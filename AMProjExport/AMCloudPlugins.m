#import "AMCloudPlugins.h"
#import "AMProjImportArchive.h"

#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>

static NSString *AMCloudPluginsNormalizeEffectResourceReference(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *normalized = [value stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!normalized.length || [normalized containsString:@"://"] ||
        [normalized hasPrefix:@"/"] || [normalized hasPrefix:@"@"]) return nil;
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\\"
                                                         withString:@"/"];
    while ([normalized hasPrefix:@"./"]) {
        normalized = [normalized substringFromIndex:2];
    }
    if ([normalized hasPrefix:@"BuiltinEffects/"]) {
        normalized = [normalized substringFromIndex:@"BuiltinEffects/".length];
    }
    NSArray<NSString *> *parts = normalized.pathComponents;
    if (parts.count < 2) return nil;
    for (NSString *part in parts) {
        if (!part.length || [part isEqualToString:@"."] ||
            [part isEqualToString:@".."] || [part containsString:@":"]) return nil;
    }
    NSString *extension = parts.lastObject.pathExtension.lowercaseString;
    if (![@[@"png", @"jpg", @"jpeg", @"webp", @"xml"] containsObject:extension]) {
        return nil;
    }
    return [parts componentsJoinedByString:@"/"];
}

@interface AMCloudPluginsEffectIdentityParser : NSObject <NSXMLParserDelegate>
@property(nonatomic, copy) NSString *effectID;
@property(nonatomic) BOOL sawRoot;
@property(nonatomic) BOOL invalid;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *rootAttributes;
@property(nonatomic, strong) NSMutableSet<NSString *> *referencedPaths;
@property(nonatomic, strong) NSMutableSet<NSString *> *referencedEffectIDs;
@end

static void AMCloudPluginsRecordEffectAttributes(
    AMCloudPluginsEffectIdentityParser *delegate,
    NSDictionary<NSString *, NSString *> *attributeDict) {
    if (!delegate.referencedPaths) delegate.referencedPaths = [NSMutableSet set];
    if (!delegate.referencedEffectIDs) delegate.referencedEffectIDs = [NSMutableSet set];
    for (NSString *key in attributeDict) {
        NSString *value = attributeDict[key];
        NSString *reference = AMCloudPluginsNormalizeEffectResourceReference(value);
        if (reference.length) [delegate.referencedPaths addObject:reference.lowercaseString];
        NSString *normalizedKey = key.lowercaseString;
        if ([normalizedKey isEqualToString:@"effect"] ||
            [normalizedKey isEqualToString:@"effectid"] ||
            [normalizedKey isEqualToString:@"effect_id"]) {
            NSString *effectID = [value stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (effectID.length && ![effectID containsString:@"://"] &&
                ![effectID containsString:@"/"]) {
                [delegate.referencedEffectIDs addObject:effectID.lowercaseString];
            }
        }
    }
}

@implementation AMCloudPluginsEffectIdentityParser

- (void)parser:(NSXMLParser *)parser
 didStartElement:(NSString *)elementName
    namespaceURI:(NSString *)namespaceURI
      qualifiedName:(NSString *)qName
      attributes:(NSDictionary<NSString *,NSString *> *)attributeDict {
    (void)parser;
    (void)namespaceURI;
    (void)qName;
    AMCloudPluginsRecordEffectAttributes(self, attributeDict);
    if (self.sawRoot) return;
    self.sawRoot = YES;
    NSMutableDictionary<NSString *, NSString *> *rootAttributes = [NSMutableDictionary dictionary];
    for (NSString *key in attributeDict) {
        NSString *value = [attributeDict[key] isKindOfClass:NSString.class]
            ? attributeDict[key] : nil;
        if (value.length) rootAttributes[key.lowercaseString] = value;
    }
    self.rootAttributes = rootAttributes;
    if ([elementName caseInsensitiveCompare:@"effect"] != NSOrderedSame) {
        self.invalid = YES;
        return;
    }
    NSString *identifier = [attributeDict[@"id"] isKindOfClass:NSString.class]
        ? [attributeDict[@"id"] stringByTrimmingCharactersInSet:
              NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
    if (identifier.length) self.effectID = identifier;
}

@end

static NSString *const AMCloudPluginsDirectoryName = @"AMCloudPlugins";
static NSString *const AMCloudPluginsStateName = @"state.json";
static NSString *const AMCloudPluginsRevocationName = @"AMCloudPlugins.revoked";
static NSString *const AMCloudBundleHookGuardKey = @"AMCloudBundleHookGuard";
// Bump this whenever the merged catalog invariants change. Protocol 6
// catalogs incorrectly treated some com.autfeng plugins as official aliases;
// rebuild from the IPA baseline so real custom plugins are exposed again.
NSInteger const AMCloudPluginsCatalogProtocolVersion = 7;

typedef NSArray<NSURL *> *(*AMCloudBundleURLsIMP)(id, SEL, NSString *, NSString *);
typedef NSURL *(*AMCloudBundleURLIMP)(id, SEL, NSString *, NSString *, NSString *);
typedef NSArray<NSString *> *(*AMCloudBundlePathsIMP)(id, SEL, NSString *, NSString *);
typedef NSString *(*AMCloudBundlePathIMP)(id, SEL, NSString *, NSString *, NSString *);

static AMCloudBundleURLsIMP AMCloudOriginalBundleURLs = NULL;
static AMCloudBundleURLIMP AMCloudOriginalBundleURL = NULL;
static AMCloudBundlePathsIMP AMCloudOriginalBundlePaths = NULL;
static AMCloudBundlePathIMP AMCloudOriginalBundlePath = NULL;
static NSURL *AMCloudActiveEffectsURL = nil;
static NSDictionary<NSString *, id> *AMCloudActiveState = nil;
static uint64_t AMCloudAuthorizationGeneration = 0;
static uint64_t AMCloudActiveAuthorizationGeneration = 0;
static void *AMCloudPluginsMutationQueueKey = &AMCloudPluginsMutationQueueKey;

// Bundle resource lookups are on the native effect-discovery path and can be
// repeated dozens of times while the browser is scrolling.  The catalog is
// immutable between activations, so cache the directory listing and the
// cloud-vs-IPA comparison until the active state changes.  This avoids doing
// synchronous file reads on the main thread for every lookup without changing
// which resource wins.
static NSCache<NSString *, NSArray<NSURL *> *> *AMCloudPluginsFilesCache(void) {
    static NSCache<NSString *, NSArray<NSURL *> *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 256;
    });
    return cache;
}

static NSCache<NSString *, NSNumber *> *AMCloudPluginsResourceDecisionCache(void) {
    static NSCache<NSString *, NSNumber *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 1024;
    });
    return cache;
}

static void AMCloudPluginsClearRuntimeCaches(void) {
    [AMCloudPluginsFilesCache() removeAllObjects];
    [AMCloudPluginsResourceDecisionCache() removeAllObjects];
}

static NSString *AMCloudPluginsFilesCacheKey(NSURL *directoryURL,
                                              NSString *extension) {
    NSString *path = directoryURL.URLByStandardizingPath.path ?: @"";
    NSString *suffix = extension.lowercaseString ?: @"";
    return [NSString stringWithFormat:@"%@|%@", path, suffix];
}

static NSString *AMCloudPluginsResourceDecisionCacheKey(NSURL *cloudURL,
                                                         NSURL *bundledURL) {
    return [NSString stringWithFormat:@"%@\n%@",
            cloudURL.URLByStandardizingPath.path ?: @"",
            bundledURL.URLByStandardizingPath.path ?: @""];
}

static NSArray<NSURL *> *AMCloudPluginsFiles(NSURL *directoryURL, NSString *extension);
static NSArray<NSURL *> *AMCloudPluginsRecursiveFiles(NSURL *directoryURL);
static BOOL AMCloudPluginsCatalogContainsBundledEffects(NSURL *catalogEffectsURL,
                                                         NSURL *bundledEffectsURL);
static BOOL AMCloudPluginsResourceNameIsSafe(NSString *name);
static NSString *AMCloudPluginsRelativeFilePath(NSURL *fileURL, NSURL *rootURL);
static NSString *AMCloudPluginsItemEffectID(NSDictionary *plugin);
static NSString *AMCloudPluginsItemTargetPath(NSDictionary *plugin);
static NSString *AMCloudPluginsItemVersionID(NSDictionary *plugin);
static NSURL *AMCloudPluginsBundledEffectsURL(void);
static BOOL AMCloudPluginsCustomPluginTargetsBundledEffect(NSDictionary *plugin);

static NSError *AMCloudPluginsValidationError(NSString *message) {
    return [NSError errorWithDomain:AMProjImportArchiveErrorDomain
                                code:AMProjImportArchiveErrorInvalidArgument
                            userInfo:@{NSLocalizedDescriptionKey: message ?: @"Invalid cloud plugin metadata"}];
}

static NSString *AMCloudPluginsItemDisplayName(NSDictionary *plugin) {
    for (NSString *key in @[@"name", @"displayName", @"display_name", @"title"]) {
        NSString *value = [plugin[key] isKindOfClass:NSString.class] ? plugin[key] : nil;
        if (value.length) return value;
    }
    return nil;
}

static NSError *AMCloudPluginsValidationErrorForItem(
    NSString *message, NSDictionary *plugin, NSString *sourceID, NSURL *sourceURL) {
    NSString *pluginID = [plugin[@"id"] isKindOfClass:NSString.class] ? plugin[@"id"] : nil;
    NSString *versionID = AMCloudPluginsItemVersionID(plugin);
    NSString *effectID = AMCloudPluginsItemEffectID(plugin);
    NSString *targetPath = AMCloudPluginsItemTargetPath(plugin);
    NSString *displayName = AMCloudPluginsItemDisplayName(plugin);
    NSMutableArray<NSString *> *context = [NSMutableArray array];
    if (pluginID.length) [context addObject:[NSString stringWithFormat:@"plugin=%@", pluginID]];
    if (displayName.length) [context addObject:[NSString stringWithFormat:@"name=%@", displayName]];
    if (versionID.length) [context addObject:[NSString stringWithFormat:@"version=%@", versionID]];
    if (effectID.length) [context addObject:[NSString stringWithFormat:@"effectId=%@", effectID]];
    if (targetPath.length) [context addObject:[NSString stringWithFormat:@"targetPath=%@", targetPath]];
    if (sourceID.length) [context addObject:[NSString stringWithFormat:@"sourceId=%@", sourceID]];
    if (sourceURL.path.length) [context addObject:[NSString stringWithFormat:@"source=%@", sourceURL.path]];
    NSString *detail = context.count ? [context componentsJoinedByString:@"; "] : @"no item context";
    return AMCloudPluginsValidationError([NSString stringWithFormat:@"%@ (%@)", message ?: @"Cloud plugin validation failed", detail]);
}

static NSString *AMCloudPluginsItemKind(NSDictionary *plugin) {
    NSString *kind = [plugin[@"kind"] isKindOfClass:NSString.class]
        ? [plugin[@"kind"] lowercaseString] : nil;
    if (!kind.length) {
        kind = [plugin[@"type"] isKindOfClass:NSString.class]
            ? [plugin[@"type"] lowercaseString] : nil;
    }
    return kind.length ? kind : @"custom_plugin";
}

