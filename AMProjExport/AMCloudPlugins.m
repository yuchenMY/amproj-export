#import "AMCloudPlugins.h"
#import "AMProjImportArchive.h"

#import <objc/runtime.h>

static NSString *const AMCloudPluginsDirectoryName = @"AMCloudPlugins";
static NSString *const AMCloudPluginsStateName = @"state.json";
static NSString *const AMCloudPluginsRevocationName = @"AMCloudPlugins.revoked";
static NSString *const AMCloudBundleHookGuardKey = @"AMCloudBundleHookGuard";

typedef NSArray<NSURL *> *(*AMCloudBundleURLsIMP)(id, SEL, NSString *, NSString *);
typedef NSURL *(*AMCloudBundleURLIMP)(id, SEL, NSString *, NSString *, NSString *);
typedef NSURL *(*AMCloudBundleURLSimpleIMP)(id, SEL, NSString *, NSString *);
typedef NSArray<NSString *> *(*AMCloudBundlePathsIMP)(id, SEL, NSString *, NSString *);
typedef NSString *(*AMCloudBundlePathIMP)(id, SEL, NSString *, NSString *, NSString *);
typedef NSString *(*AMCloudBundlePathSimpleIMP)(id, SEL, NSString *, NSString *);

static AMCloudBundleURLsIMP AMCloudOriginalBundleURLs = NULL;
static AMCloudBundleURLIMP AMCloudOriginalBundleURL = NULL;
static AMCloudBundleURLSimpleIMP AMCloudOriginalBundleURLSimple = NULL;
static AMCloudBundlePathsIMP AMCloudOriginalBundlePaths = NULL;
static AMCloudBundlePathIMP AMCloudOriginalBundlePath = NULL;
static AMCloudBundlePathSimpleIMP AMCloudOriginalBundlePathSimple = NULL;
static NSURL *AMCloudActiveEffectsURL = nil;
static NSDictionary<NSString *, id> *AMCloudActiveState = nil;
static uint64_t AMCloudAuthorizationGeneration = 0;
static uint64_t AMCloudActiveAuthorizationGeneration = 0;
static void *AMCloudPluginsMutationQueueKey = &AMCloudPluginsMutationQueueKey;

static NSArray<NSURL *> *AMCloudPluginsFiles(NSURL *directoryURL, NSString *extension);

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
    return [version[@"id"] isKindOfClass:NSString.class] ? version[@"id"] : nil;
}

static NSString *AMCloudPluginsItemSHA(NSDictionary *plugin) {
    NSDictionary *version = [plugin[@"version"] isKindOfClass:NSDictionary.class]
        ? plugin[@"version"] : nil;
    return [version[@"sha256"] isKindOfClass:NSString.class]
        ? [version[@"sha256"] lowercaseString] : nil;
}

static BOOL AMCloudPluginsCatalogEntryIsSafe(NSDictionary *plugin) {
    NSString *pluginID = [plugin[@"id"] isKindOfClass:NSString.class] ? plugin[@"id"] : nil;
    return AMCloudPluginReleaseIDIsSafe(pluginID) &&
        AMCloudPluginReleaseIDIsSafe(AMCloudPluginsItemVersionID(plugin)) &&
        AMCloudPluginAuthorizationKeyIsSafe(AMCloudPluginsItemSHA(plugin));
}

static void AMCloudPluginsSetActiveState(NSDictionary<NSString *, id> *state,
                                         NSURL *effectsURL,
                                         uint64_t authorizationGeneration) {
    @synchronized (NSBundle.class) {
        AMCloudActiveState = [state copy];
        AMCloudActiveEffectsURL = effectsURL;
        AMCloudActiveAuthorizationGeneration = authorizationGeneration;
    }
}