static NSString *AMCloudPluginsItemEffectID(NSDictionary *plugin) {
    NSString *effectID = [plugin[@"effectId"] isKindOfClass:NSString.class]
        ? plugin[@"effectId"] : plugin[@"effect_id"];
    return [effectID isKindOfClass:NSString.class]
        ? [effectID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        : nil;
}

static NSString *AMCloudPluginsNormalizeBuiltinTargetPath(NSString *targetPath) {
    if (![targetPath isKindOfClass:NSString.class] || !targetPath.length ||
        [targetPath hasPrefix:@"/"] || [targetPath hasPrefix:@"\\"]) return nil;
    NSString *normalized = [targetPath stringByReplacingOccurrencesOfString:@"\\"
                                                                   withString:@"/"];
    NSArray<NSString *> *parts = normalized.pathComponents;
    if (parts.count < 2 || ![parts.firstObject isEqualToString:@"BuiltinEffects"]) return nil;
    for (NSString *part in parts) {
        if (!part.length || [part isEqualToString:@"."] || [part isEqualToString:@".."] ||
            [part containsString:@":"]) return nil;
    }
    NSString *filename = parts.lastObject;
    if ([filename.pathExtension caseInsensitiveCompare:@"xml"] != NSOrderedSame) return nil;
    return [parts componentsJoinedByString:@"/"];
}

static NSString *AMCloudPluginsItemTargetPath(NSDictionary *plugin) {
    NSString *targetPath = [plugin[@"targetPath"] isKindOfClass:NSString.class]
        ? plugin[@"targetPath"] : plugin[@"target_path"];
    return AMCloudPluginsNormalizeBuiltinTargetPath(targetPath);
}

static BOOL AMCloudPluginsItemRestartRequired(NSDictionary *plugin) {
    return [plugin[@"restartRequired"] boolValue] || [plugin[@"restart_required"] boolValue];
}

static BOOL AMCloudPluginsItemAllowsLegacyPathOverride(NSDictionary *plugin) {
    return [plugin[@"legacyPathOverride"] boolValue] ||
        [plugin[@"legacy_path_override"] boolValue];
}

static AMCloudPluginsEffectIdentityParser *AMCloudPluginsParseEffectData(
    NSData *data, NSError **error) {
    if (!data.length) {
        if (error) *error = AMCloudPluginsValidationError(
            @"Effect XML is empty or unreadable");
        return nil;
    }
    AMCloudPluginsEffectIdentityParser *delegate = [AMCloudPluginsEffectIdentityParser new];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = delegate;
    parser.shouldProcessNamespaces = NO;
    parser.shouldResolveExternalEntities = NO;
    if ([parser parse] && !delegate.invalid && delegate.sawRoot &&
        delegate.effectID.length) return delegate;

    // A few legacy effect files in the shipped catalog are not XML-well-formed
    // (usually a missing space between root attributes). Use a deliberately
    // narrow root-tag fallback so those existing custom effects remain usable;
    // external entities, declarations, and arbitrary non-effect roots stay
    // rejected.
    NSString *source = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!source.length || [source rangeOfString:@"<!DOCTYPE" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [source rangeOfString:@"<!ENTITY" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        if (error && !*error) *error = AMCloudPluginsValidationError(
            @"Effect XML has no valid root effect id");
        return nil;
    }
    NSRegularExpression *rootExpression = [NSRegularExpression regularExpressionWithPattern:
        @"<effect(?:\\s|>)" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *rootMatch = [rootExpression firstMatchInString:source
        options:0 range:NSMakeRange(0, source.length)];
    if (!rootMatch) {
        if (error && !*error) *error = AMCloudPluginsValidationError(
            @"Effect XML has no valid root effect id");
        return nil;
    }
    NSRange closeRange = [source rangeOfString:@">" options:0
                                          range:NSMakeRange(rootMatch.range.location,
                                                            source.length - rootMatch.range.location)];
    if (closeRange.location == NSNotFound) {
        if (error && !*error) *error = AMCloudPluginsValidationError(
            @"Effect XML root tag is incomplete");
        return nil;
    }
    NSString *rootTag = [source substringWithRange:NSMakeRange(
        rootMatch.range.location, closeRange.location + 1 - rootMatch.range.location)];
    NSRegularExpression *attributeExpression = [NSRegularExpression regularExpressionWithPattern:
        @"([A-Za-z_][A-Za-z0-9_.:-]*)\\s*=\\s*([\\\"'])([^\\\"']*)\\2"
        options:0 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [attributeExpression matchesInString:rootTag
        options:0 range:NSMakeRange(0, rootTag.length)];
    NSMutableDictionary<NSString *, NSString *> *attributes = [NSMutableDictionary dictionary];
    for (NSTextCheckingResult *match in matches) {
        NSString *key = [rootTag substringWithRange:[match rangeAtIndex:1]];
        NSString *value = [rootTag substringWithRange:[match rangeAtIndex:3]];
        attributes[key] = value;
    }
    NSString *identifier = nil;
    for (NSString *key in attributes) {
        if ([key caseInsensitiveCompare:@"id"] == NSOrderedSame) {
            identifier = [attributes[key] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            break;
        }
    }
    if (!identifier.length) {
        if (error && !*error) *error = AMCloudPluginsValidationError(
            @"Effect XML has no valid root effect id");
        return nil;
    }
    delegate = [AMCloudPluginsEffectIdentityParser new];
    delegate.sawRoot = YES;
    delegate.effectID = identifier;
    NSMutableDictionary<NSString *, NSString *> *rootAttributes = [NSMutableDictionary dictionary];
    for (NSString *key in attributes) {
        NSString *value = [attributes[key] isKindOfClass:NSString.class]
            ? attributes[key] : nil;
        if (value.length) rootAttributes[key.lowercaseString] = value;
    }
    delegate.rootAttributes = rootAttributes;
    AMCloudPluginsRecordEffectAttributes(delegate, attributes);
    return delegate;
}

static NSString *AMCloudPluginsEffectIDForXMLURL(NSURL *URL, NSError **error) {
    NSData *data = URL ? [NSData dataWithContentsOfURL:URL options:0 error:error] : nil;
    AMCloudPluginsEffectIdentityParser *delegate = AMCloudPluginsParseEffectData(data, error);
    if (!delegate) return nil;
    return delegate.effectID;
}

static NSString *AMCloudPluginsRootAttributeForXMLURL(
    NSURL *URL, NSString *attribute, NSError **error) {
    NSData *data = URL ? [NSData dataWithContentsOfURL:URL options:0 error:error] : nil;
    AMCloudPluginsEffectIdentityParser *delegate = AMCloudPluginsParseEffectData(data, error);
    if (!delegate) return nil;
    return delegate.rootAttributes[attribute.lowercaseString];
}

static NSString *AMCloudPluginsEscapeXMLAttributeValue(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return @"";
    return [[value stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"]
        stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
}

static BOOL AMCloudPluginsEnsureRootAttribute(
    NSURL *URL, NSString *attribute, NSString *value, NSError **error) {
    if (!URL || !attribute.length || !value.length) return YES;
    NSData *data = [NSData dataWithContentsOfURL:URL options:0 error:error];
    NSString *source = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (!source.length) {
        if (error && !*error) *error = AMCloudPluginsValidationError(
            @"Builtin override XML is not valid UTF-8");
        return NO;
    }
    NSRegularExpression *rootExpression = [NSRegularExpression regularExpressionWithPattern:
        @"<effect(?:\\s|>)[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *rootMatch = [rootExpression firstMatchInString:source
        options:0 range:NSMakeRange(0, source.length)];
    if (!rootMatch) {
        if (error && !*error) *error = AMCloudPluginsValidationError(
            @"Builtin override XML has no effect root");
        return NO;
    }
    NSRange rootRange = rootMatch.range;
    NSString *rootTag = [source substringWithRange:rootRange];
    NSString *escaped = AMCloudPluginsEscapeXMLAttributeValue(value);
    NSString *attributePattern = [NSString stringWithFormat:
        @"\\b%@\\s*=\\s*(['\\\"])([^'\\\"]*)\\1", attribute];
    NSRegularExpression *attributeExpression = [NSRegularExpression regularExpressionWithPattern:
        attributePattern options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *attributeMatch = [attributeExpression firstMatchInString:rootTag
        options:0 range:NSMakeRange(0, rootTag.length)];
    if (attributeMatch) {
        NSString *existing = [rootTag substringWithRange:[attributeMatch rangeAtIndex:2]];
        if ([existing isEqualToString:value]) return YES;
        NSMutableString *updatedTag = [rootTag mutableCopy];
        [updatedTag replaceCharactersInRange:[attributeMatch rangeAtIndex:2] withString:escaped];
        NSMutableString *updated = [source mutableCopy];
        [updated replaceCharactersInRange:rootRange withString:updatedTag];
        NSData *updatedData = [updated dataUsingEncoding:NSUTF8StringEncoding];
        if (![updatedData writeToURL:URL options:NSDataWritingAtomic error:error]) return NO;
        return YES;
    }
    NSMutableString *updatedTag = [rootTag mutableCopy];
    NSRange closeRange = [updatedTag rangeOfString:@">" options:NSBackwardsSearch];
    if (closeRange.location == NSNotFound) {
        if (error && !*error) *error = AMCloudPluginsValidationError(
            @"Builtin override XML root is incomplete");
        return NO;
    }
    NSUInteger insertion = closeRange.location;
    if (insertion > 0 && [updatedTag characterAtIndex:insertion - 1] == '/') insertion--;
    NSString *addition = [NSString stringWithFormat:@" %@=\"%@\"", attribute, escaped];
    [updatedTag insertString:addition atIndex:insertion];
    NSMutableString *updated = [source mutableCopy];
    [updated replaceCharactersInRange:rootRange withString:updatedTag];
    NSData *updatedData = [updated dataUsingEncoding:NSUTF8StringEncoding];
    if (![updatedData writeToURL:URL options:NSDataWritingAtomic error:error]) return NO;
    return YES;
}

static BOOL AMCloudPluginsRepairBuiltinCompatibility(
    NSURL *cloudURL, NSURL *bundledURL, NSError **error) {
    if (!cloudURL || !bundledURL) return YES;
    NSError *bundledError = nil;
    NSString *bundledCompat = AMCloudPluginsRootAttributeForXMLURL(
        bundledURL, @"compat", &bundledError);
    if (!bundledCompat.length) return YES;
    NSError *cloudError = nil;
    NSString *cloudCompat = AMCloudPluginsRootAttributeForXMLURL(
        cloudURL, @"compat", &cloudError);
    if (cloudError && !cloudCompat.length) {
        if (error) *error = cloudError;
        return NO;
    }
    if (cloudCompat.length && ![cloudCompat isEqualToString:bundledCompat]) {
        if (error) *error = AMCloudPluginsValidationError([NSString stringWithFormat:
            @"Builtin override compat does not match the IPA baseline (%@ / %@)",
            cloudCompat, bundledCompat]);
        return NO;
    }
    if (!cloudCompat.length && !AMCloudPluginsEnsureRootAttribute(
            cloudURL, @"compat", bundledCompat, error)) return NO;

    NSError *bundledOverdrawError = nil;
    NSString *bundledMaxOverdraw = AMCloudPluginsRootAttributeForXMLURL(
        bundledURL, @"maxoverdraw", &bundledOverdrawError);
    if (bundledMaxOverdraw.length) {
        NSError *cloudMaxOverdrawError = nil;
        NSString *cloudMaxOverdraw = AMCloudPluginsRootAttributeForXMLURL(
            cloudURL, @"maxoverdraw", &cloudMaxOverdrawError);
        if (cloudMaxOverdrawError && !cloudMaxOverdraw.length) {
            if (error) *error = cloudMaxOverdrawError;
            return NO;
        }
        if (!cloudMaxOverdraw.length) {
            NSString *legacyMaxOverdraw = AMCloudPluginsRootAttributeForXMLURL(
                cloudURL, @"max-overdraw", nil);
            if (!legacyMaxOverdraw.length) legacyMaxOverdraw = bundledMaxOverdraw;
            if (!AMCloudPluginsEnsureRootAttribute(
                    cloudURL, @"maxOverdraw", legacyMaxOverdraw, error)) return NO;
        }
    }
    return YES;
}

static NSSet<NSString *> *AMCloudPluginsReferencedPathsForXMLURL(
    NSURL *URL, NSError **error) {
    NSData *data = URL ? [NSData dataWithContentsOfURL:URL options:0 error:error] : nil;
    AMCloudPluginsEffectIdentityParser *delegate = AMCloudPluginsParseEffectData(data, error);
    if (!delegate) return nil;
    return delegate.referencedPaths ?: [NSSet set];
}

static NSSet<NSString *> *AMCloudPluginsReferencedEffectIDsForXMLURL(
    NSURL *URL, NSError **error) {
    NSData *data = URL ? [NSData dataWithContentsOfURL:URL options:0 error:error] : nil;
    AMCloudPluginsEffectIdentityParser *delegate = AMCloudPluginsParseEffectData(data, error);
    if (!delegate) return nil;
    return delegate.referencedEffectIDs ?: [NSSet set];
}

static NSData *AMCloudPluginsDataAtURL(NSURL *URL) {
    if (!URL) return nil;
    return [NSData dataWithContentsOfURL:URL options:0 error:nil];
}

static NSString *AMCloudPluginsBundledEffectsFingerprint(NSURL *effectsURL) {
    if (!effectsURL) return nil;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    for (NSURL *fileURL in AMCloudPluginsRecursiveFiles(effectsURL)) {
        NSString *relative = AMCloudPluginsRelativeFilePath(fileURL, effectsURL);
        NSData *data = AMCloudPluginsDataAtURL(fileURL);
        if (!relative.length || !data.length) return nil;
        NSData *relativeData = [relative dataUsingEncoding:NSUTF8StringEncoding];
        uint64_t length = data.length;
        CC_SHA256_Update(&context, relativeData.bytes, (CC_LONG)relativeData.length);
        CC_SHA256_Update(&context, &length, (CC_LONG)sizeof(length));
        CC_SHA256_Update(&context, data.bytes, (CC_LONG)data.length);
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [result appendFormat:@"%02x", digest[index]];
    }
    return result;
}

static BOOL AMCloudPluginsCatalogContainsBundledEffects(NSURL *catalogEffectsURL,
                                                         NSURL *bundledEffectsURL) {
    if (!catalogEffectsURL || !bundledEffectsURL) return NO;
    for (NSURL *bundledURL in AMCloudPluginsRecursiveFiles(bundledEffectsURL)) {
        NSString *relative = AMCloudPluginsRelativeFilePath(bundledURL, bundledEffectsURL);
        if (!relative.length) return NO;
        NSURL *catalogURL = [catalogEffectsURL URLByAppendingPathComponent:relative];
        NSNumber *regular = nil;
        if (![catalogURL getResourceValue:&regular forKey:NSURLIsRegularFileKey
                                     error:nil] || !regular.boolValue) return NO;
    }
    return YES;
}

static BOOL AMCloudPluginsIsLegacyCustomEffectID(NSString *effectID) {
    NSString *normalized = [effectID isKindOfClass:NSString.class]
        ? [effectID stringByTrimmingCharactersInSet:
              NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString : nil;
    return [normalized hasPrefix:@"com.autfeng."];
}

static BOOL AMCloudPluginsIsOfficialEffectID(NSString *effectID) {
    NSString *normalized = [effectID isKindOfClass:NSString.class]
        ? [effectID stringByTrimmingCharactersInSet:
              NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString : nil;
    return [normalized hasPrefix:@"com.alightcreative."];
}

static BOOL AMCloudPluginsLegacyXMLCanOverrideBundledOfficial(
    NSURL *sourceURL, NSURL *destinationURL, NSURL *bundledURL,
    NSSet<NSString *> *targetReferencedEffectIDs) {
    NSError *sourceError = nil;
    NSString *sourceID = AMCloudPluginsEffectIDForXMLURL(sourceURL, &sourceError);
    if (!sourceID.length) return NO;

    NSError *bundledError = nil;
    NSString *bundledID = AMCloudPluginsEffectIDForXMLURL(bundledURL, &bundledError);
    if (!bundledID.length || !AMCloudPluginsIsOfficialEffectID(bundledID)) return NO;
    NSData *sourceData = AMCloudPluginsDataAtURL(sourceURL);
    NSData *bundledData = AMCloudPluginsDataAtURL(bundledURL);
    (void)destinationURL;
    if (AMCloudPluginsIsOfficialEffectID(sourceID) &&
        [sourceID caseInsensitiveCompare:bundledID] == NSOrderedSame) {
        // An unchanged official dependency is safe and does not alter the IPA.
        return sourceData.length && bundledData.length &&
            [sourceData isEqualToData:bundledData];
    }
    // A legacy custom dependency is allowed only when the target XML explicitly
    // references the official effect identity it replaces.
    return AMCloudPluginsIsLegacyCustomEffectID(sourceID) &&
        [targetReferencedEffectIDs containsObject:bundledID.lowercaseString];
}

static dispatch_queue_t AMCloudPluginsMutationQueue(void) {
    static dispatch_queue_t queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ayakameow.amproj.cloud-plugins",
                                      DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(queue, AMCloudPluginsMutationQueueKey,
                                    AMCloudPluginsMutationQueueKey, NULL);
    });
    return queue;
}

static void AMCloudPluginsPerformMutation(dispatch_block_t block) {
    if (!block) return;
    if (dispatch_get_specific(AMCloudPluginsMutationQueueKey)) {
        block();
    } else {
        dispatch_sync(AMCloudPluginsMutationQueue(), block);
    }
}

static NSURL *AMCloudPluginsRootURL(void) {
    NSURL *support = [NSFileManager.defaultManager
        URLsForDirectory:NSApplicationSupportDirectory
               inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:AMCloudPluginsDirectoryName isDirectory:YES];
}

static NSURL *AMCloudPluginsStateURL(void) {
    return [AMCloudPluginsRootURL() URLByAppendingPathComponent:AMCloudPluginsStateName];
}

static NSURL *AMCloudPluginsCatalogURL(void);

static NSURL *AMCloudPluginsRevocationURL(void) {
    NSURL *support = [NSFileManager.defaultManager
        URLsForDirectory:NSApplicationSupportDirectory
               inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:AMCloudPluginsRevocationName];
}

static BOOL AMCloudPluginsGetItemExistence(NSFileManager *manager, NSURL *URL,
                                            BOOL *exists) {
    NSError *error = nil;
    NSDictionary *attributes = [manager attributesOfItemAtPath:URL.path error:&error];
    if (attributes) {
        if (exists) *exists = YES;
        return YES;
    }
    if ([error.domain isEqualToString:NSCocoaErrorDomain] &&
        (error.code == NSFileNoSuchFileError ||
         error.code == NSFileReadNoSuchFileError)) {
        if (exists) *exists = NO;
        return YES;
    }
    if (exists) *exists = NO;
    return NO;
}

static BOOL AMCloudPluginsInvalidatePersistedState(NSFileManager *manager) {
    NSURL *stateURL = AMCloudPluginsStateURL();
    BOOL stateExists = NO;
    if (AMCloudPluginsGetItemExistence(manager, stateURL, &stateExists) &&
        !stateExists) return YES;

    NSData *invalidState = [NSData dataWithBytes:"{}" length:2];
    NSError *error = nil;
    if ([invalidState writeToURL:stateURL options:NSDataWritingAtomic error:&error]) {
        return YES;
    }

    [manager removeItemAtURL:stateURL error:nil];
    return AMCloudPluginsGetItemExistence(manager, stateURL, &stateExists) &&
        !stateExists;
}

static BOOL AMCloudPluginsInvalidateStaleCatalog(NSFileManager *manager) {
    if (!manager) return NO;
    BOOL stateInvalidated = AMCloudPluginsInvalidatePersistedState(manager);
    NSURL *catalogURL = AMCloudPluginsCatalogURL();
    NSError *removeError = nil;
    BOOL catalogRemoved = [manager removeItemAtURL:catalogURL error:&removeError];
    if (!catalogRemoved && removeError.code == NSFileNoSuchFileError) {
        catalogRemoved = YES;
    }
    BOOL catalogExists = NO;
    BOOL catalogKnown = AMCloudPluginsGetItemExistence(manager, catalogURL, &catalogExists);
    return stateInvalidated && catalogKnown && !catalogExists;
}

static BOOL AMCloudPluginsPersistRevocationMarker(NSFileManager *manager) {
    NSURL *markerURL = AMCloudPluginsRevocationURL();
    NSData *marker = [NSData dataWithBytes:"revoked" length:7];
    if ([marker writeToURL:markerURL options:NSDataWritingAtomic error:nil]) return YES;
    BOOL markerExists = NO;
    return AMCloudPluginsGetItemExistence(manager, markerURL, &markerExists) &&
        markerExists;
}

static BOOL AMCloudPluginReleaseIDIsSafe(NSString *releaseID) {
    if (![releaseID isKindOfClass:NSString.class] || releaseID.length == 0 ||
        releaseID.length > 128) return NO;
    NSCharacterSet *allowed = [NSCharacterSet
        characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    return [releaseID rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static BOOL AMCloudPluginAuthorizationKeyIsSafe(NSString *authorizationKey) {
    if (![authorizationKey isKindOfClass:NSString.class] ||
        authorizationKey.length != 64) return NO;
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    return [authorizationKey.lowercaseString
        rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound;
}

static NSURL *AMCloudPluginsItemsURL(void) {
    return [AMCloudPluginsRootURL() URLByAppendingPathComponent:@"items" isDirectory:YES];
}

static NSURL *AMCloudPluginsCatalogURL(void) {
    return [AMCloudPluginsRootURL() URLByAppendingPathComponent:@"catalog" isDirectory:YES];
}

static NSString *AMCloudPluginsItemVersionID(NSDictionary *plugin) {
    NSDictionary *version = [plugin[@"version"] isKindOfClass:NSDictionary.class]
        ? plugin[@"version"] : nil;
    NSString *versionID = [version[@"id"] isKindOfClass:NSString.class]
        ? version[@"id"] : nil;
    if (!versionID.length) {
        versionID = [plugin[@"version_id"] isKindOfClass:NSString.class]
            ? plugin[@"version_id"] : nil;
    }
    return versionID;
}

static NSString *AMCloudPluginsItemSHA(NSDictionary *plugin) {
    NSDictionary *version = [plugin[@"version"] isKindOfClass:NSDictionary.class]
        ? plugin[@"version"] : nil;
    NSString *sha256 = [version[@"sha256"] isKindOfClass:NSString.class]
        ? version[@"sha256"] : nil;
    if (!sha256.length) {
        sha256 = [plugin[@"sha256"] isKindOfClass:NSString.class]
            ? plugin[@"sha256"] : nil;
    }
    return sha256.length ? sha256.lowercaseString : nil;
}

static BOOL AMCloudPluginsCatalogEntryIsSafe(NSDictionary *plugin) {
    NSString *pluginID = [plugin[@"id"] isKindOfClass:NSString.class] ? plugin[@"id"] : nil;
    NSString *kind = AMCloudPluginsItemKind(plugin);
    if (![kind isEqualToString:@"custom_plugin"] &&
        ![kind isEqualToString:@"builtin_override"]) return NO;
    if ([kind isEqualToString:@"custom_plugin"] &&
        AMCloudPluginsCustomPluginTargetsBundledEffect(plugin)) return NO;
    if ([kind isEqualToString:@"builtin_override"] &&
        (!AMCloudPluginsItemEffectID(plugin).length ||
         !AMCloudPluginsItemTargetPath(plugin).length)) return NO;
    if ([kind isEqualToString:@"custom_plugin"] &&
        AMCloudPluginsItemAllowsLegacyPathOverride(plugin) &&
        (!AMCloudPluginsItemEffectID(plugin).length ||
         !AMCloudPluginsItemTargetPath(plugin).length)) return NO;
    return AMCloudPluginReleaseIDIsSafe(pluginID) &&
        AMCloudPluginReleaseIDIsSafe(AMCloudPluginsItemVersionID(plugin)) &&
        AMCloudPluginAuthorizationKeyIsSafe(AMCloudPluginsItemSHA(plugin));
}

static NSURL *AMCloudPluginsBuiltinTargetURL(NSURL *effectsRoot, NSString *targetPath) {
    NSString *normalized = AMCloudPluginsNormalizeBuiltinTargetPath(targetPath);
    if (!effectsRoot || !normalized.length) return nil;
    NSString *relative = [normalized substringFromIndex:@"BuiltinEffects/".length];
    NSURL *candidate = [[effectsRoot URLByAppendingPathComponent:relative]
        URLByStandardizingPath];
    NSString *rootPath = effectsRoot.URLByStandardizingPath.path;
    NSString *candidatePath = candidate.path;
    NSString *prefix = [rootPath stringByAppendingString:@"/"];
    if (!rootPath.length || !candidatePath.length ||
        ![candidatePath hasPrefix:prefix]) return nil;
    NSNumber *regular = nil;
    if (![candidate getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil] ||
        !regular.boolValue) return nil;
    return candidate;
}

// A custom effect may live under BuiltinEffects, but it must not reuse a path
// that belongs to an IPA-shipped official effect. Older catalogs did exactly
// that after rewriting their XML ids to com.autfeng..., which makes Alight
// Motion's native recommendation lookup fall back to an unrelated effect.
static BOOL AMCloudPluginsCustomPluginTargetsBundledEffect(NSDictionary *plugin) {
    if (![AMCloudPluginsItemKind(plugin) isEqualToString:@"custom_plugin"]) return NO;
    NSURL *bundledURL = AMCloudPluginsBuiltinTargetURL(
        AMCloudPluginsBundledEffectsURL(), AMCloudPluginsItemTargetPath(plugin));
    NSString *bundledID = AMCloudPluginsEffectIDForXMLURL(bundledURL, nil);
    return AMCloudPluginsIsOfficialEffectID(bundledID);
}

static BOOL AMCloudPluginsValidateBuiltinOverride(NSDictionary *plugin,
                                                   NSURL *versionURL,
                                                   NSURL *bundledEffectsURL,
                                                   NSError **error) {
    if (![AMCloudPluginsItemKind(plugin) isEqualToString:@"builtin_override"]) return YES;
    NSString *effectID = AMCloudPluginsItemEffectID(plugin);
    NSString *targetPath = AMCloudPluginsItemTargetPath(plugin);
    NSURL *bundledURL = AMCloudPluginsBuiltinTargetURL(bundledEffectsURL, targetPath);
    NSURL *versionEffectsURL = [versionURL URLByAppendingPathComponent:@"BuiltinEffects"
                                                                  isDirectory:YES];
    NSURL *cloudURL = AMCloudPluginsBuiltinTargetURL(versionEffectsURL, targetPath);
    if (!effectID.length || !targetPath.length || !bundledURL || !cloudURL) {
        if (error) *error = AMCloudPluginsValidationError(
            @"Builtin override targetPath is not an existing IPA effect");
        return NO;
    }
    if (!AMCloudPluginsRepairBuiltinCompatibility(cloudURL, bundledURL, error)) {
        return NO;
    }
    NSError *bundledError = nil;
    NSString *bundledID = AMCloudPluginsEffectIDForXMLURL(bundledURL, &bundledError);
    if (!bundledID.length || ![bundledID isEqualToString:effectID]) {
        if (error) *error = AMCloudPluginsValidationErrorForItem(
            [NSString stringWithFormat:@"Builtin override effectId does not match the bundled IPA effect (bundledId=%@)",
             bundledID ?: (bundledError.localizedDescription ?: @"missing")],
            plugin, bundledID, bundledURL);
        return NO;
    }
    NSError *cloudError = nil;
    NSString *cloudID = AMCloudPluginsEffectIDForXMLURL(cloudURL, &cloudError);
    if (!cloudID.length || ![cloudID isEqualToString:effectID]) {
        if (error) *error = AMCloudPluginsValidationErrorForItem(
            [NSString stringWithFormat:@"Builtin override XML effect id does not match effectId (sourceId=%@)",
             cloudID ?: (cloudError.localizedDescription ?: @"missing")],
            plugin, cloudID, cloudURL);
        return NO;
    }
    return YES;
}

static BOOL AMCloudPluginsValidateLegacyCustomOverride(
    NSDictionary *plugin, NSURL *versionURL, NSURL *bundledEffectsURL, NSError **error) {
    if (![AMCloudPluginsItemKind(plugin) isEqualToString:@"custom_plugin"] ||
        !AMCloudPluginsItemAllowsLegacyPathOverride(plugin)) return YES;
    NSString *effectID = AMCloudPluginsItemEffectID(plugin);
    NSString *targetPath = AMCloudPluginsItemTargetPath(plugin);
    NSURL *bundledURL = AMCloudPluginsBuiltinTargetURL(bundledEffectsURL, targetPath);
    NSURL *sourceURL = AMCloudPluginsBuiltinTargetURL(
        [versionURL URLByAppendingPathComponent:@"BuiltinEffects" isDirectory:YES],
        targetPath);
    if (!effectID.length || !targetPath.length || !sourceURL) {
        if (error) *error = AMCloudPluginsValidationError(
            @"Legacy plugin override target XML is missing");
        return NO;
    }
    NSError *sourceError = nil;
    NSString *sourceID = AMCloudPluginsEffectIDForXMLURL(sourceURL, &sourceError);
    if (!AMCloudPluginsIsLegacyCustomEffectID(sourceID) || !sourceID.length ||
        [sourceID caseInsensitiveCompare:effectID] != NSOrderedSame) {
        NSString *detail = sourceID ?: (sourceError.localizedDescription ?: @"missing");
        if (error) *error = AMCloudPluginsValidationErrorForItem(
            [NSString stringWithFormat:@"Legacy plugin override XML effect id does not match metadata (sourceId=%@)", detail],
            plugin, sourceID, sourceURL);
        return NO;
    }
    if (!bundledURL) return YES;
    if (!AMCloudPluginsRepairBuiltinCompatibility(sourceURL, bundledURL, error)) {
        return NO;
    }
    NSError *bundledError = nil;
    NSString *bundledID = AMCloudPluginsEffectIDForXMLURL(bundledURL, &bundledError);
    if (!AMCloudPluginsIsOfficialEffectID(bundledID)) {
        if (error) *error = AMCloudPluginsValidationError(
            @"Legacy plugin override target is not an official IPA effect");
        return NO;
    }
    return YES;
}

// AM enumerates BuiltinEffects by filename, while effect identity lives in
// the XML root id. A catalog can therefore contain more than one filename
// for the same effect. Keep the IPA copy as the authority for exact official
// ids and collapse duplicate custom entries before activation. Official XML
// files keep their original com.alightcreative ID/path. A repaired official
// effect belongs in a builtin_override entry and is kept by that original
// target path; a com.autfeng ID is a separate custom plugin and remains
// publishable as long as it does not claim an official path or ID.
static BOOL AMCloudPluginsDedupeCatalogRootEffects(
    NSURL *catalogEffectsURL, NSURL *bundledEffectsURL,
    NSArray<NSDictionary<NSString *, id> *> *plugins, NSError **error) {
    if (!catalogEffectsURL || !bundledEffectsURL) {
        if (error) *error = AMCloudPluginsValidationError(
            @"Cloud plugin catalog effect roots are unavailable");
        return NO;
    }
    NSArray<NSURL *> *bundledFiles = AMCloudPluginsFiles(bundledEffectsURL, @"xml");
    NSMutableSet<NSString *> *bundledNames = [NSMutableSet set];
    NSMutableSet<NSString *> *bundledIDs = [NSMutableSet set];
    for (NSURL *URL in bundledFiles) {
        NSString *name = URL.lastPathComponent.precomposedStringWithCanonicalMapping.lowercaseString;
        if (name.length) [bundledNames addObject:name];
        NSString *effectID = AMCloudPluginsEffectIDForXMLURL(URL, nil);
        if (effectID.length) [bundledIDs addObject:effectID.lowercaseString];
    }

    NSMutableSet<NSString *> *targetNames = [NSMutableSet set];
    NSMutableSet<NSString *> *builtinOverridePaths = [NSMutableSet set];
    for (NSDictionary *plugin in plugins) {
        NSString *targetPath = AMCloudPluginsItemTargetPath(plugin);
        if (!targetPath.length) continue;
        NSString *name = targetPath.lastPathComponent.precomposedStringWithCanonicalMapping.lowercaseString;
        if (name.length) [targetNames addObject:name];
        if ([AMCloudPluginsItemKind(plugin) isEqualToString:@"builtin_override"]) {
            NSString *relative = [targetPath substringFromIndex:@"BuiltinEffects/".length];
            NSString *relativeKey = relative.precomposedStringWithCanonicalMapping.lowercaseString;
            if (relativeKey.length) [builtinOverridePaths addObject:relativeKey];
        }
    }

    NSArray<NSURL *> *catalogFiles = AMCloudPluginsFiles(catalogEffectsURL, @"xml");
    NSMutableDictionary<NSString *, NSMutableArray<NSURL *> *> *cloudByID = [NSMutableDictionary dictionary];
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSURL *URL in catalogFiles) {
        NSString *name = URL.lastPathComponent.precomposedStringWithCanonicalMapping.lowercaseString;
        if (!name.length || [bundledNames containsObject:name]) continue;
        NSString *effectID = AMCloudPluginsEffectIDForXMLURL(URL, nil);
        if (!effectID.length) continue;
        NSString *relative = AMCloudPluginsRelativeFilePath(URL, catalogEffectsURL);
        NSString *relativeKey = relative.precomposedStringWithCanonicalMapping.lowercaseString;
        BOOL isBuiltinOverride = relativeKey.length &&
            [builtinOverridePaths containsObject:relativeKey];
        NSString *key = effectID.lowercaseString;
        NSMutableArray<NSURL *> *files = cloudByID[key];
        if (!files) {
            files = [NSMutableArray array];
            cloudByID[key] = files;
        }
        [files addObject:URL];
    }

    for (NSString *effectID in cloudByID) {
        NSArray<NSURL *> *files = cloudByID[effectID];
        if ([bundledIDs containsObject:effectID]) {
            // Official ids must stay at their IPA filename. A custom entry
            // using the exact official id is not a second effect.
            for (NSURL *URL in files) {
                NSString *relative = AMCloudPluginsRelativeFilePath(URL, catalogEffectsURL);
                NSString *relativeKey = relative.precomposedStringWithCanonicalMapping.lowercaseString;
                if ([builtinOverridePaths containsObject:relativeKey]) continue;
                if (![manager removeItemAtURL:URL error:error]) return NO;
            }
            continue;
        }
        NSMutableArray<NSURL *> *primaryFiles = [NSMutableArray array];
        for (NSURL *URL in files) {
            NSString *name = URL.lastPathComponent.precomposedStringWithCanonicalMapping.lowercaseString;
            if ([targetNames containsObject:name]) [primaryFiles addObject:URL];
        }
        if (primaryFiles.count > 1) {
            if (error) *error = AMCloudPluginsValidationError(
                [NSString stringWithFormat:@"Cloud catalog contains multiple primary XML files for effect id %@", effectID]);
            return NO;
        }
        NSURL *keep = primaryFiles.firstObject ?: files.firstObject;
        for (NSURL *URL in files) {
            if ([URL isEqual:keep]) continue;
            if (![manager removeItemAtURL:URL error:error]) return NO;
        }
    }
    return YES;
}

static BOOL AMCloudPluginsValidateCatalogIdentity(
    NSArray<NSDictionary<NSString *, id> *> *plugins,
    NSURL *bundledEffectsURL, NSURL *itemsRootURL, NSError **error) {
    NSMutableSet<NSString *> *targetPaths = [NSMutableSet set];
    NSMutableSet<NSString *> *effectIDs = [NSMutableSet set];
    NSMutableSet<NSString *> *bundledEffectIDs = [NSMutableSet set];
    for (NSURL *URL in AMCloudPluginsFiles(bundledEffectsURL, @"xml")) {
        NSString *bundledID = AMCloudPluginsEffectIDForXMLURL(URL, nil);
        if (bundledID.length) [bundledEffectIDs addObject:bundledID.lowercaseString];
    }
    for (NSDictionary *plugin in plugins) {
        NSString *kind = AMCloudPluginsItemKind(plugin);
        NSString *targetPath = AMCloudPluginsItemTargetPath(plugin);
        NSString *effectID = AMCloudPluginsItemEffectID(plugin);
        if ([kind isEqualToString:@"custom_plugin"] && effectID.length &&
            [bundledEffectIDs containsObject:effectID.lowercaseString]) {
            if (error) *error = AMCloudPluginsValidationErrorForItem(
                @"Custom plugin cannot reuse an IPA built-in effect id; publish it as builtin_override with the original official path",
                plugin, effectID, nil);
            return NO;
        }
        if (AMCloudPluginsCustomPluginTargetsBundledEffect(plugin)) {
            NSURL *bundledURL = AMCloudPluginsBuiltinTargetURL(
                bundledEffectsURL, targetPath);
            NSString *bundledID = AMCloudPluginsEffectIDForXMLURL(bundledURL, nil);
            if (error) *error = AMCloudPluginsValidationErrorForItem(
                @"Custom plugins may not replace a bundled official effect; publish it as builtin_override with the original official effect id",
                plugin, bundledID, bundledURL);
            return NO;
        }
        BOOL tracksTarget = targetPath.length > 0 || effectID.length > 0;
        if (!tracksTarget) continue;
        NSString *pathKey = targetPath.lowercaseString;
        NSString *idKey = effectID.lowercaseString;
        if ((pathKey.length && [targetPaths containsObject:pathKey]) ||
            (idKey.length && [effectIDs containsObject:idKey])) {
            if (error) *error = AMCloudPluginsValidationError(
                @"Conflicting cloud plugin targetPath or effectId");
            return NO;
        }
        if (pathKey.length) [targetPaths addObject:pathKey];
        if (idKey.length) [effectIDs addObject:idKey];
        if (![kind isEqualToString:@"builtin_override"] &&
            !([kind isEqualToString:@"custom_plugin"] &&
              AMCloudPluginsItemAllowsLegacyPathOverride(plugin))) continue;
        NSString *pluginID = [plugin[@"id"] isKindOfClass:NSString.class] ? plugin[@"id"] : nil;
        NSString *versionID = AMCloudPluginsItemVersionID(plugin);
        NSURL *versionURL = [[[[itemsRootURL URLByAppendingPathComponent:pluginID isDirectory:YES]
            URLByAppendingPathComponent:@"versions" isDirectory:YES]
            URLByAppendingPathComponent:versionID isDirectory:YES] URLByStandardizingPath];
        BOOL valid = [kind isEqualToString:@"builtin_override"]
            ? AMCloudPluginsValidateBuiltinOverride(plugin, versionURL,
                                                    bundledEffectsURL, error)
            : AMCloudPluginsValidateLegacyCustomOverride(plugin, versionURL,
                                                         bundledEffectsURL, error);
        if (!valid) return NO;
    }
    return YES;
}

static void AMCloudPluginsSetActiveState(NSDictionary<NSString *, id> *state,
                                         NSURL *effectsURL,
                                         uint64_t authorizationGeneration) {
    AMCloudPluginsClearRuntimeCaches();
    @synchronized (NSBundle.class) {
        AMCloudActiveState = [state copy];
        AMCloudActiveEffectsURL = effectsURL;
        AMCloudActiveAuthorizationGeneration = authorizationGeneration;
    }
}

void AMCloudPluginsSetAuthorizationGeneration(uint64_t generation) {
    @synchronized (NSBundle.class) {
        if (AMCloudAuthorizationGeneration != generation) {
            AMCloudPluginsClearRuntimeCaches();
        }
        AMCloudAuthorizationGeneration = generation;
    }
}

static uint64_t AMCloudPluginsAuthorizationGeneration(void) {
    @synchronized (NSBundle.class) {
        return AMCloudAuthorizationGeneration;
    }
}

static BOOL AMCloudPluginsActivatePersistedState(NSString *releaseID, NSString *sha256,
                                                  NSString *authorizationKey,
                                                  uint64_t authorizationGeneration) {
    NSFileManager *manager = NSFileManager.defaultManager;
    BOOL markerExists = NO;
    if (!AMCloudPluginsGetItemExistence(
            manager, AMCloudPluginsRevocationURL(), &markerExists) || markerExists) {
        AMCloudPluginsSetActiveState(nil, nil, 0);
        return NO;
    }
    NSData *data = [NSData dataWithContentsOfURL:AMCloudPluginsStateURL()];
    id object = data.length
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *state = [object isKindOfClass:NSDictionary.class] ? object : nil;
    NSString *storedReleaseID = [state[@"release_id"] isKindOfClass:NSString.class]
        ? state[@"release_id"] : nil;
    NSString *storedSHA = [state[@"sha256"] isKindOfClass:NSString.class]
        ? [state[@"sha256"] lowercaseString] : nil;
    NSString *storedKey = [state[@"authorization_key"] isKindOfClass:NSString.class]
        ? state[@"authorization_key"] : nil;
    if (![storedReleaseID isEqualToString:releaseID] ||
        ![storedSHA isEqualToString:sha256.lowercaseString] ||
        ![storedKey isEqualToString:authorizationKey.lowercaseString]) {
        AMCloudPluginsSetActiveState(nil, nil, 0);
        return NO;
    }
    NSURL *effectsURL = [[[[AMCloudPluginsRootURL()
        URLByAppendingPathComponent:@"releases" isDirectory:YES]
        URLByAppendingPathComponent:storedReleaseID isDirectory:YES]
        URLByAppendingPathComponent:@"BuiltinEffects" isDirectory:YES]
        URLByStandardizingPath];
    NSNumber *directory = nil;
    if (![effectsURL getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil] ||
        !directory.boolValue) {
        AMCloudPluginsSetActiveState(nil, nil, 0);
        return NO;
    }
    NSString *storedFingerprint = [state[@"bundled_effects_fingerprint"] isKindOfClass:NSString.class]
        ? [state[@"bundled_effects_fingerprint"] lowercaseString] : nil;
    NSString *currentFingerprint = AMCloudPluginsBundledEffectsFingerprint(
        AMCloudPluginsBundledEffectsURL());
    if (!storedFingerprint.length || !currentFingerprint.length ||
        ![storedFingerprint isEqualToString:currentFingerprint] ||
        !AMCloudPluginsCatalogContainsBundledEffects(
            effectsURL, AMCloudPluginsBundledEffectsURL())) {
        // Legacy release state predates the merged-catalog fingerprint. Do
        // not restore it after a covered install: it may be a partial effect
        // directory that hides official XML files shipped by the new IPA.
        AMCloudPluginsSetActiveState(nil, nil, 0);
        AMCloudPluginsInvalidateStaleCatalog(manager);
        return NO;
    }
    if (authorizationGeneration != AMCloudPluginsAuthorizationGeneration()) return NO;
    AMCloudPluginsSetActiveState(state, effectsURL, authorizationGeneration);
    return YES;
}

static BOOL AMCloudPluginsActivatePersistedCatalog(
    NSString *authorizationKey, uint64_t authorizationGeneration) {
    NSFileManager *manager = NSFileManager.defaultManager;
    BOOL markerExists = NO;
    if (!AMCloudPluginsGetItemExistence(
            manager, AMCloudPluginsRevocationURL(), &markerExists) || markerExists) {
        AMCloudPluginsSetActiveState(nil, nil, 0);
        return NO;
    }
    NSData *data = [NSData dataWithContentsOfURL:AMCloudPluginsStateURL()];
    id object = data.length
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *state = [object isKindOfClass:NSDictionary.class] ? object : nil;
    NSNumber *protocol = [state[@"protocol_version"] isKindOfClass:NSNumber.class]
        ? state[@"protocol_version"] : nil;
    NSString *storedKey = [state[@"authorization_key"] isKindOfClass:NSString.class]
        ? [state[@"authorization_key"] lowercaseString] : nil;
    NSArray *plugins = [state[@"plugins"] isKindOfClass:NSArray.class] ? state[@"plugins"] : nil;
    if (protocol.integerValue != AMCloudPluginsCatalogProtocolVersion || !plugins ||
        ![storedKey isEqualToString:authorizationKey.lowercaseString]) {
        // A catalog generated by an older overlay implementation can make
        // native effect discovery resolve every entry through the same cached
        // resource. Covered installs preserve Application Support, so discard
        // the old catalog and let the next manifest sync recreate it.
        AMCloudPluginsSetActiveState(nil, nil, 0);
        AMCloudPluginsInvalidateStaleCatalog(manager);
        return NO;
    }
    NSString *storedFingerprint = [state[@"bundled_effects_fingerprint"] isKindOfClass:NSString.class]
        ? [state[@"bundled_effects_fingerprint"] lowercaseString] : nil;
    NSString *currentFingerprint = AMCloudPluginsBundledEffectsFingerprint(
        AMCloudPluginsBundledEffectsURL());
    if (!storedFingerprint.length || !currentFingerprint.length ||
        ![storedFingerprint isEqualToString:currentFingerprint]) {
        // The IPA was replaced while the app data survived (common with a
        // covered install). Never let the old merged catalog hide resources
        // from the new IPA; the next manifest sync will rebuild it atomically.
        AMCloudPluginsSetActiveState(nil, nil, 0);
        AMCloudPluginsInvalidateStaleCatalog(manager);
        return NO;
    }
    NSURL *persistedEffectsURL = [AMCloudPluginsCatalogURL()
        URLByAppendingPathComponent:@"BuiltinEffects" isDirectory:YES];
    if (!AMCloudPluginsCatalogContainsBundledEffects(
            persistedEffectsURL, AMCloudPluginsBundledEffectsURL())) {
        // Older catalogs could contain only cloud-delivered files. The root
        // NSBundle hook exposes the catalog directory, so any omitted IPA
        // resource becomes an unresolved effect in existing projects.
        AMCloudPluginsSetActiveState(nil, nil, 0);
        AMCloudPluginsInvalidateStaleCatalog(manager);
        return NO;
    }
    for (NSDictionary *plugin in plugins) {
        if (![plugin isKindOfClass:NSDictionary.class] ||
            !AMCloudPluginsCatalogEntryIsSafe(plugin)) {
            AMCloudPluginsSetActiveState(nil, nil, 0);
            return NO;
        }
    }
    NSError *identityError = nil;
    if (!AMCloudPluginsValidateCatalogIdentity(
            plugins, AMCloudPluginsBundledEffectsURL(), AMCloudPluginsItemsURL(),
            &identityError)) {
        AMCloudPluginsSetActiveState(nil, nil, 0);
        return NO;
    }
    NSURL *effectsURL = persistedEffectsURL;
    NSNumber *directory = nil;
    if (![effectsURL getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil] ||
        !directory.boolValue ||
        authorizationGeneration != AMCloudPluginsAuthorizationGeneration()) return NO;
    AMCloudPluginsSetActiveState(state, effectsURL, authorizationGeneration);
    return YES;
}

BOOL AMCloudPluginsRestoreInstalledReleaseForAuthorization(
    NSString *authorizationKey, uint64_t authorizationGeneration) {
    if (!AMCloudPluginAuthorizationKeyIsSafe(authorizationKey) ||
        authorizationGeneration == 0) return NO;
    __block BOOL restored = NO;
    AMCloudPluginsPerformMutation(^{
        NSData *data = [NSData dataWithContentsOfURL:AMCloudPluginsStateURL()];
        id object = data.length
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *state = [object isKindOfClass:NSDictionary.class] ? object : nil;
        NSNumber *protocol = [state[@"protocol_version"] isKindOfClass:NSNumber.class]
            ? state[@"protocol_version"] : nil;
        if (protocol.integerValue == AMCloudPluginsCatalogProtocolVersion) {
            restored = AMCloudPluginsActivatePersistedCatalog(
                authorizationKey, authorizationGeneration);
            return;
        }
        if (protocol) {
            AMCloudPluginsSetActiveState(nil, nil, 0);
            AMCloudPluginsInvalidateStaleCatalog(NSFileManager.defaultManager);
            return;
        }
        // Legacy full-release state predates the per-effect catalog and may
        // contain duplicate official XML aliases. Never expose it during
        // startup; the next manifest sync will rebuild a clean catalog (or
        // leave the IPA baseline active when cloud access is unavailable).
        NSFileManager *manager = NSFileManager.defaultManager;
        AMCloudPluginsSetActiveState(nil, nil, 0);
        AMCloudPluginsInvalidateStaleCatalog(manager);
        [manager removeItemAtURL:[AMCloudPluginsRootURL()
            URLByAppendingPathComponent:@"releases" isDirectory:YES] error:nil];
    });
    return restored;
}

BOOL AMCloudPluginsInstallItemArchive(NSURL *archiveURL, NSString *pluginID,
                                      NSString *versionID, NSString *sha256,
                                      NSError **error) {
    return AMCloudPluginsInstallItemArchiveWithMetadata(
        archiveURL, pluginID, versionID, sha256, nil, error);
}

BOOL AMCloudPluginsInstallItemArchiveWithMetadata(
    NSURL *archiveURL, NSString *pluginID, NSString *versionID, NSString *sha256,
    NSDictionary<NSString *, id> *metadata, NSError **error) {
    if (!archiveURL || !AMCloudPluginReleaseIDIsSafe(pluginID) ||
        !AMCloudPluginReleaseIDIsSafe(versionID) ||
        !AMCloudPluginAuthorizationKeyIsSafe(sha256)) {
        if (error) *error = [NSError errorWithDomain:AMProjImportArchiveErrorDomain
            code:AMProjImportArchiveErrorInvalidArgument
            userInfo:@{NSLocalizedDescriptionKey: @"Cloud plugin item metadata is invalid"}];
        return NO;
    }
    if (metadata && ![metadata isKindOfClass:NSDictionary.class]) {
        if (error) *error = AMCloudPluginsValidationError(
            @"Cloud plugin item metadata must be an object");
        return NO;
    }
    NSString *kind = AMCloudPluginsItemKind(metadata ?: @{});
    if (![kind isEqualToString:@"custom_plugin"] &&
        ![kind isEqualToString:@"builtin_override"]) {
        if (error) *error = AMCloudPluginsValidationError(
            @"Cloud plugin item kind is invalid");
        return NO;
    }
    NSString *effectID = AMCloudPluginsItemEffectID(metadata ?: @{});
    NSString *targetPath = AMCloudPluginsItemTargetPath(metadata ?: @{});
    if ([kind isEqualToString:@"builtin_override"] &&
        (!effectID.length || !targetPath.length)) {
        if (error) *error = AMCloudPluginsValidationError(
            @"Builtin override metadata is incomplete");
        return NO;
    }
    NSDictionary *validationPlugin = @{
        @"id": pluginID,
        @"version_id": versionID,
        @"sha256": sha256.lowercaseString,
        @"kind": kind,
        @"effect_id": effectID ?: @"",
        @"target_path": targetPath ?: @""
    };
    if (AMCloudPluginsCustomPluginTargetsBundledEffect(validationPlugin)) {
        NSURL *bundledURL = AMCloudPluginsBuiltinTargetURL(
            AMCloudPluginsBundledEffectsURL(), targetPath);
        NSString *bundledID = AMCloudPluginsEffectIDForXMLURL(bundledURL, nil);
        if (error) *error = AMCloudPluginsValidationErrorForItem(
            @"Custom plugins may not replace a bundled official effect; publish it as builtin_override with the original official effect id",
            validationPlugin, bundledID, bundledURL);
        return NO;
    }
    __block BOOL installed = NO;
    __block NSError *installError = nil;
    AMCloudPluginsPerformMutation(^{
        NSFileManager *manager = NSFileManager.defaultManager;
        NSURL *itemsURL = AMCloudPluginsItemsURL();
        NSURL *pluginURL = [itemsURL URLByAppendingPathComponent:pluginID isDirectory:YES];
        NSURL *versionsURL = [pluginURL URLByAppendingPathComponent:@"versions" isDirectory:YES];
        NSURL *stagingRoot = [AMCloudPluginsRootURL()
            URLByAppendingPathComponent:@"item-staging" isDirectory:YES];
        for (NSURL *URL in @[AMCloudPluginsRootURL(), itemsURL, pluginURL, versionsURL, stagingRoot]) {
            if (![manager createDirectoryAtURL:URL withIntermediateDirectories:YES
                                    attributes:nil error:&installError]) return;
        }
        NSURL *stagingURL = [stagingRoot URLByAppendingPathComponent:
            NSUUID.UUID.UUIDString.lowercaseString isDirectory:YES];
        NSDictionary *metrics = nil;
        if (!AMProjExtractPluginArchive(archiveURL, stagingURL, &metrics, &installError)) return;

        if ([kind isEqualToString:@"builtin_override"] &&
            !AMCloudPluginsValidateBuiltinOverride(
                validationPlugin, stagingURL, AMCloudPluginsBundledEffectsURL(),
                &installError)) {
            [manager removeItemAtURL:stagingURL error:nil];
            return;
        }
        NSURL *finalURL = [versionsURL URLByAppendingPathComponent:versionID isDirectory:YES];
        [manager removeItemAtURL:finalURL error:nil];
        if (![manager moveItemAtURL:stagingURL toURL:finalURL error:&installError]) return;
        NSMutableDictionary *storedMetadata = [@{
            @"plugin_id": pluginID, @"version_id": versionID,
            @"sha256": sha256.lowercaseString,
            @"installed_at": @((long long)NSDate.date.timeIntervalSince1970),
            @"kind": kind
        } mutableCopy];
        if (effectID.length) storedMetadata[@"effect_id"] = effectID;
        if (targetPath.length) storedMetadata[@"target_path"] = targetPath;
        if (AMCloudPluginsItemAllowsLegacyPathOverride(metadata)) {
            storedMetadata[@"legacy_path_override"] = @YES;
        }
        if (AMCloudPluginsItemRestartRequired(metadata)) {
            storedMetadata[@"restart_required"] = @YES;
        }
        NSData *metadataData = [NSJSONSerialization dataWithJSONObject:storedMetadata options:0
                                                                  error:&installError];
        NSURL *metadataURL = [finalURL URLByAppendingPathComponent:@"item.json"];
        if (!metadataData || ![metadataData writeToURL:metadataURL
                                               options:NSDataWritingAtomic error:&installError]) {
            [manager removeItemAtURL:finalURL error:nil];
            return;
        }
        NSArray<NSURL *> *versions = [manager contentsOfDirectoryAtURL:versionsURL
                                             includingPropertiesForKeys:nil options:0 error:nil];
        for (NSURL *URL in versions) {
            if (![URL.lastPathComponent isEqualToString:versionID]) {
                [manager removeItemAtURL:URL error:nil];
            }
        }
        installed = YES;
    });
    if (!installed && error) *error = installError;
    return installed;
}

static NSURL *AMCloudPluginsBundledEffectsURL(void) {
    NSURL *URL = [NSBundle.mainBundle.resourceURL
        URLByAppendingPathComponent:@"BuiltinEffects" isDirectory:YES];
    NSNumber *directory = nil;
    return [URL getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil] &&
        directory.boolValue ? URL : nil;
}

static BOOL AMCloudPluginsCopyCatalogDirectorySkippingPaths(
    NSFileManager *manager, NSURL *sourceURL, NSURL *destinationURL,
    BOOL replaceExisting, NSSet<NSString *> *skipRelativePaths,
    NSURL *sourceRootURL, NSError **error) {
    NSArray<NSURL *> *children = [manager contentsOfDirectoryAtURL:sourceURL
        includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:error];
    if (!children) return NO;
    for (NSURL *source in children) {
        NSNumber *directory = nil;
        if (![source getResourceValue:&directory forKey:NSURLIsDirectoryKey error:error]) return NO;
        NSURL *destination = [destinationURL URLByAppendingPathComponent:source.lastPathComponent
                                                              isDirectory:directory.boolValue];
        if (directory.boolValue) {
            if (![manager createDirectoryAtURL:destination withIntermediateDirectories:YES
                                    attributes:nil error:error]) return NO;
            if (!AMCloudPluginsCopyCatalogDirectorySkippingPaths(
                    manager, source, destination, replaceExisting, skipRelativePaths,
                    sourceRootURL, error)) return NO;
            continue;
        }
        if ([source.lastPathComponent isEqualToString:@"item.json"]) continue;
        NSString *relative = AMCloudPluginsRelativeFilePath(source, sourceRootURL);
        NSString *relativeKey = relative.precomposedStringWithCanonicalMapping.lowercaseString;
        if (relativeKey.length && [skipRelativePaths containsObject:relativeKey]) continue;
        BOOL destinationExists = NO;
        if (!AMCloudPluginsGetItemExistence(manager, destination, &destinationExists)) return NO;
        if (destinationExists) {
			if (replaceExisting) {
				if (![manager removeItemAtURL:destination error:error] ||
					![manager copyItemAtURL:source toURL:destination error:error]) return NO;
				continue;
			}
            NSData *existing = [NSData dataWithContentsOfURL:destination options:0 error:error];
            NSData *incoming = [NSData dataWithContentsOfURL:source options:0 error:error];
            if (!existing || !incoming || ![existing isEqualToData:incoming]) {
                if (error && !*error) *error = [NSError errorWithDomain:NSCocoaErrorDomain
                    code:NSFileWriteFileExistsError
                    userInfo:@{NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:@"Plugin dependency conflict: %@",
                                                   source.lastPathComponent ?: @""]}];
                return NO;
            }
            continue;
        }
        if (![manager copyItemAtURL:source toURL:destination error:error]) return NO;
    }
    return YES;
}

static BOOL AMCloudPluginsCopyCatalogDirectory(NSFileManager *manager,
                                                NSURL *sourceURL,
                                                NSURL *destinationURL,
                                                BOOL replaceExisting,
                                                NSError **error) {
    return AMCloudPluginsCopyCatalogDirectorySkippingPaths(
        manager, sourceURL, destinationURL, replaceExisting, nil, sourceURL, error);
}

static NSArray<NSURL *> *AMCloudPluginsRecursiveFiles(NSURL *directoryURL) {
    if (!directoryURL) return @[];
    NSArray<NSURL *> *children = [NSFileManager.defaultManager
        contentsOfDirectoryAtURL:directoryURL
        includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsRegularFileKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    for (NSURL *URL in children ?: @[]) {
        NSNumber *isDirectory = nil;
        NSNumber *isRegular = nil;
        if (![URL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil] ||
            ![URL getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil]) {
            continue;
        }
        if (isDirectory.boolValue) {
            [files addObjectsFromArray:AMCloudPluginsRecursiveFiles(URL)];
        } else if (isRegular.boolValue) {
            [files addObject:URL];
        }
    }
    [files sortUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        return [left.path compare:right.path options:NSCaseInsensitiveSearch];
    }];
    return files;
}

static NSString *AMCloudPluginsRelativeFilePath(NSURL *fileURL, NSURL *rootURL) {
    NSString *rootPath = rootURL.URLByStandardizingPath.path;
    NSString *filePath = fileURL.URLByStandardizingPath.path;
    if (!rootPath.length || !filePath.length) return nil;
    NSString *prefix = [rootPath stringByAppendingString:@"/"];
    if (![filePath hasPrefix:prefix]) return nil;
    NSString *relative = [filePath substringFromIndex:prefix.length];
    return AMCloudPluginsResourceNameIsSafe(relative) ? relative : nil;
}

static BOOL AMCloudPluginsValidateCatalogItemFiles(
    NSDictionary *plugin, NSURL *versionURL, NSURL *destinationEffectsURL,
    NSURL *bundledEffectsURL, NSMutableDictionary<NSString *, NSURL *> *resourceOwners,
    NSMutableSet<NSString *> *skipRelativePaths,
    NSError **error) {
    NSURL *sourceEffectsURL = [versionURL URLByAppendingPathComponent:@"BuiltinEffects"
                                                               isDirectory:YES];
    NSNumber *sourceDirectory = nil;
    if (![sourceEffectsURL getResourceValue:&sourceDirectory forKey:NSURLIsDirectoryKey error:nil] ||
        !sourceDirectory.boolValue) {
        if (error) *error = AMCloudPluginsValidationError(
            @"Cloud plugin item has no BuiltinEffects directory");
        return NO;
    }
    NSString *kind = AMCloudPluginsItemKind(plugin);
    NSString *targetPath = AMCloudPluginsItemTargetPath(plugin);
    NSString *targetRelative = targetPath.length
        ? [targetPath substringFromIndex:@"BuiltinEffects/".length] : nil;
    NSString *targetKey = targetRelative.precomposedStringWithCanonicalMapping.lowercaseString;
    BOOL legacyPathOverride = [kind isEqualToString:@"custom_plugin"] &&
        AMCloudPluginsItemAllowsLegacyPathOverride(plugin);
    NSSet<NSString *> *targetReferences = [NSSet set];
    NSSet<NSString *> *targetReferencedEffectIDs = [NSSet set];
    if ((legacyPathOverride || [kind isEqualToString:@"builtin_override"]) &&
        targetPath.length) {
        NSURL *targetURL = AMCloudPluginsBuiltinTargetURL(sourceEffectsURL, targetPath);
        NSError *referenceError = nil;
        targetReferences = AMCloudPluginsReferencedPathsForXMLURL(targetURL, &referenceError);
        if (!targetReferences) {
            if (error) *error = referenceError ?: AMCloudPluginsValidationError(
                @"Legacy plugin target XML resource references are invalid");
            return NO;
        }
        NSError *effectReferenceError = nil;
        targetReferencedEffectIDs = AMCloudPluginsReferencedEffectIDsForXMLURL(
            targetURL, &effectReferenceError);
        if (!targetReferencedEffectIDs) {
            if (error) *error = effectReferenceError ?: AMCloudPluginsValidationError(
                @"Legacy plugin target XML effect references are invalid");
            return NO;
        }
    }
    for (NSURL *xmlURL in AMCloudPluginsRecursiveFiles(sourceEffectsURL)) {
        if ([xmlURL.pathExtension caseInsensitiveCompare:@"xml"] != NSOrderedSame) continue;
        NSError *dependencyError = nil;
        if (!AMCloudPluginsReferencedEffectIDsForXMLURL(xmlURL, &dependencyError)) {
            if (error) *error = dependencyError ?: AMCloudPluginsValidationError(
                @"Cloud plugin dependency XML is invalid");
            return NO;
        }
    }
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *destinationRoot = destinationEffectsURL.URLByStandardizingPath.path;
    NSString *destinationPrefix = [destinationRoot stringByAppendingString:@"/"];
    for (NSURL *sourceURL in AMCloudPluginsRecursiveFiles(sourceEffectsURL)) {
        NSString *relative = AMCloudPluginsRelativeFilePath(sourceURL, sourceEffectsURL);
        NSString *relativeKey = relative.precomposedStringWithCanonicalMapping.lowercaseString;
        if (!relative.length || !relativeKey.length) {
            if (error) *error = AMCloudPluginsValidationError(
                @"Cloud plugin item contains an unsafe resource path");
            return NO;
        }
        NSData *incoming = AMCloudPluginsDataAtURL(sourceURL);
        if (!incoming.length) {
            if (error) *error = AMCloudPluginsValidationError(
                @"Cloud plugin item contains an empty or unreadable resource");
            return NO;
        }
        NSURL *bundledURL = nil;
        if (bundledEffectsURL) {
            bundledURL = [[bundledEffectsURL URLByAppendingPathComponent:relative]
                URLByStandardizingPath];
        }
        NSData *bundled = AMCloudPluginsDataAtURL(bundledURL);
        BOOL baselineIdentical = bundled.length && [bundled isEqualToData:incoming];
        NSURL *ownedURL = resourceOwners[relativeKey];
        NSData *owned = AMCloudPluginsDataAtURL(ownedURL);
        BOOL ownedIdentical = owned.length && [owned isEqualToData:incoming];
        if (ownedURL && !baselineIdentical &&
            !ownedIdentical) {
            if (error) *error = AMCloudPluginsValidationError(
                @"Cloud plugin items contain conflicting resource paths");
            return NO;
        }
        BOOL isXML = [sourceURL.pathExtension caseInsensitiveCompare:@"xml"] == NSOrderedSame;
        BOOL isTarget = [kind isEqualToString:@"builtin_override"] &&
            targetKey.length && [relativeKey isEqualToString:targetKey];
        BOOL isLegacyPathOverride = legacyPathOverride && isXML && targetKey.length &&
            [relativeKey isEqualToString:targetKey];
        if (isLegacyPathOverride) {
            NSString *expectedID = AMCloudPluginsItemEffectID(plugin);
            NSError *sourceError = nil;
            NSString *sourceID = AMCloudPluginsEffectIDForXMLURL(sourceURL, &sourceError);
            if (!expectedID.length || !sourceID.length ||
                [expectedID caseInsensitiveCompare:sourceID] != NSOrderedSame) {
                NSString *detail = sourceID ?: (sourceError.localizedDescription ?: @"missing");
                if (error) *error = AMCloudPluginsValidationErrorForItem(
                    [NSString stringWithFormat:@"Legacy plugin target XML effect id does not match metadata (sourceId=%@)", detail],
                    plugin, sourceID, sourceURL);
                return NO;
            }
        }
        if ([kind isEqualToString:@"builtin_override"] && isXML && !isTarget) {
            if (error) *error = AMCloudPluginsValidationError(
                @"Builtin override may contain only its target XML");
            return NO;
        }
        if (baselineIdentical) {
            // An unchanged IPA resource is a passive dependency. It must not
            // become an owner or overwrite a real cloud override from another
            // catalog item, regardless of catalog ordering.
            if (skipRelativePaths) [skipRelativePaths addObject:relativeKey];
            continue;
        }
        if (!ownedURL && resourceOwners) resourceOwners[relativeKey] = sourceURL;
        NSURL *destinationURL = [[destinationEffectsURL URLByAppendingPathComponent:relative]
            URLByStandardizingPath];
        NSString *destinationPath = destinationURL.path;
        if (!destinationPath.length || ![destinationPath hasPrefix:destinationPrefix]) {
            if (error) *error = AMCloudPluginsValidationError(
                @"Cloud plugin item escaped BuiltinEffects");
            return NO;
        }
        BOOL destinationExists = NO;
        if (!AMCloudPluginsGetItemExistence(manager, destinationURL, &destinationExists)) {
            if (error) *error = AMCloudPluginsValidationError(
                @"Unable to inspect an existing BuiltinEffects resource");
            return NO;
        }
        if (!destinationExists) continue;
        BOOL isLegacyOfficialDependency = legacyPathOverride && isXML && !isTarget &&
            AMCloudPluginsLegacyXMLCanOverrideBundledOfficial(
                sourceURL, destinationURL, bundledURL, targetReferencedEffectIDs);
        NSArray<NSString *> *relativeComponents = relative.pathComponents;
        // Legacy effect packages can carry both thumbnails and raster
        // textures under BuiltinEffects/resource. Keep the allow-list narrow
        // to image formats; arbitrary binary/resource replacement remains a
        // conflict and is rejected.
        BOOL imageReplacement = !isXML && relativeComponents.count > 1 &&
            ([sourceURL.pathExtension caseInsensitiveCompare:@"png"] == NSOrderedSame ||
             [sourceURL.pathExtension caseInsensitiveCompare:@"jpg"] == NSOrderedSame ||
             [sourceURL.pathExtension caseInsensitiveCompare:@"webp"] == NSOrderedSame);
        BOOL isReferencedByTarget = [targetReferences containsObject:relativeKey];
        BOOL isLegacyImageReplacement = legacyPathOverride && imageReplacement &&
            isReferencedByTarget && bundled.length;
        BOOL isBuiltinImageReplacement = [kind isEqualToString:@"builtin_override"] &&
            imageReplacement && isReferencedByTarget && bundled.length;
        BOOL isSharedNewResource = !bundled.length && ownedURL && ownedIdentical;
        if (!isSharedNewResource && !isTarget && !isLegacyPathOverride &&
            !isLegacyOfficialDependency &&
            !isBuiltinImageReplacement &&
            !isLegacyImageReplacement) {
            if (error) *error = AMCloudPluginsValidationError(
                @"Cloud plugin items contain conflicting resource paths");
            return NO;
        }
    }
    return YES;
}

BOOL AMCloudPluginsActivateCatalog(NSArray<NSDictionary<NSString *,id> *> *plugins,
                                   NSNumber *revision, NSString *authorizationKey,
                                   uint64_t authorizationGeneration,
                                   AMCloudPluginsCommitGuard commitGuard,
                                   NSError **error) {
    if (![plugins isKindOfClass:NSArray.class] ||
        !AMCloudPluginAuthorizationKeyIsSafe(authorizationKey) ||
        authorizationGeneration == 0 || !commitGuard) return NO;
    for (NSDictionary *plugin in plugins) {
        if (![plugin isKindOfClass:NSDictionary.class] ||
            !AMCloudPluginsCatalogEntryIsSafe(plugin)) return NO;
    }
    __block BOOL activated = NO;
    __block NSError *activationError = nil;
    AMCloudPluginsPerformMutation(^{
        NSFileManager *manager = NSFileManager.defaultManager;
        NSURL *rootURL = AMCloudPluginsRootURL();
        NSURL *stagingRoot = [rootURL URLByAppendingPathComponent:@"catalog-staging"
                                                      isDirectory:YES];
        [manager createDirectoryAtURL:stagingRoot withIntermediateDirectories:YES
                            attributes:nil error:&activationError];
        if (activationError) return;
        NSURL *stagingURL = [stagingRoot URLByAppendingPathComponent:
            NSUUID.UUID.UUIDString.lowercaseString isDirectory:YES];
        NSURL *effectsURL = [stagingURL URLByAppendingPathComponent:@"BuiltinEffects"
                                                        isDirectory:YES];
        if (![manager createDirectoryAtURL:effectsURL withIntermediateDirectories:YES
                                attributes:nil error:&activationError]) return;
		NSURL *bundledEffectsURL = AMCloudPluginsBundledEffectsURL();
		if (!bundledEffectsURL || !AMCloudPluginsCopyCatalogDirectory(
				manager, bundledEffectsURL, effectsURL, NO, &activationError)) {
			[manager removeItemAtURL:stagingURL error:nil];
			return;
		}
        if (!AMCloudPluginsValidateCatalogIdentity(
				plugins, bundledEffectsURL, AMCloudPluginsItemsURL(), &activationError)) {
			[manager removeItemAtURL:stagingURL error:nil];
			return;
		}
        NSMutableArray *statePlugins = [NSMutableArray arrayWithCapacity:plugins.count];
        NSMutableDictionary<NSString *, NSURL *> *resourceOwners = [NSMutableDictionary dictionary];
        for (NSDictionary *plugin in plugins) {
            NSString *pluginID = plugin[@"id"];
            NSString *versionID = AMCloudPluginsItemVersionID(plugin);
            NSString *sha = AMCloudPluginsItemSHA(plugin);
            NSURL *versionURL = [[[[AMCloudPluginsItemsURL()
                URLByAppendingPathComponent:pluginID isDirectory:YES]
                URLByAppendingPathComponent:@"versions" isDirectory:YES]
                URLByAppendingPathComponent:versionID isDirectory:YES] URLByStandardizingPath];
            NSData *metadataData = [NSData dataWithContentsOfURL:
                [versionURL URLByAppendingPathComponent:@"item.json"]];
            NSDictionary *metadata = metadataData.length ?
                [NSJSONSerialization JSONObjectWithData:metadataData options:0 error:nil] : nil;
            if (![metadata[@"plugin_id"] isEqualToString:pluginID] ||
                ![metadata[@"version_id"] isEqualToString:versionID] ||
                ![[metadata[@"sha256"] lowercaseString] isEqualToString:sha]) {
                activationError = [NSError errorWithDomain:NSCocoaErrorDomain
                    code:NSFileReadCorruptFileError
                    userInfo:@{NSLocalizedDescriptionKey: @"Installed plugin item is incomplete"}];
                break;
            }
            NSURL *sourceEffects = [versionURL URLByAppendingPathComponent:@"BuiltinEffects"
                                                               isDirectory:YES];
			NSMutableSet<NSString *> *skipRelativePaths = [NSMutableSet set];
			if (!AMCloudPluginsValidateCatalogItemFiles(
					plugin, versionURL, effectsURL, bundledEffectsURL,
					resourceOwners, skipRelativePaths, &activationError)) break;
			if (!AMCloudPluginsCopyCatalogDirectorySkippingPaths(
					manager, sourceEffects, effectsURL, YES, skipRelativePaths,
					sourceEffects, &activationError)) break;
            NSMutableDictionary *statePlugin = [@{ @"id": pluginID,
                @"version_id": versionID, @"sha256": sha } mutableCopy];
            NSString *kind = AMCloudPluginsItemKind(plugin);
            statePlugin[@"kind"] = kind;
            NSString *effectID = AMCloudPluginsItemEffectID(plugin);
            NSString *targetPath = AMCloudPluginsItemTargetPath(plugin);
            if (effectID.length) statePlugin[@"effect_id"] = effectID;
            if (targetPath.length) statePlugin[@"target_path"] = targetPath;
            if (AMCloudPluginsItemAllowsLegacyPathOverride(plugin)) {
                statePlugin[@"legacy_path_override"] = @YES;
            }
            if (AMCloudPluginsItemRestartRequired(plugin)) statePlugin[@"restart_required"] = @YES;
            [statePlugins addObject:statePlugin];
        }
        if (!activationError && !AMCloudPluginsDedupeCatalogRootEffects(
                effectsURL, bundledEffectsURL, plugins, &activationError)) {
            // Keep activation atomic: a malformed historical item must not
            // leave a partially deduplicated catalog on disk.
            [manager removeItemAtURL:stagingURL error:nil];
            return;
        }
        if (activationError) {
            [manager removeItemAtURL:stagingURL error:nil];
            return;
        }
        NSObject *commitLock = [NSObject new];
        __block BOOL commitInvoked = NO;
        __block BOOL commitGuardReturned = NO;
        dispatch_block_t commit = ^{
            @synchronized (commitLock) {
                if (commitGuardReturned || commitInvoked) return;
                commitInvoked = YES;
                NSURL *catalogURL = AMCloudPluginsCatalogURL();
                NSURL *oldURL = [rootURL URLByAppendingPathComponent:@"catalog-old"
                                                          isDirectory:YES];
                [manager removeItemAtURL:oldURL error:nil];
                BOOL catalogExists = NO;
                if (AMCloudPluginsGetItemExistence(manager, catalogURL, &catalogExists) &&
                    catalogExists && ![manager moveItemAtURL:catalogURL toURL:oldURL
                                                  error:&activationError]) return;
                if (![manager moveItemAtURL:stagingURL toURL:catalogURL
                                      error:&activationError]) {
                    [manager moveItemAtURL:oldURL toURL:catalogURL error:nil];
                    return;
                }
                NSString *bundledFingerprint = AMCloudPluginsBundledEffectsFingerprint(
                    bundledEffectsURL);
                NSDictionary *state = @{ @"protocol_version": @(AMCloudPluginsCatalogProtocolVersion),
                    @"catalog_revision": revision ?: @0,
                    @"authorization_key": authorizationKey.lowercaseString,
                    @"installed_at": @((long long)NSDate.date.timeIntervalSince1970),
                    @"bundled_effects_fingerprint": bundledFingerprint ?: @"",
                    @"effect_count": @(AMCloudPluginsFiles(
                        [catalogURL URLByAppendingPathComponent:@"BuiltinEffects" isDirectory:YES],
                        @"xml").count), @"plugins": statePlugins };
                NSData *stateData = [NSJSONSerialization dataWithJSONObject:state options:0
                                                                       error:&activationError];
                if (!stateData || ![stateData writeToURL:AMCloudPluginsStateURL()
                                                  options:NSDataWritingAtomic error:&activationError]) {
                    [manager removeItemAtURL:catalogURL error:nil];
                    [manager moveItemAtURL:oldURL toURL:catalogURL error:nil];
                    return;
                }
                // The catalog is now authoritative. Remove legacy full
                // release directories so a stale fallback cannot be reused
                // after a covered install or a protocol downgrade.
                NSURL *legacyReleasesURL = [rootURL URLByAppendingPathComponent:@"releases"
                                                                    isDirectory:YES];
                [manager removeItemAtURL:legacyReleasesURL error:nil];
                [manager removeItemAtURL:oldURL error:nil];
                [manager removeItemAtURL:AMCloudPluginsRevocationURL() error:nil];
                AMCloudPluginsSetActiveState(state,
                    [catalogURL URLByAppendingPathComponent:@"BuiltinEffects" isDirectory:YES],
                    authorizationGeneration);
                activated = YES;
            }
        };
        BOOL authorized = commitGuard(commit);
        @synchronized (commitLock) { commitGuardReturned = YES; }
        if (!authorized || !activated) [manager removeItemAtURL:stagingURL error:nil];
    });
    if (!activated && error) *error = activationError;
    return activated;
}

static NSString *AMCloudPluginsRelativeDirectory(NSString *subdirectory) {
    if (![subdirectory isKindOfClass:NSString.class] || !subdirectory.length ||
        [subdirectory hasPrefix:@"/"] || [subdirectory hasPrefix:@"\\"]) return nil;
    NSString *normalized = [subdirectory stringByReplacingOccurrencesOfString:@"\\"
                                                                    withString:@"/"];
    NSArray<NSString *> *parts = normalized.pathComponents;
    if (!parts.count ||
        [parts.firstObject caseInsensitiveCompare:@"BuiltinEffects"] != NSOrderedSame) {
        return nil;
    }
    NSMutableArray<NSString *> *relative = [NSMutableArray array];
    for (NSUInteger index = 1; index < parts.count; index++) {
        NSString *part = parts[index];
        if (!part.length || [part isEqualToString:@"."] || [part isEqualToString:@".."] ||
            [part containsString:@":"]) return nil;
        [relative addObject:part];
    }
    return [relative componentsJoinedByString:@"/"];
}

static NSURL *AMCloudPluginsActiveDirectoryURL(NSString *subdirectory) {
    NSString *relative = AMCloudPluginsRelativeDirectory(subdirectory);
    if (!relative) return nil;
    NSURL *effectsURL = nil;
    @synchronized (NSBundle.class) {
        if (AMCloudActiveAuthorizationGeneration == AMCloudAuthorizationGeneration) {
            effectsURL = AMCloudActiveEffectsURL;
        }
    }
    if (!effectsURL) return nil;
    NSURL *directoryURL = relative.length
        ? [effectsURL URLByAppendingPathComponent:relative isDirectory:YES] : effectsURL;
    NSNumber *directory = nil;
    if (![directoryURL getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil] ||
        !directory.boolValue) return nil;
    return directoryURL;
}

static NSArray<NSURL *> *AMCloudPluginsFiles(NSURL *directoryURL, NSString *extension) {
    if (!directoryURL) return @[];
    NSString *cacheKey = AMCloudPluginsFilesCacheKey(directoryURL, extension);
    NSArray<NSURL *> *cached = [AMCloudPluginsFilesCache() objectForKey:cacheKey];
    if (cached) return cached;
    NSArray<NSURL *> *contents = [NSFileManager.defaultManager
        contentsOfDirectoryAtURL:directoryURL
      includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                         options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSMutableArray<NSURL *> *URLs = [NSMutableArray array];
    for (NSURL *URL in contents ?: @[]) {
        NSNumber *regular = nil;
        BOOL matchesExtension = !extension.length ||
            [URL.pathExtension caseInsensitiveCompare:extension] == NSOrderedSame;
        if (matchesExtension &&
            [URL getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil] &&
            regular.boolValue) {
            [URLs addObject:URL];
        }
    }
    [URLs sortUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        return [left.lastPathComponent compare:right.lastPathComponent
                                        options:NSCaseInsensitiveSearch];
    }];
    NSArray<NSURL *> *result = [URLs copy];
    [AMCloudPluginsFilesCache() setObject:result forKey:cacheKey];
    return result;
}

static BOOL AMCloudPluginsShouldUseCloudResource(NSURL *cloudURL, NSURL *bundledURL) {
    if (!cloudURL) return NO;
    NSString *cacheKey = AMCloudPluginsResourceDecisionCacheKey(cloudURL, bundledURL);
    NSNumber *cached = [AMCloudPluginsResourceDecisionCache() objectForKey:cacheKey];
    if (cached) return cached.boolValue;
    NSData *cloud = AMCloudPluginsDataAtURL(cloudURL);
    if (!cloud.length) {
        [AMCloudPluginsResourceDecisionCache() setObject:@NO forKey:cacheKey];
        return NO;
    }
    NSData *bundled = AMCloudPluginsDataAtURL(bundledURL);
    BOOL useCloud = !bundled.length || ![cloud isEqualToData:bundled];
    [AMCloudPluginsResourceDecisionCache() setObject:@(useCloud) forKey:cacheKey];
    return useCloud;
}

static NSArray<NSURL *> *AMCloudPluginsMergeResourceURLs(NSArray<NSURL *> *bundled,
                                                          NSArray<NSURL *> *cloud) {
    if (cloud.count == 0) return bundled ?: @[];
    NSMutableDictionary<NSString *, NSURL *> *remaining = [NSMutableDictionary dictionary];
    for (NSURL *URL in cloud) {
        NSString *key = URL.lastPathComponent.precomposedStringWithCanonicalMapping.lowercaseString;
        if (key.length) remaining[key] = URL;
    }
    NSMutableArray<NSURL *> *merged = [NSMutableArray arrayWithCapacity:bundled.count + cloud.count];
    for (NSURL *URL in bundled ?: @[]) {
        NSString *key = URL.lastPathComponent.precomposedStringWithCanonicalMapping.lowercaseString;
        NSURL *replacement = key.length ? remaining[key] : nil;
        if (replacement) {
            [remaining removeObjectForKey:key];
            // The catalog contains a complete baseline copy so it can be
            // rebuilt atomically. Returning that copy for unchanged files
            // changes the resource root seen by Alight Motion and breaks its
            // native recommendation cache. Only expose actual overrides.
            [merged addObject:AMCloudPluginsShouldUseCloudResource(replacement, URL)
                ? replacement : URL];
        } else {
            [merged addObject:URL];
        }
    }
    NSArray<NSURL *> *newURLs = [remaining.allValues
        sortedArrayUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
            return [left.lastPathComponent compare:right.lastPathComponent
                                            options:NSCaseInsensitiveSearch];
        }];
    [merged addObjectsFromArray:newURLs];
    return merged;
}

static BOOL AMCloudPluginsResourceNameIsSafe(NSString *name) {
    if (![name isKindOfClass:NSString.class] || !name.length ||
        [name hasPrefix:@"/"] || [name hasPrefix:@"\\"]) return NO;
    NSString *normalized = [name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    for (NSString *part in normalized.pathComponents) {
        if (!part.length || [part isEqualToString:@"."] || [part isEqualToString:@".."] ||
            [part containsString:@":"]) return NO;
    }
    return YES;
}

static NSURL *AMCloudPluginsResourceURL(NSString *name, NSString *extension,
                                        NSString *subdirectory) {
    if (!AMCloudPluginsResourceNameIsSafe(name)) return nil;
    NSURL *directoryURL = AMCloudPluginsActiveDirectoryURL(subdirectory);
    if (!directoryURL) return nil;
    NSString *relative = extension.length
        ? [name stringByAppendingPathExtension:extension] : name;
    NSURL *candidate = [[directoryURL URLByAppendingPathComponent:relative]
        URLByStandardizingPath];
    NSString *directoryPath = directoryURL.URLByStandardizingPath.path;
    NSString *candidatePath = candidate.path;
    NSString *prefix = [directoryPath stringByAppendingString:@"/"];
    if (!candidatePath.length || ![candidatePath hasPrefix:prefix]) return nil;
    NSNumber *regular = nil;
    if (![candidate getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil] ||
        !regular.boolValue) return nil;
    return candidate;
}

static BOOL AMCloudPluginsEnterBundleHook(void) {
    NSMutableDictionary *dictionary = NSThread.currentThread.threadDictionary;
    if ([dictionary[AMCloudBundleHookGuardKey] boolValue]) return NO;
    dictionary[AMCloudBundleHookGuardKey] = @YES;
    return YES;
}

static void AMCloudPluginsLeaveBundleHook(void) {
    [NSThread.currentThread.threadDictionary removeObjectForKey:AMCloudBundleHookGuardKey];
}

static NSArray<NSURL *> *AMCloudBundleURLsHook(id self, SEL selector,
                                               NSString *extension,
                                               NSString *subdirectory) {
    if (!AMCloudPluginsEnterBundleHook()) {
        return AMCloudOriginalBundleURLs
            ? AMCloudOriginalBundleURLs(self, selector, extension, subdirectory) : @[];
    }
    @try {
        NSArray<NSURL *> *bundled = AMCloudOriginalBundleURLs
            ? AMCloudOriginalBundleURLs(self, selector, extension, subdirectory) : @[];
        if (self != NSBundle.mainBundle ||
            !AMCloudPluginsRelativeDirectory(subdirectory)) return bundled ?: @[];
        NSArray<NSURL *> *cloud = AMCloudPluginsFiles(
            AMCloudPluginsActiveDirectoryURL(subdirectory), extension);
        return AMCloudPluginsMergeResourceURLs(bundled, cloud);
    } @finally {
        AMCloudPluginsLeaveBundleHook();
    }
}

static NSURL *AMCloudBundleURLHook(id self, SEL selector, NSString *name,
                                   NSString *extension, NSString *subdirectory) {
    if (!AMCloudPluginsEnterBundleHook()) {
        return AMCloudOriginalBundleURL
            ? AMCloudOriginalBundleURL(self, selector, name, extension, subdirectory) : nil;
    }
    @try {
        NSURL *bundled = AMCloudOriginalBundleURL
            ? AMCloudOriginalBundleURL(self, selector, name, extension, subdirectory) : nil;
        if (self == NSBundle.mainBundle) {
            if (AMCloudPluginsRelativeDirectory(subdirectory)) {
                NSURL *cloud = AMCloudPluginsResourceURL(name, extension, subdirectory);
                if (AMCloudPluginsShouldUseCloudResource(cloud, bundled)) return cloud;
            }
        }
        return bundled;
    } @finally {
        AMCloudPluginsLeaveBundleHook();
    }
}

static NSArray<NSString *> *AMCloudBundlePathsHook(id self, SEL selector,
                                                    NSString *extension,
                                                    NSString *subdirectory) {
    if (!AMCloudPluginsEnterBundleHook()) {
        return AMCloudOriginalBundlePaths
            ? AMCloudOriginalBundlePaths(self, selector, extension, subdirectory) : @[];
    }
    @try {
        NSArray<NSString *> *bundledPaths = AMCloudOriginalBundlePaths
            ? AMCloudOriginalBundlePaths(self, selector, extension, subdirectory) : @[];
        if (self != NSBundle.mainBundle ||
            !AMCloudPluginsRelativeDirectory(subdirectory)) return bundledPaths ?: @[];
        NSMutableArray<NSURL *> *bundledURLs = [NSMutableArray arrayWithCapacity:bundledPaths.count];
        for (NSString *path in bundledPaths ?: @[]) {
            if (path.length) [bundledURLs addObject:[NSURL fileURLWithPath:path]];
        }
        NSArray<NSURL *> *merged = AMCloudPluginsMergeResourceURLs(
            bundledURLs, AMCloudPluginsFiles(AMCloudPluginsActiveDirectoryURL(subdirectory),
                                             extension));
        NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:merged.count];
        for (NSURL *URL in merged) {
            if (URL.path.length) [paths addObject:URL.path];
        }
        return paths;
    } @finally {
        AMCloudPluginsLeaveBundleHook();
    }
}

static NSString *AMCloudBundlePathHook(id self, SEL selector, NSString *name,
                                       NSString *extension, NSString *subdirectory) {
    if (!AMCloudPluginsEnterBundleHook()) {
        return AMCloudOriginalBundlePath
            ? AMCloudOriginalBundlePath(self, selector, name, extension, subdirectory) : nil;
    }
    @try {
        NSString *bundled = AMCloudOriginalBundlePath
            ? AMCloudOriginalBundlePath(self, selector, name, extension, subdirectory) : nil;
        if (self == NSBundle.mainBundle) {
            if (AMCloudPluginsRelativeDirectory(subdirectory)) {
                NSURL *cloud = AMCloudPluginsResourceURL(name, extension, subdirectory);
                NSURL *bundledURL = bundled.length ? [NSURL fileURLWithPath:bundled] : nil;
                if (AMCloudPluginsShouldUseCloudResource(cloud, bundledURL)) return cloud.path;
            }
        }
        return bundled;
    } @finally {
        AMCloudPluginsLeaveBundleHook();
    }
}

static IMP AMCloudPluginsInstallHook(Class bundleClass, SEL selector, IMP hook) {
    Method method = class_getInstanceMethod(bundleClass, selector);
    if (!method) return NULL;
    IMP original = method_getImplementation(method);
    class_addMethod(bundleClass, selector, hook, method_getTypeEncoding(method));
    if (class_getMethodImplementation(bundleClass, selector) != hook) {
        class_replaceMethod(bundleClass, selector, hook, method_getTypeEncoding(method));
    }
    return original;
}

void AMCloudPluginsInstallBundleHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class bundleClass = object_getClass(NSBundle.mainBundle);
        AMCloudOriginalBundleURLs = (AMCloudBundleURLsIMP)AMCloudPluginsInstallHook(
            bundleClass, @selector(URLsForResourcesWithExtension:subdirectory:),
            (IMP)AMCloudBundleURLsHook);
        AMCloudOriginalBundleURL = (AMCloudBundleURLIMP)AMCloudPluginsInstallHook(
            bundleClass, @selector(URLForResource:withExtension:subdirectory:),
            (IMP)AMCloudBundleURLHook);
        AMCloudOriginalBundlePaths = (AMCloudBundlePathsIMP)AMCloudPluginsInstallHook(
            bundleClass, @selector(pathsForResourcesOfType:inDirectory:),
            (IMP)AMCloudBundlePathsHook);
        AMCloudOriginalBundlePath = (AMCloudBundlePathIMP)AMCloudPluginsInstallHook(
            bundleClass, @selector(pathForResource:ofType:inDirectory:),
            (IMP)AMCloudBundlePathHook);
    });
}

BOOL AMCloudPluginsActivateInstalledRelease(NSString *releaseID, NSString *sha256,
                                             NSString *authorizationKey,
                                             uint64_t authorizationGeneration) {
    if (!AMCloudPluginReleaseIDIsSafe(releaseID) ||
        !AMCloudPluginAuthorizationKeyIsSafe(sha256) ||
        !AMCloudPluginAuthorizationKeyIsSafe(authorizationKey) ||
        authorizationGeneration == 0) return NO;
    __block BOOL activated = NO;
    AMCloudPluginsPerformMutation(^{
        activated = AMCloudPluginsActivatePersistedState(
            releaseID, sha256, authorizationKey, authorizationGeneration);
    });
    return activated;
}

NSDictionary<NSString *, id> *AMCloudPluginsCurrentState(void) {
    @synchronized (NSBundle.class) {
        if (AMCloudActiveAuthorizationGeneration != AMCloudAuthorizationGeneration) return nil;
        return [AMCloudActiveState copy];
    }
}

BOOL AMCloudPluginsInstallArchive(NSURL *archiveURL, NSString *releaseID,
                                  NSString *sha256, NSString *authorizationKey,
                                  uint64_t authorizationGeneration,
                                  AMCloudPluginsCommitGuard commitGuard,
                                  NSError **error) {
    if (!AMCloudPluginReleaseIDIsSafe(releaseID) || sha256.length != 64 ||
        !AMCloudPluginAuthorizationKeyIsSafe(authorizationKey) ||
        authorizationGeneration == 0 || !commitGuard) {
        if (error) {
            *error = [NSError errorWithDomain:AMProjImportArchiveErrorDomain
                                         code:AMProjImportArchiveErrorInvalidArgument
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"Cloud plugin release metadata is invalid"}];
        }
        return NO;
    }
    __block BOOL installed = NO;
    __block NSError *installError = nil;
    AMCloudPluginsPerformMutation(^{
        NSFileManager *manager = NSFileManager.defaultManager;
        NSURL *rootURL = AMCloudPluginsRootURL();
        NSURL *releasesURL = [rootURL URLByAppendingPathComponent:@"releases" isDirectory:YES];
        NSURL *stagingRoot = [rootURL URLByAppendingPathComponent:@"staging" isDirectory:YES];
        for (NSURL *URL in @[rootURL, releasesURL, stagingRoot]) {
            if (![manager createDirectoryAtURL:URL withIntermediateDirectories:YES
                                    attributes:nil error:&installError]) return;
        }
        NSURL *stagingURL = [stagingRoot
            URLByAppendingPathComponent:NSUUID.UUID.UUIDString.lowercaseString isDirectory:YES];
        NSDictionary *metrics = nil;
        if (!AMProjExtractPluginArchive(archiveURL, stagingURL, &metrics, &installError)) return;
        NSURL *stagedEffectsURL = [stagingURL URLByAppendingPathComponent:@"BuiltinEffects"
                                                                  isDirectory:YES];
        if (!AMCloudPluginsDedupeCatalogRootEffects(
                stagedEffectsURL, AMCloudPluginsBundledEffectsURL(), @[], &installError)) {
            [manager removeItemAtURL:stagingURL error:nil];
            return;
        }

        NSObject *commitLock = [NSObject new];
        __block BOOL commitInvoked = NO;
        __block BOOL commitGuardReturned = NO;
        dispatch_block_t commit = ^{
            @synchronized (commitLock) {
                if (commitGuardReturned || commitInvoked) return;
                commitInvoked = YES;
                NSURL *finalURL = [releasesURL URLByAppendingPathComponent:releaseID
                                                               isDirectory:YES];
                [manager removeItemAtURL:finalURL error:nil];
                if (![manager moveItemAtURL:stagingURL toURL:finalURL error:&installError]) {
                    [manager removeItemAtURL:stagingURL error:nil];
                    return;
                }
                NSURL *effectsURL = [finalURL URLByAppendingPathComponent:@"BuiltinEffects"
                                                              isDirectory:YES];
                NSNumber *effectCount = @(AMCloudPluginsFiles(effectsURL, @"xml").count);
                NSDictionary *state = @{
                    @"release_id": releaseID,
                    @"sha256": sha256.lowercaseString,
                    @"authorization_key": authorizationKey.lowercaseString,
                    @"installed_at": @((long long)NSDate.date.timeIntervalSince1970),
                    @"effect_count": effectCount
                };
                NSData *stateData = [NSJSONSerialization dataWithJSONObject:state
                                                                    options:0 error:&installError];
                if (!stateData || ![stateData writeToURL:AMCloudPluginsStateURL()
                                                  options:NSDataWritingAtomic error:&installError]) {
                    [manager removeItemAtURL:finalURL error:nil];
                    return;
                }
                NSURL *revocationURL = AMCloudPluginsRevocationURL();
                BOOL markerExists = NO;
                if (!AMCloudPluginsGetItemExistence(manager, revocationURL,
                                                     &markerExists)) {
                    installError = [NSError errorWithDomain:NSCocoaErrorDomain
                                                       code:NSFileReadUnknownError
                                                   userInfo:@{NSLocalizedDescriptionKey:
                                                       @"Cloud plugin revocation state is unreadable"}];
                    [manager removeItemAtURL:finalURL error:nil];
                    return;
                }
                if (markerExists &&
                    ![manager removeItemAtURL:revocationURL error:&installError]) {
                    BOOL markerKnown = AMCloudPluginsGetItemExistence(
                        manager, revocationURL, &markerExists);
                    if (!markerKnown || markerExists) {
                        if (!installError) {
                            installError = [NSError errorWithDomain:NSCocoaErrorDomain
                                                               code:NSFileWriteUnknownError
                                                           userInfo:@{NSLocalizedDescriptionKey:
                                                               @"Cloud plugin revocation state could not be cleared"}];
                        }
                        [manager removeItemAtURL:finalURL error:nil];
                        return;
                    }
                }
                [rootURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
                AMCloudPluginsSetActiveState(state, effectsURL, authorizationGeneration);

                NSArray<NSURL *> *releases = [manager contentsOfDirectoryAtURL:releasesURL
                                                    includingPropertiesForKeys:nil
                                                                       options:0 error:nil];
                for (NSURL *URL in releases) {
                    if (![URL.lastPathComponent isEqualToString:releaseID]) {
                        [manager removeItemAtURL:URL error:nil];
                    }
                }
                [manager removeItemAtURL:stagingRoot error:nil];
                installed = YES;
            }
        };
        BOOL authorized = commitGuard(commit);
        BOOL commitAccepted = NO;
        @synchronized (commitLock) {
            commitGuardReturned = YES;
            commitAccepted = commitInvoked;
        }
        if (!authorized && commitAccepted && installed) {
            AMCloudPluginsSetActiveState(nil, nil, 0);
            BOOL stateInvalidated = AMCloudPluginsInvalidatePersistedState(manager);
            if (!stateInvalidated) AMCloudPluginsPersistRevocationMarker(manager);
            [manager removeItemAtURL:rootURL error:nil];
            installed = NO;
        }
        if (!authorized || !commitAccepted) {
            [manager removeItemAtURL:stagingURL error:nil];
            installError = [NSError errorWithDomain:NSURLErrorDomain
                                                code:NSURLErrorCancelled
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                @"Cloud plugin install was cancelled"}];
        }
    });
    if (!installed && error) *error = installError;
    return installed;
}

BOOL AMCloudPluginsRemoveAllIf(BOOL (^validator)(void)) {
    __block BOOL removed = NO;
    AMCloudPluginsPerformMutation(^{
        if (validator && !validator()) return;
        NSFileManager *manager = NSFileManager.defaultManager;
        NSURL *rootURL = AMCloudPluginsRootURL();
        AMCloudPluginsSetActiveState(nil, nil, 0);
        BOOL stateInvalidated = AMCloudPluginsInvalidatePersistedState(manager);
        BOOL revocationMarked = stateInvalidated || AMCloudPluginsPersistRevocationMarker(manager);

        BOOL rootExists = NO;
        BOOL rootKnown = AMCloudPluginsGetItemExistence(manager, rootURL, &rootExists);
        if (rootKnown && !rootExists) {
            removed = YES;
            [manager removeItemAtURL:AMCloudPluginsRevocationURL() error:nil];
            return;
        }
        [manager removeItemAtURL:rootURL error:nil];
        rootKnown = AMCloudPluginsGetItemExistence(manager, rootURL, &rootExists);
        removed = rootKnown && !rootExists;
        if (removed && revocationMarked) {
            [manager removeItemAtURL:AMCloudPluginsRevocationURL() error:nil];
        }
    });
    return removed;
}

void AMCloudPluginsRemoveAll(void) {
    AMCloudPluginsRemoveAllIf(nil);
}