void AMCloudPluginsSetAuthorizationGeneration(uint64_t generation) {
    @synchronized (NSBundle.class) {
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
    if (protocol.integerValue != 2 || !plugins ||
        ![storedKey isEqualToString:authorizationKey.lowercaseString]) {
        return NO;
    }
    NSURL *effectsURL = [AMCloudPluginsCatalogURL()
        URLByAppendingPathComponent:@"BuiltinEffects" isDirectory:YES];
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
        if (protocol.integerValue == 2) {
            restored = AMCloudPluginsActivatePersistedCatalog(
                authorizationKey, authorizationGeneration);
            return;
        }
        NSString *releaseID = [state[@"release_id"] isKindOfClass:NSString.class]
            ? state[@"release_id"] : nil;
        NSString *sha256 = [state[@"sha256"] isKindOfClass:NSString.class]
            ? [state[@"sha256"] lowercaseString] : nil;
        NSString *storedKey = [state[@"authorization_key"] isKindOfClass:NSString.class]
            ? [state[@"authorization_key"] lowercaseString] : nil;
        if (!AMCloudPluginReleaseIDIsSafe(releaseID) ||
            !AMCloudPluginAuthorizationKeyIsSafe(sha256) ||
            ![storedKey isEqualToString:authorizationKey.lowercaseString]) return;
        restored = AMCloudPluginsActivatePersistedState(
            releaseID, sha256, authorizationKey, authorizationGeneration);
    });
    return restored;
}

BOOL AMCloudPluginsInstallItemArchive(NSURL *archiveURL, NSString *pluginID,
                                      NSString *versionID, NSString *sha256,
                                      NSError **error) {
    if (!archiveURL || !AMCloudPluginReleaseIDIsSafe(pluginID) ||
        !AMCloudPluginReleaseIDIsSafe(versionID) ||
        !AMCloudPluginAuthorizationKeyIsSafe(sha256)) {
        if (error) *error = [NSError errorWithDomain:AMProjImportArchiveErrorDomain
            code:AMProjImportArchiveErrorInvalidArgument
            userInfo:@{NSLocalizedDescriptionKey: @"Cloud plugin item metadata is invalid"}];
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
        NSURL *finalURL = [versionsURL URLByAppendingPathComponent:versionID isDirectory:YES];
        [manager removeItemAtURL:finalURL error:nil];
        if (![manager moveItemAtURL:stagingURL toURL:finalURL error:&installError]) return;
        NSDictionary *metadata = @{ @"plugin_id": pluginID, @"version_id": versionID,
            @"sha256": sha256.lowercaseString,
            @"installed_at": @((long long)NSDate.date.timeIntervalSince1970) };
        NSData *metadataData = [NSJSONSerialization dataWithJSONObject:metadata options:0
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

static BOOL AMCloudPluginsCopyCatalogDirectory(NSFileManager *manager,
                                                NSURL *sourceURL,
                                                NSURL *destinationURL,
                                                BOOL replaceExisting,
                                                NSError **error) {
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
            if (!AMCloudPluginsCopyCatalogDirectory(
                    manager, source, destination, replaceExisting, error)) return NO;
            continue;
        }
        if ([source.lastPathComponent isEqualToString:@"item.json"]) continue;
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
        NSMutableArray *statePlugins = [NSMutableArray arrayWithCapacity:plugins.count];
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
			if (!AMCloudPluginsCopyCatalogDirectory(manager, sourceEffects, effectsURL,
			                                             YES, &activationError)) break;
            [statePlugins addObject:@{ @"id": pluginID, @"version_id": versionID,
                                       @"sha256": sha }];
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
                NSDictionary *state = @{ @"protocol_version": @2,
                    @"catalog_revision": revision ?: @0,
                    @"authorization_key": authorizationKey.lowercaseString,
                    @"installed_at": @((long long)NSDate.date.timeIntervalSince1970),
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

static NSURL *AMCloudPluginsBuiltinEffectsRootURL(NSString *name,
                                                   NSString *extension) {
    if (![name isKindOfClass:NSString.class] || !name.length || extension.length ||
        [name caseInsensitiveCompare:@"BuiltinEffects"] != NSOrderedSame) return nil;
    NSURL *effectsURL = nil;
    @synchronized (NSBundle.class) {
        if (AMCloudActiveAuthorizationGeneration == AMCloudAuthorizationGeneration) {
            effectsURL = AMCloudActiveEffectsURL;
        }
    }
    NSNumber *directory = nil;
    if (![effectsURL getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil] ||
        !directory.boolValue) return nil;
    return effectsURL;
}

static NSArray<NSURL *> *AMCloudPluginsFiles(NSURL *directoryURL, NSString *extension) {
    if (!directoryURL) return @[];
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
    return URLs;
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
        [merged addObject:replacement ?: URL];
        if (replacement) [remaining removeObjectForKey:key];
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
        if (self == NSBundle.mainBundle) {
            NSURL *root = !subdirectory.length
                ? AMCloudPluginsBuiltinEffectsRootURL(name, extension) : nil;
            if (root) return root;
            if (AMCloudPluginsRelativeDirectory(subdirectory)) {
                NSURL *cloud = AMCloudPluginsResourceURL(name, extension, subdirectory);
                if (cloud) return cloud;
            }
        }
        return AMCloudOriginalBundleURL
            ? AMCloudOriginalBundleURL(self, selector, name, extension, subdirectory) : nil;
    } @finally {
        AMCloudPluginsLeaveBundleHook();
    }
}

static NSURL *AMCloudBundleURLSimpleHook(id self, SEL selector, NSString *name,
                                         NSString *extension) {
    if (!AMCloudPluginsEnterBundleHook()) {
        return AMCloudOriginalBundleURLSimple
            ? AMCloudOriginalBundleURLSimple(self, selector, name, extension) : nil;
    }
    @try {
        if (self == NSBundle.mainBundle) {
            NSURL *root = AMCloudPluginsBuiltinEffectsRootURL(name, extension);
            if (root) return root;
        }
        return AMCloudOriginalBundleURLSimple
            ? AMCloudOriginalBundleURLSimple(self, selector, name, extension) : nil;
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
        if (self == NSBundle.mainBundle) {
            NSURL *root = !subdirectory.length
                ? AMCloudPluginsBuiltinEffectsRootURL(name, extension) : nil;
            if (root.path.length) return root.path;
            if (AMCloudPluginsRelativeDirectory(subdirectory)) {
                NSURL *cloud = AMCloudPluginsResourceURL(name, extension, subdirectory);
                if (cloud.path.length) return cloud.path;
            }
        }
        return AMCloudOriginalBundlePath
            ? AMCloudOriginalBundlePath(self, selector, name, extension, subdirectory) : nil;
    } @finally {
        AMCloudPluginsLeaveBundleHook();
    }
}

static NSString *AMCloudBundlePathSimpleHook(id self, SEL selector, NSString *name,
                                             NSString *extension) {
    if (!AMCloudPluginsEnterBundleHook()) {
        return AMCloudOriginalBundlePathSimple
            ? AMCloudOriginalBundlePathSimple(self, selector, name, extension) : nil;
    }
    @try {
        if (self == NSBundle.mainBundle) {
            NSString *root = AMCloudPluginsBuiltinEffectsRootURL(name, extension).path;
            if (root.length) return root;
        }
        return AMCloudOriginalBundlePathSimple
            ? AMCloudOriginalBundlePathSimple(self, selector, name, extension) : nil;
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
        AMCloudOriginalBundleURLSimple =
            (AMCloudBundleURLSimpleIMP)AMCloudPluginsInstallHook(
                bundleClass, @selector(URLForResource:withExtension:),
                (IMP)AMCloudBundleURLSimpleHook);
        AMCloudOriginalBundlePaths = (AMCloudBundlePathsIMP)AMCloudPluginsInstallHook(
            bundleClass, @selector(pathsForResourcesOfType:inDirectory:),
            (IMP)AMCloudBundlePathsHook);
        AMCloudOriginalBundlePath = (AMCloudBundlePathIMP)AMCloudPluginsInstallHook(
            bundleClass, @selector(pathForResource:ofType:inDirectory:),
            (IMP)AMCloudBundlePathHook);
        AMCloudOriginalBundlePathSimple =
            (AMCloudBundlePathSimpleIMP)AMCloudPluginsInstallHook(
                bundleClass, @selector(pathForResource:ofType:),
                (IMP)AMCloudBundlePathSimpleHook);
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
