#import "AMCloudSync.h"
#import "AMCloudPlugins.h"
#import "AMDebugTransport.h"

#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static NSString *const AMCloudAPIBase = @"https://am.meowcr.cn/api";
static NSString *const AMCloudKeychainService = @"com.ayakameow.ambeta.amproj-cloud";
static NSString *const AMCloudKeychainAccount = @"bearer-token";
static NSString *const AMCloudDeviceKeychainAccount = @"ios-device-id";
static NSString *const AMCloudErrorDomain = @"com.ayakameow.amproj.cloud";
static NSString *const AMCloudAccountEntryIdentifier = @"AMCloudAccountEntry";
static NSString *const AMCloudTokenChangedNotification = @"AMCloudTokenChangedNotification";
static NSString *const AMCloudAvatarCacheFilename = @"account-avatar.png";

typedef void (^AMCloudResult)(id _Nullable data, NSError * _Nullable error);

static NSString *AMCloudClassName(id object) {
    return object ? (NSStringFromClass([object class]) ?: @"") : @"";
}

static void AMCloudDiagnostic(NSString *name, NSDictionary *fields) {
    NSLog(@"[AMProjExport] %@ %@", name ?: @"cloud.account", fields ?: @{});
    [[AMDebugTransport shared] emitCriticalEvent:name fields:fields ?: @{}];
}

static NSError *AMCloudError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:AMCloudErrorDomain code:code
                            userInfo:@{NSLocalizedDescriptionKey:
                                message.length ? message : @"云服务请求失败"}];
}

static void AMCloudCompleteOnMain(AMCloudResult completion, id data, NSError *error) {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(data, error);
    });
}

static void *AMCloudAuthQueueKey = &AMCloudAuthQueueKey;
static uint64_t AMCloudAuthGeneration = 1;
static BOOL AMCloudAuthInitialized = NO;

static dispatch_queue_t AMCloudAuthQueue(void) {
    static dispatch_queue_t queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ayakameow.amproj.cloud-auth",
                                      DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(queue, AMCloudAuthQueueKey,
                                    AMCloudAuthQueueKey, NULL);
    });
    return queue;
}

static void AMCloudAuthPerformSync(dispatch_block_t block) {
    if (!block) return;
    if (dispatch_get_specific(AMCloudAuthQueueKey)) {
        block();
    } else {
        dispatch_sync(AMCloudAuthQueue(), block);
    }
}

static void AMCloudAuthInitializeUnlocked(void) {
    if (AMCloudAuthInitialized) return;
    AMCloudAuthInitialized = YES;
    AMCloudPluginsSetAuthorizationGeneration(AMCloudAuthGeneration);
}

static NSString *AMCloudReadTokenUnlocked(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: AMCloudKeychainService,
        (__bridge id)kSecAttrAccount: AMCloudKeychainAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) return nil;
    NSData *data = CFBridgingRelease(result);
    NSString *token = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return token.length ? token : nil;
}

static BOOL AMCloudWriteTokenUnlocked(NSString *token) {
    NSData *data = [token dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *identity = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: AMCloudKeychainService,
        (__bridge id)kSecAttrAccount: AMCloudKeychainAccount
    };
    NSDictionary *values = @{
        (__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible:
            (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    };
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)identity,
                                    (__bridge CFDictionaryRef)values);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *insert = [identity mutableCopy];
        [insert addEntriesFromDictionary:values];
        status = SecItemAdd((__bridge CFDictionaryRef)insert, NULL);
    }
    return status == errSecSuccess;
}

static OSStatus AMCloudDeleteTokenUnlocked(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: AMCloudKeychainService,
        (__bridge id)kSecAttrAccount: AMCloudKeychainAccount
    };
    return SecItemDelete((__bridge CFDictionaryRef)query);
}

static NSString *AMCloudTokenAuthorizationKey(NSString *token) {
    if (!token.length) return @"";
    NSData *data = [token dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

static void AMCloudReadAuthContext(NSString **token, uint64_t *generation,
                                   NSString **authorizationKey) {
    __block NSString *currentToken = nil;
    __block uint64_t currentGeneration = 0;
    AMCloudAuthPerformSync(^{
        AMCloudAuthInitializeUnlocked();
        currentToken = AMCloudReadTokenUnlocked();
        currentGeneration = AMCloudAuthGeneration;
    });
    if (token) *token = currentToken;
    if (generation) *generation = currentGeneration;
    if (authorizationKey) *authorizationKey = AMCloudTokenAuthorizationKey(currentToken);
}

static NSString *AMCloudReadToken(void) {
    NSString *token = nil;
    AMCloudReadAuthContext(&token, NULL, NULL);
    return token;
}

static BOOL AMCloudAuthMatches(NSString *token, uint64_t generation) {
    __block BOOL matches = NO;
    AMCloudAuthPerformSync(^{
        AMCloudAuthInitializeUnlocked();
        NSString *currentToken = AMCloudReadTokenUnlocked();
        matches = AMCloudAuthGeneration == generation &&
            ((token.length && [currentToken isEqualToString:token]) ||
             (!token.length && !currentToken.length));
    });
    return matches;
}

static BOOL AMCloudCommitIfAuthMatches(NSString *token, uint64_t generation,
                                       dispatch_block_t commit) {
    __block BOOL committed = NO;
    AMCloudAuthPerformSync(^{
        AMCloudAuthInitializeUnlocked();
        if (AMCloudAuthGeneration != generation ||
            ![AMCloudReadTokenUnlocked() isEqualToString:token]) return;
        commit();
        committed = YES;
    });
    return committed;
}

static void AMCloudPostTokenChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:AMCloudTokenChangedNotification object:nil];
    });
}

static void AMCloudCleanupPluginsForAuth(NSString *token, uint64_t generation) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        AMCloudPluginsRemoveAllIf(^BOOL{
            return AMCloudAuthMatches(token, generation);
        });
    });
}

static BOOL AMCloudWriteToken(NSString *token) {
    if (!token.length) return NO;
    __block BOOL stored = NO;
    __block BOOL changed = NO;
    __block uint64_t generation = 0;
    AMCloudAuthPerformSync(^{
        AMCloudAuthInitializeUnlocked();
        NSString *previousToken = AMCloudReadTokenUnlocked();
        stored = AMCloudWriteTokenUnlocked(token);
        changed = stored && ![previousToken isEqualToString:token];
        if (changed) {
            generation = ++AMCloudAuthGeneration;
            AMCloudPluginsSetAuthorizationGeneration(generation);
        }
    });
    if (changed) {
        AMCloudPostTokenChanged();
        AMCloudCleanupPluginsForAuth(token, generation);
    }
    return stored;
}

static BOOL AMCloudDeleteTokenMatching(NSString *expectedToken, BOOL requireMatch) {
    __block BOOL matched = NO;
    __block BOOL hadToken = NO;
    __block BOOL deleted = NO;
    __block OSStatus deleteStatus = errSecSuccess;
    __block uint64_t generation = 0;
    AMCloudAuthPerformSync(^{
        AMCloudAuthInitializeUnlocked();
        NSString *currentToken = AMCloudReadTokenUnlocked();
        matched = !requireMatch ||
            (expectedToken.length && [currentToken isEqualToString:expectedToken]);
        if (!matched) return;
        hadToken = currentToken.length > 0;
        if (hadToken) {
            deleteStatus = AMCloudDeleteTokenUnlocked();
            deleted = deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound;
            if (!deleted) return;
            generation = ++AMCloudAuthGeneration;
            AMCloudPluginsSetAuthorizationGeneration(generation);
        } else {
            deleted = YES;
            generation = AMCloudAuthGeneration;
        }
    });
    if (!matched || !deleted) {
        if (matched && deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound) {
            AMCloudDiagnostic(@"cloud.token.delete_failed", @{ @"status": @(deleteStatus) });
        }
        return NO;
    }
    if (hadToken) AMCloudPostTokenChanged();
    AMCloudCleanupPluginsForAuth(nil, generation);
    return YES;
}

static void AMCloudDeleteToken(void) {
    AMCloudDeleteTokenMatching(nil, NO);
}

static void AMCloudInvalidateToken(NSString *token) {
    if (!token.length) return;
    AMCloudDeleteTokenMatching(token, YES);
}

static void AMCloudInvalidateTokenForRequest(NSURLRequest *request) {
    NSString *authorization = [request valueForHTTPHeaderField:@"Authorization"];
    NSString *prefix = @"Bearer ";
    if (![authorization hasPrefix:prefix]) return;
    AMCloudInvalidateToken([authorization substringFromIndex:prefix.length]);
}

static BOOL AMCloudIsValidDeviceIdentifier(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] || !identifier.length) return NO;
    NSUUID *UUID = [[NSUUID alloc] initWithUUIDString:identifier];
    return UUID != nil;
}

static NSString *AMCloudDeviceIdentifier(void) {
    static NSString *cachedIdentifier = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *identity = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: AMCloudKeychainService,
            (__bridge id)kSecAttrAccount: AMCloudDeviceKeychainAccount
        };
        NSMutableDictionary *query = [identity mutableCopy];
        [query addEntriesFromDictionary:@{
            (__bridge id)kSecReturnData: @YES,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
        }];
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (status == errSecSuccess && result) {
            NSData *data = CFBridgingRelease(result);
            NSString *stored = [[NSString alloc] initWithData:data
                                                      encoding:NSUTF8StringEncoding];
            if (AMCloudIsValidDeviceIdentifier(stored)) {
                NSUUID *storedUUID = [[NSUUID alloc] initWithUUIDString:stored];
                cachedIdentifier = storedUUID.UUIDString.lowercaseString;
                return;
            }
        } else if (status != errSecItemNotFound) {
            if (result) CFRelease(result);
            AMCloudDiagnostic(@"cloud.device_id.read_failed", @{
                @"status": @(status)
            });
            return;
        }

        NSString *candidate = NSUUID.UUID.UUIDString.lowercaseString;
        NSData *data = [candidate dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *values = @{
            (__bridge id)kSecValueData: data,
            (__bridge id)kSecAttrAccessible:
                (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        };
        OSStatus writeStatus = errSecSuccess;
        if (status == errSecSuccess) {
            writeStatus = SecItemUpdate((__bridge CFDictionaryRef)identity,
                                        (__bridge CFDictionaryRef)values);
        } else {
            NSMutableDictionary *insert = [identity mutableCopy];
            [insert addEntriesFromDictionary:values];
            writeStatus = SecItemAdd((__bridge CFDictionaryRef)insert, NULL);
            if (writeStatus == errSecDuplicateItem) {
                writeStatus = SecItemUpdate((__bridge CFDictionaryRef)identity,
                                            (__bridge CFDictionaryRef)values);
            }
        }
        if (writeStatus == errSecSuccess) {
            cachedIdentifier = candidate;
        } else {
            AMCloudDiagnostic(@"cloud.device_id.write_failed", @{
                @"status": @(writeStatus)
            });
        }
    });
    return cachedIdentifier;
}

static BOOL AMCloudIsTrustedAccountURL(NSURL *URL) {
    if (![URL isKindOfClass:NSURL.class]) return NO;
    BOOL defaultPort = !URL.port || URL.port.integerValue == 443;
    return [URL.scheme.lowercaseString isEqualToString:@"https"] &&
        [URL.host.lowercaseString isEqualToString:@"am.meowcr.cn"] &&
        !URL.user.length && !URL.password.length && defaultPort;
}

static NSString *AMCloudDeviceName(void) {
    NSString *name = UIDevice.currentDevice.name;
    return name.length ? name : (UIDevice.currentDevice.model ?: @"iOS Device");
}

static NSString *AMCloudSHA256(NSURL *URL, NSError **error) {
    NSInputStream *stream = [NSInputStream inputStreamWithURL:URL];
    if (!stream) {
        if (error) *error = AMCloudError(1, @"无法读取项目包");
        return nil;
    }
    [stream open];
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t buffer[256 * 1024];
    NSInteger count = 0;
    while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) {
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    }
    NSError *streamError = stream.streamError;
    [stream close];
    if (count < 0 || streamError) {
        if (error) *error = streamError ?: AMCloudError(2, @"读取项目包失败");
        return nil;
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

static NSString *AMCloudSafeFilename(NSString *name) {
    NSString *filename = name.lastPathComponent;
    if (!filename.length) filename = @"project.amproj";
    filename = [filename stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    filename = [filename stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];
    if (![filename.pathExtension.lowercaseString isEqualToString:@"amproj"]) {
        filename = [filename stringByAppendingPathExtension:@"amproj"];
    }
    return filename;
}

static NSString *AMCloudUploadHeaderFilename(NSString *name) {
    NSString *filename = AMCloudSafeFilename(name);
    return [filename canBeConvertedToEncoding:NSASCIIStringEncoding]
        ? filename : @"project.amproj";
}

static NSString *AMCloudByteText(long long bytes) {
    NSByteCountFormatter *formatter = [NSByteCountFormatter new];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    return [formatter stringFromByteCount:MAX(0, bytes)];
}

static NSString *AMCloudDateText(NSNumber *timestamp) {
    if (![timestamp isKindOfClass:NSNumber.class] || timestamp.longLongValue <= 0) return @"";
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:timestamp.doubleValue]];
}

static void AMCloudAfterAlertAction(dispatch_block_t block) {
    if (!block) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), block);
}

static UIViewController *AMCloudTopController(UIViewController *base) {
    UIViewController *controller = base;
    if (!controller) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class] ||
                scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) {
                    controller = window.rootViewController;
                    break;
                }
            }
            if (controller) break;
        }
    }
    while (controller.presentedViewController) controller = controller.presentedViewController;
    if ([controller isKindOfClass:UINavigationController.class]) {
        return AMCloudTopController(((UINavigationController *)controller).visibleViewController);
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return AMCloudTopController(((UITabBarController *)controller).selectedViewController);
    }
    return controller;
}

static NSDictionary *AMCloudEnvelope(NSData *data, NSHTTPURLResponse *response,
                                     NSError **error) {
    NSDictionary *json = nil;
    if (data.length) {
        id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([value isKindOfClass:NSDictionary.class]) json = value;
    }
    NSInteger status = response.statusCode;
    NSNumber *code = [json[@"code"] isKindOfClass:NSNumber.class] ? json[@"code"] : nil;
    if (status < 200 || status >= 300) {
        NSString *message = [json[@"message"] isKindOfClass:NSString.class]
            ? json[@"message"] : nil;
        if (!message.length) message = [NSHTTPURLResponse localizedStringForStatusCode:status];
        if (error) *error = AMCloudError(status, message);
        return nil;
    }
    if (![json isKindOfClass:NSDictionary.class] || !code) {
        if (error) *error = AMCloudError(3, @"云服务返回了无效数据");
        return nil;
    }
    if (code.integerValue != 0) {
        NSString *message = [json[@"message"] isKindOfClass:NSString.class]
            ? json[@"message"] : @"云服务请求失败";
        if (error) *error = AMCloudError(code.integerValue, message);
        return nil;
    }
    id payload = json[@"data"];
    return [payload isKindOfClass:NSDictionary.class] ? payload : @{};
}

@interface AMCloudClient : NSObject
@property(nonatomic, strong) NSURLSession *session;
- (void)loginUsername:(NSString *)username password:(NSString *)password
             nickname:(NSString *)nickname registerAccount:(BOOL)registerAccount
           completion:(AMCloudResult)completion;
- (void)loadMe:(AMCloudResult)completion;
- (void)loadAvatarURL:(NSURL *)URL completion:(void (^)(NSData *data, NSError *error))completion;
- (void)logout:(AMCloudResult)completion;
- (void)activateIOSSession:(AMCloudResult)completion;
- (void)authorizeFeature:(NSString *)feature completion:(AMCloudResult)completion;
- (void)loadPluginManifest:(AMCloudResult)completion;
- (void)downloadPluginRelease:(NSDictionary *)release completion:(AMCloudResult)completion;
- (void)loadProjects:(AMCloudResult)completion;
- (void)createProject:(NSString *)title completion:(AMCloudResult)completion;
- (void)uploadFile:(NSURL *)fileURL projectID:(NSString *)projectID
          filename:(NSString *)filename completion:(AMCloudResult)completion;
- (void)downloadProject:(NSDictionary *)project completion:(AMCloudResult)completion;
- (void)loadVersions:(NSString *)projectID completion:(AMCloudResult)completion;
- (void)restoreProject:(NSString *)projectID versionID:(NSString *)versionID
             completion:(AMCloudResult)completion;
- (void)deleteProject:(NSString *)projectID completion:(AMCloudResult)completion;
@end

@implementation AMCloudClient

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *configuration =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 60;
        configuration.timeoutIntervalForResource = 15 * 60;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.HTTPAdditionalHeaders = @{ @"Accept": @"application/json" };
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

- (NSMutableURLRequest *)requestMethod:(NSString *)method path:(NSString *)path
                                  body:(NSDictionary *)body authenticated:(BOOL)authenticated
                                 error:(NSError **)error {
    NSURL *URL = [NSURL URLWithString:[AMCloudAPIBase stringByAppendingString:path ?: @""]];
    if (!URL) {
        if (error) *error = AMCloudError(4, @"云服务地址无效");
        return nil;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.HTTPMethod = method;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSString *deviceIdentifier = AMCloudDeviceIdentifier();
    if (!deviceIdentifier.length) {
        if (error) {
            *error = AMCloudError(21,
                @"无法安全保存此设备标识，请解锁设备后重新打开应用");
        }
        return nil;
    }
    [request setValue:@"ios" forHTTPHeaderField:@"X-AM-Platform"];
    [request setValue:deviceIdentifier forHTTPHeaderField:@"X-AM-Device-ID"];
    if (authenticated) {
        NSString *token = AMCloudReadToken();
        if (!token.length) {
            if (error) *error = AMCloudError(401, @"请先登录猫鹤账户");
            return nil;
        }
        [request setValue:[@"Bearer " stringByAppendingString:token]
       forHTTPHeaderField:@"Authorization"];
    }
    if (body) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:error];
        if (!data) return nil;
        request.HTTPBody = data;
        [request setValue:@"application/json; charset=utf-8"
       forHTTPHeaderField:@"Content-Type"];
        [request setValue:[NSString stringWithFormat:@"%lu", (unsigned long)data.length]
       forHTTPHeaderField:@"Content-Length"];
    }
    return request;
}

- (void)performMethod:(NSString *)method path:(NSString *)path
                  body:(NSDictionary *)body authenticated:(BOOL)authenticated
            completion:(AMCloudResult)completion {
    NSError *requestError = nil;
    NSMutableURLRequest *request = [self requestMethod:method path:path body:body
                                          authenticated:authenticated error:&requestError];
    if (!request) {
        AMCloudCompleteOnMain(completion, nil, requestError);
        return;
    }
    [[self.session dataTaskWithRequest:request
                    completionHandler:^(NSData *data, NSURLResponse *rawResponse,
                                        NSError *networkError) {
        if (networkError) {
            AMCloudCompleteOnMain(completion, nil, networkError);
            return;
        }
        NSHTTPURLResponse *response = [rawResponse isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)rawResponse : nil;
        NSError *responseError = nil;
        NSDictionary *payload = AMCloudEnvelope(data, response, &responseError);
        if (response.statusCode == 401 && authenticated &&
            [path isEqualToString:@"/user/me"]) {
            AMCloudInvalidateTokenForRequest(request);
        }
        AMCloudCompleteOnMain(completion, payload, responseError);
    }] resume];
}

- (void)loginUsername:(NSString *)username password:(NSString *)password
             nickname:(NSString *)nickname registerAccount:(BOOL)registerAccount
           completion:(AMCloudResult)completion {
    NSString *deviceIdentifier = AMCloudDeviceIdentifier();
    if (!deviceIdentifier.length) {
        AMCloudCompleteOnMain(completion, nil, AMCloudError(21,
            @"无法安全保存此设备标识，请解锁设备后重新打开应用"));
        return;
    }
    NSMutableDictionary *body = [@{
        @"username": username ?: @"",
        @"password": password ?: @"",
        @"platform": @"ios",
        @"device_id": deviceIdentifier,
        @"device_name": AMCloudDeviceName()
    } mutableCopy];
    if (registerAccount) body[@"nickname"] = nickname.length ? nickname : username ?: @"";
    NSString *path = registerAccount ? @"/auth/register" : @"/auth/login";
    [self performMethod:@"POST" path:path body:body authenticated:NO
             completion:^(NSDictionary *data, NSError *error) {
        NSString *token = [data[@"token"] isKindOfClass:NSString.class] ? data[@"token"] : nil;
        if (!error && !token.length) error = AMCloudError(5, @"登录响应中没有令牌");
        if (!error && !AMCloudWriteToken(token)) error = AMCloudError(6, @"无法安全保存登录状态");
        if (completion) completion(data, error);
    }];
}

- (void)loadMe:(AMCloudResult)completion {
    [self performMethod:@"GET" path:@"/user/me" body:nil authenticated:YES completion:completion];
}

- (void)loadAvatarURL:(NSURL *)URL completion:(void (^)(NSData *data, NSError *error))completion {
    if (!URL || ![[URL.scheme lowercaseString] isEqualToString:@"https"]) {
        AMCloudCompleteOnMain(^(id data, NSError *error) {
            if (completion) completion(data, error);
        }, nil, AMCloudError(4, @"头像地址无效"));
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    request.timeoutInterval = 20;
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data,
        NSURLResponse *rawResponse, NSError *error) {
        NSHTTPURLResponse *response = [rawResponse isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)rawResponse : nil;
        if (!error && (response.statusCode < 200 || response.statusCode >= 300)) {
            error = AMCloudError(response.statusCode, @"头像下载失败");
        }
        if (!error && (!data.length || data.length > 5 * 1024 * 1024)) {
            error = AMCloudError(4, @"头像文件无效或过大");
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(error ? nil : data, error);
        });
    }] resume];
}

- (void)logout:(AMCloudResult)completion {
    NSString *logoutToken = AMCloudReadToken();
    [self performMethod:@"POST" path:@"/auth/logout" body:@{}
          authenticated:YES completion:^(id data, NSError *error) {
        AMCloudInvalidateToken(logoutToken);
        if (completion) completion(data, error);
    }];
}

- (void)activateIOSSession:(AMCloudResult)completion {
    NSString *deviceIdentifier = AMCloudDeviceIdentifier();
    if (!deviceIdentifier.length) {
        AMCloudCompleteOnMain(completion, nil, AMCloudError(21,
            @"无法安全保存此设备标识，请解锁设备后重新打开应用"));
        return;
    }
    [self performMethod:@"POST" path:@"/ios/session/activate" body:@{
        @"platform": @"ios",
        @"device_id": deviceIdentifier,
        @"device_name": AMCloudDeviceName()
    } authenticated:YES completion:completion];
}

- (void)authorizeFeature:(NSString *)feature completion:(AMCloudResult)completion {
    [self performMethod:@"POST" path:@"/ios/authorize"
                   body:@{ @"feature": feature ?: @"" }
          authenticated:YES completion:completion];
}

- (void)loadProjects:(AMCloudResult)completion {
    [self performMethod:@"GET" path:@"/cloud/projects" body:nil
          authenticated:YES completion:completion];
}

- (void)createProject:(NSString *)title completion:(AMCloudResult)completion {
    [self performMethod:@"POST" path:@"/cloud/projects"
                   body:@{ @"title": title ?: @"未命名工程" }
          authenticated:YES completion:completion];
}

- (void)uploadFile:(NSURL *)fileURL projectID:(NSString *)projectID
          filename:(NSString *)filename completion:(AMCloudResult)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *hashError = nil;
        NSString *sha256 = AMCloudSHA256(fileURL, &hashError);
        NSNumber *size = nil;
        [fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:&hashError];
        if (!sha256.length || size.unsignedLongLongValue == 0 || hashError) {
            AMCloudCompleteOnMain(completion, nil,
                hashError ?: AMCloudError(7, @"项目包为空或不可读取"));
            return;
        }
        NSString *path = [NSString stringWithFormat:@"/cloud/projects/%@/upload", projectID];
        NSError *requestError = nil;
        NSMutableURLRequest *request = [self requestMethod:@"POST" path:path body:nil
                                              authenticated:YES error:&requestError];
        if (!request) {
            AMCloudCompleteOnMain(completion, nil, requestError);
            return;
        }
        request.timeoutInterval = 15 * 60;
        [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
        [request setValue:size.stringValue forHTTPHeaderField:@"Content-Length"];
        [request setValue:AMCloudUploadHeaderFilename(filename)
       forHTTPHeaderField:@"X-AMProj-Filename"];
        [request setValue:sha256 forHTTPHeaderField:@"X-AMProj-SHA256"];
        [[self.session uploadTaskWithRequest:request fromFile:fileURL
                          completionHandler:^(NSData *data, NSURLResponse *rawResponse,
                                              NSError *networkError) {
            if (networkError) {
                AMCloudCompleteOnMain(completion, nil, networkError);
                return;
            }
            NSHTTPURLResponse *response = [rawResponse isKindOfClass:NSHTTPURLResponse.class]
                ? (NSHTTPURLResponse *)rawResponse : nil;
            NSError *responseError = nil;
            NSDictionary *payload = AMCloudEnvelope(data, response, &responseError);
            AMCloudCompleteOnMain(completion, payload, responseError);
        }] resume];
    });
}

- (void)downloadProject:(NSDictionary *)project completion:(AMCloudResult)completion {
    NSString *projectID = [project[@"id"] isKindOfClass:NSString.class] ? project[@"id"] : nil;
    NSDictionary *version = [project[@"currentVersion"] isKindOfClass:NSDictionary.class]
        ? project[@"currentVersion"] : nil;
    if (!projectID.length || !version) {
        AMCloudCompleteOnMain(completion, nil, AMCloudError(8, @"该云工程还没有可下载版本"));
        return;
    }
    NSString *path = [NSString stringWithFormat:@"/cloud/projects/%@/download", projectID];
    NSError *requestError = nil;
    NSMutableURLRequest *request = [self requestMethod:@"GET" path:path body:nil
                                          authenticated:YES error:&requestError];
    if (!request) {
        AMCloudCompleteOnMain(completion, nil, requestError);
        return;
    }
    [[self.session downloadTaskWithRequest:request
                         completionHandler:^(NSURL *temporaryURL, NSURLResponse *rawResponse,
                                             NSError *networkError) {
        NSHTTPURLResponse *response = [rawResponse isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)rawResponse : nil;
        if (networkError) {
            AMCloudCompleteOnMain(completion, nil, networkError);
            return;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
            NSData *errorData = temporaryURL ? [NSData dataWithContentsOfURL:temporaryURL] : nil;
            NSError *responseError = nil;
            AMCloudEnvelope(errorData, response, &responseError);
            AMCloudCompleteOnMain(completion, nil,
                responseError ?: AMCloudError(response.statusCode, @"下载云工程失败"));
            return;
        }
        if (!temporaryURL) {
            AMCloudCompleteOnMain(completion, nil,
                AMCloudError(9, @"云服务没有返回下载文件"));
            return;
        }
        NSString *headerSHA = [response valueForHTTPHeaderField:@"X-AMProj-SHA256"];
        NSString *expectedSHA = [headerSHA isKindOfClass:NSString.class] ? headerSHA : nil;
        if (!expectedSHA.length) {
            expectedSHA = [version[@"sha256"] isKindOfClass:NSString.class]
                ? version[@"sha256"] : nil;
        }
        NSError *hashError = nil;
        NSString *actualSHA = AMCloudSHA256(temporaryURL, &hashError);
        NSNumber *actualSize = nil;
        [temporaryURL getResourceValue:&actualSize forKey:NSURLFileSizeKey error:&hashError];
        NSNumber *listedSize = [version[@"sizeBytes"] isKindOfClass:NSNumber.class]
            ? version[@"sizeBytes"] : nil;
        NSString *listedSHA = [version[@"sha256"] isKindOfClass:NSString.class]
            ? version[@"sha256"] : nil;
        long long responseSize = response.expectedContentLength;
        BOOL canUseListedSize = responseSize < 0 && listedSize &&
            (!expectedSHA.length || !listedSHA.length ||
             [expectedSHA caseInsensitiveCompare:listedSHA] == NSOrderedSame);
        BOOL sizeMismatch = responseSize >= 0
            ? responseSize != actualSize.longLongValue
            : (canUseListedSize && listedSize.longLongValue != actualSize.longLongValue);
        if (hashError || !actualSHA.length ||
            (expectedSHA.length && [actualSHA caseInsensitiveCompare:expectedSHA] != NSOrderedSame) ||
            sizeMismatch) {
            AMCloudCompleteOnMain(completion, nil,
                hashError ?: AMCloudError(9, @"下载文件校验失败，请重新下载"));
            return;
        }
        NSURL *support = [NSFileManager.defaultManager URLsForDirectory:
            NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *directory = [[support URLByAppendingPathComponent:@"AMProjCloudDownloads"
                                                     isDirectory:YES]
            URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        NSError *fileError = nil;
        if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                                     withIntermediateDirectories:YES attributes:nil
                                                          error:&fileError]) {
            AMCloudCompleteOnMain(completion, nil, fileError);
            return;
        }
        NSString *filename = [version[@"filename"] isKindOfClass:NSString.class]
            ? version[@"filename"] : [project[@"title"] stringByAppendingPathExtension:@"amproj"];
        filename = AMCloudSafeFilename(filename);
        NSURL *destination = [directory URLByAppendingPathComponent:filename];
        if (![NSFileManager.defaultManager moveItemAtURL:temporaryURL
                                                   toURL:destination error:&fileError]) {
            [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
            AMCloudCompleteOnMain(completion, nil, fileError);
            return;
        }
        [directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        AMCloudCompleteOnMain(completion,
            @{ @"url": destination, @"filename": filename,
               @"cleanupURL": directory, @"sha256": actualSHA }, nil);
    }] resume];
}

- (void)loadVersions:(NSString *)projectID completion:(AMCloudResult)completion {
    NSString *path = [NSString stringWithFormat:@"/cloud/projects/%@/versions", projectID];
    [self performMethod:@"GET" path:path body:nil authenticated:YES completion:completion];
}

- (void)restoreProject:(NSString *)projectID versionID:(NSString *)versionID
             completion:(AMCloudResult)completion {
    NSString *path = [NSString stringWithFormat:@"/cloud/projects/%@/restore", projectID];
    [self performMethod:@"POST" path:path body:@{ @"versionId": versionID ?: @"" }
          authenticated:YES completion:completion];
}

- (void)deleteProject:(NSString *)projectID completion:(AMCloudResult)completion {
    NSString *path = [NSString stringWithFormat:@"/cloud/projects/%@", projectID];
    [self performMethod:@"DELETE" path:path body:nil authenticated:YES completion:completion];
}

- (void)loadPluginManifest:(AMCloudResult)completion {
    [self performMethod:@"GET" path:@"/ios/plugins/manifest" body:nil
          authenticated:YES completion:completion];
}

- (void)downloadPluginRelease:(NSDictionary *)release completion:(AMCloudResult)completion {
    NSString *releaseID = [release[@"id"] isKindOfClass:NSString.class]
        ? release[@"id"] : nil;
    NSString *expectedSHA = [release[@"sha256"] isKindOfClass:NSString.class]
        ? [release[@"sha256"] lowercaseString] : nil;
    NSNumber *expectedSize = [release[@"sizeBytes"] isKindOfClass:NSNumber.class]
        ? release[@"sizeBytes"] : nil;
    if (!releaseID.length || expectedSHA.length != 64 || expectedSize.longLongValue <= 0) {
        AMCloudCompleteOnMain(completion, nil,
            AMCloudError(22, @"云端插件版本信息不完整"));
        return;
    }
    NSString *path = [NSString stringWithFormat:@"/ios/plugins/releases/%@/download", releaseID];
    NSError *requestError = nil;
    NSMutableURLRequest *request = [self requestMethod:@"GET" path:path body:nil
                                          authenticated:YES error:&requestError];
    if (!request) {
        AMCloudCompleteOnMain(completion, nil, requestError);
        return;
    }
    request.timeoutInterval = 15 * 60;
    [[self.session downloadTaskWithRequest:request
                         completionHandler:^(NSURL *temporaryURL, NSURLResponse *rawResponse,
                                             NSError *networkError) {
        NSHTTPURLResponse *response = [rawResponse isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)rawResponse : nil;
        if (networkError) {
            AMCloudCompleteOnMain(completion, nil, networkError);
            return;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
            NSData *errorData = temporaryURL ? [NSData dataWithContentsOfURL:temporaryURL] : nil;
            NSError *responseError = nil;
            AMCloudEnvelope(errorData, response, &responseError);
            AMCloudCompleteOnMain(completion, nil,
                responseError ?: AMCloudError(response.statusCode, @"下载云端插件失败"));
            return;
        }
        NSError *hashError = nil;
        NSString *actualSHA = temporaryURL ? AMCloudSHA256(temporaryURL, &hashError) : nil;
        NSNumber *actualSize = nil;
        [temporaryURL getResourceValue:&actualSize forKey:NSURLFileSizeKey error:&hashError];
        NSString *headerSHA = [[response valueForHTTPHeaderField:@"X-AM-Plugin-SHA256"]
            lowercaseString];
        BOOL headerMismatch = headerSHA.length &&
            [headerSHA caseInsensitiveCompare:expectedSHA] != NSOrderedSame;
        if (!temporaryURL || hashError || !actualSHA.length || headerMismatch ||
            [actualSHA caseInsensitiveCompare:expectedSHA] != NSOrderedSame ||
            actualSize.longLongValue != expectedSize.longLongValue) {
            AMCloudCompleteOnMain(completion, nil,
                hashError ?: AMCloudError(23, @"云端插件文件校验失败"));
            return;
        }
        NSURL *downloadsURL = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
            URLByAppendingPathComponent:@"AMCloudPluginDownloads" isDirectory:YES];
        NSError *fileError = nil;
        if (![NSFileManager.defaultManager createDirectoryAtURL:downloadsURL
                                    withIntermediateDirectories:YES attributes:nil
                                                         error:&fileError]) {
            AMCloudCompleteOnMain(completion, nil, fileError);
            return;
        }
        NSURL *destinationURL = [downloadsURL URLByAppendingPathComponent:
            [[NSUUID.UUID.UUIDString lowercaseString] stringByAppendingPathExtension:@"zip"]];
        if (![NSFileManager.defaultManager moveItemAtURL:temporaryURL
                                                   toURL:destinationURL error:&fileError]) {
            AMCloudCompleteOnMain(completion, nil, fileError);
            return;
        }
        AMCloudCompleteOnMain(completion, @{
            @"url": destinationURL,
            @"cleanup": destinationURL,
            @"release": release
        }, nil);
    }] resume];
}

@end

@class AMCloudManager;

@interface AMCloudAccountViewController : UITableViewController
@property(nonatomic, strong) AMCloudManager *manager;
@property(nonatomic, copy) NSDictionary *account;
@property(nonatomic, copy) NSDictionary *usage;
@property(nonatomic, copy) NSArray<NSDictionary *> *projects;
@property(nonatomic) BOOL authenticationPending;
@property(nonatomic) BOOL contentLoaded;
@property(nonatomic) BOOL authenticated;
- (void)reloadCloudData;
- (void)createCloudProject;
- (void)ensureAccountReady;
- (void)beginAuthentication;
- (void)resetAccountContent;
@end

@interface AMCloudManager : NSObject
@property(nonatomic, strong) AMCloudClient *client;
@property(nonatomic, copy) AMCloudImportHandler importHandler;
@property(nonatomic, weak) UIViewController *lastProjectsController;
@property(nonatomic, weak) UIViewController *accountController;
@property(nonatomic, strong) NSTimer *pluginSyncTimer;
@property(nonatomic) BOOL pluginSyncInstalled;
@property(nonatomic) BOOL pluginSyncInFlight;
@property(nonatomic) BOOL pluginSyncPending;
@property(nonatomic, copy) NSString *pluginSyncOperationID;
@property(nonatomic, strong) UIView *pluginDownloadOverlay;
@property(nonatomic, copy) NSString *pluginDownloadNoticeOperationID;
@property(nonatomic, copy) NSString *pluginDownloadNoticeToken;
@property(nonatomic) uint64_t pluginDownloadNoticeGeneration;
@property(nonatomic, copy) NSString *pluginDownloadNoticeTitle;
@property(nonatomic, copy) NSString *pluginDownloadNoticeMessage;
@property(nonatomic) BOOL pluginDownloadNoticeBusy;
@property(nonatomic) BOOL pluginDownloadNoticeSuppressed;
@property(nonatomic, strong) UIImage *accountAvatarImage;
@property(nonatomic, copy) NSString *accountAvatarURL;
@property(nonatomic, copy) NSString *accountAvatarRequestID;
@property(nonatomic) BOOL accountAvatarRefreshInFlight;
+ (instancetype)shared;
- (void)installWithImportHandler:(AMCloudImportHandler)importHandler;
- (void)attachAccountEntryToController:(UIViewController *)controller;
- (void)showAccountEntry:(id)sender;
- (void)showAccountFrom:(UIViewController *)presenter;
- (void)refreshAccountAvatar;
- (void)applyAccountProfile:(NSDictionary *)profile;
- (void)showAuthenticationFrom:(UIViewController *)presenter
                     completion:(dispatch_block_t)completion;
- (void)beginUploadFile:(NSURL *)fileURL title:(NSString *)title
              presenter:(UIViewController *)presenter;
- (void)showActionsForProject:(NSDictionary *)project
                    presenter:(UIViewController *)presenter;
- (void)showError:(NSError *)error presenter:(UIViewController *)presenter;
@end

@interface AMCloudManager ()
- (UIViewController *)newAccountControllerForRoute:(NSString *)route;
- (void)showAuthenticationFrom:(UIViewController *)presenter
                     completion:(dispatch_block_t)completion
                    cancellation:(dispatch_block_t)cancellation;
- (UIAlertController *)busyAlert:(NSString *)title presenter:(UIViewController *)presenter;
- (void)showCredentialsFrom:(UIViewController *)presenter registerAccount:(BOOL)registerAccount
                  completion:(dispatch_block_t)completion;
- (void)chooseUploadTarget:(NSArray *)projects fileURL:(NSURL *)fileURL
                      title:(NSString *)title presenter:(UIViewController *)presenter;
- (void)promptCreateAndUpload:(NSURL *)fileURL title:(NSString *)title
                    presenter:(UIViewController *)presenter;
- (void)uploadFile:(NSURL *)fileURL title:(NSString *)title
         toProject:(NSDictionary *)project presenter:(UIViewController *)presenter;
- (void)downloadAndImportProject:(NSDictionary *)project
                       presenter:(UIViewController *)presenter;
- (void)showVersionsForProject:(NSDictionary *)project
                     presenter:(UIViewController *)presenter;
- (void)presentVersions:(NSArray *)versions project:(NSDictionary *)project
               presenter:(UIViewController *)presenter;
- (void)confirmRestoreVersion:(NSDictionary *)version project:(NSDictionary *)project
                    presenter:(UIViewController *)presenter;
- (void)confirmDeleteProject:(NSDictionary *)project
                   presenter:(UIViewController *)presenter;
- (void)reloadAccountControllerIfSupported;
- (void)syncPluginsNow:(NSString *)reason;
- (void)finishPluginSyncAllowingPending:(BOOL)allowPending;
- (void)beginPluginDownloadNoticeForRelease:(NSDictionary *)release
                                operationID:(NSString *)operationID
                                      token:(NSString *)token
                         authorizationGeneration:(uint64_t)authorizationGeneration;
- (void)finishPluginDownloadNoticeInstalled:(BOOL)installed
                                      state:(NSDictionary * _Nullable)state
                                      error:(NSError * _Nullable)error
                                  cancelled:(BOOL)cancelled
                                operationID:(NSString *)operationID;
- (void)showPluginDownloadNoticeIfPossible;
- (void)hidePluginDownloadNotice;
- (void)cancelPluginDownloadNotice;
- (void)updateAccountEntryImage;
- (void)clearAccountAvatar;
- (void)loadCachedAccountAvatar;
@end

@interface AMCloudAccountWebViewController : UIViewController
    <WKNavigationDelegate, WKScriptMessageHandler>
@property(nonatomic, weak) AMCloudManager *manager;
@property(nonatomic, copy) NSString *route;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
- (void)loadAccountWebsiteWithToken:(NSString *)token activationError:(NSError *)error;
@end

@interface AMCloudWeakScriptMessageHandler : NSObject <WKScriptMessageHandler>
@property(nonatomic, weak) id<WKScriptMessageHandler> target;
+ (instancetype)handlerWithTarget:(id<WKScriptMessageHandler>)target;
@end

@interface AMCloudUploadActivity : UIActivity
@property(nonatomic, strong) NSURL *fileURL;
@property(nonatomic, copy) NSString *projectTitle;
@property(nonatomic, weak) UIViewController *sourcePresenter;
@end

@implementation AMCloudUploadActivity

- (NSString *)activityType { return @"com.ayakameow.amproj.cloud-upload"; }
- (NSString *)activityTitle { return @"上传云工程"; }
- (UIImage *)activityImage {
    if (@available(iOS 13.0, *)) return [UIImage systemImageNamed:@"cloud.and.arrow.up"];
    return nil;
}
- (UIActivityCategory)activityCategory { return UIActivityCategoryAction; }
- (BOOL)canPerformWithActivityItems:(NSArray *)activityItems { return self.fileURL != nil; }
- (void)prepareWithActivityItems:(NSArray *)activityItems { (void)activityItems; }
- (void)performActivity {
    NSURL *fileURL = self.fileURL;
    NSString *title = self.projectTitle;
    UIViewController *presenter = self.sourcePresenter;
    [self activityDidFinish:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        [[AMCloudManager shared] beginUploadFile:fileURL title:title presenter:presenter];
    });
}

@end

static const void *AMCloudProjectsOriginalIMPKey = &AMCloudProjectsOriginalIMPKey;

static BOOL AMCloudIsProjectsControllerClass(Class cls) {
    NSString *name = NSStringFromClass(cls);
    return [name hasSuffix:@"ProjectsVC"] || [name hasSuffix:@"ProjectsListVC"];
}

static BOOL AMCloudIsNativeAccountControllerClass(Class cls) {
    NSString *name = NSStringFromClass(cls);
    return [name isEqualToString:@"AlightMotion.MyAccountVC"] ||
        [name isEqualToString:@"_TtC12AlightMotion11MyAccountVC"];
}

static BOOL AMCloudContainsNativeAccountController(
    UIViewController *controller, NSUInteger depth) {
    if (!controller || depth > 8) return NO;
    if (AMCloudIsNativeAccountControllerClass(controller.class)) return YES;
    UIViewController *activeChild = nil;
    if ([controller isKindOfClass:UINavigationController.class]) {
        activeChild = ((UINavigationController *)controller).topViewController;
    } else if ([controller isKindOfClass:UITabBarController.class]) {
        activeChild = ((UITabBarController *)controller).selectedViewController;
    }
    return activeChild && activeChild != controller &&
        AMCloudContainsNativeAccountController(activeChild, depth + 1);
}

static IMP AMCloudOriginalProjectsViewDidAppear(Class cls) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        NSValue *value = objc_getAssociatedObject((id)current, AMCloudProjectsOriginalIMPKey);
        if (value) return value.pointerValue;
    }
    return NULL;
}

static void AMCloudProjectsViewDidAppear(id self, SEL selector, BOOL animated) {
    IMP original = AMCloudOriginalProjectsViewDidAppear(object_getClass(self));
    if (original) ((void (*)(id, SEL, BOOL))original)(self, selector, animated);
    if ([self isKindOfClass:UIViewController.class]) {
        [[AMCloudManager shared] attachAccountEntryToController:(UIViewController *)self];
    }
}

static void AMCloudInstallProjectsHooks(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class __unsafe_unretained *classes =
        (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    count = objc_getClassList(classes, count);
    SEL selector = @selector(viewDidAppear:);
    for (int index = 0; index < count; index++) {
        Class cls = classes[index];
        if (!AMCloudIsProjectsControllerClass(cls) ||
            ![cls isSubclassOfClass:UIViewController.class] ||
            objc_getAssociatedObject((id)cls, AMCloudProjectsOriginalIMPKey)) continue;
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) continue;
        IMP original = method_getImplementation(method);
        if (original == (IMP)AMCloudProjectsViewDidAppear) continue;
        const char *types = method_getTypeEncoding(method);
        objc_setAssociatedObject((id)cls, AMCloudProjectsOriginalIMPKey,
            [NSValue valueWithPointer:original], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!class_addMethod(cls, selector, (IMP)AMCloudProjectsViewDidAppear, types)) {
            class_replaceMethod(cls, selector, (IMP)AMCloudProjectsViewDidAppear, types);
        }
    }
    free(classes);
}

static void AMCloudAttachProjectsInControllerTree(UIViewController *controller,
                                                   NSMutableSet<NSValue *> *visited) {
    if (!controller) return;
    NSValue *identity = [NSValue valueWithPointer:(__bridge const void *)controller];
    if ([visited containsObject:identity]) return;
    [visited addObject:identity];
    if (AMCloudIsProjectsControllerClass(controller.class)) {
        [[AMCloudManager shared] attachAccountEntryToController:controller];
    }
    for (UIViewController *child in controller.childViewControllers) {
        AMCloudAttachProjectsInControllerTree(child, visited);
    }
    AMCloudAttachProjectsInControllerTree(controller.presentedViewController, visited);
    if ([controller isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in ((UINavigationController *)controller).viewControllers) {
            AMCloudAttachProjectsInControllerTree(child, visited);
        }
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        for (UIViewController *child in ((UITabBarController *)controller).viewControllers) {
            AMCloudAttachProjectsInControllerTree(child, visited);
        }
    }
}

static void AMCloudAttachVisibleProjectsControllers(void) {
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden && window.alpha > 0.01) {
                AMCloudAttachProjectsInControllerTree(window.rootViewController, visited);
            }
        }
    }
}

@implementation AMCloudAccountWebViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"猫鹤账户";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    if ([self.route isEqualToString:@"modal"] ||
        [self.route isEqualToString:@"native_present"]) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                 target:self action:@selector(closeAccountWebsite)];
    }

    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.spinner];
    [NSLayoutConstraint activateConstraints:@[
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];
    [self.spinner startAnimating];

    NSString *deviceIdentifier = AMCloudDeviceIdentifier();
    AMCloudDiagnostic(@"cloud.account.web_begin", @{
        @"route": self.route ?: @"",
        @"authenticated": @(AMCloudReadToken().length > 0),
        @"device_id": deviceIdentifier ?: @""
    });
    if (!deviceIdentifier.length) {
        [self.spinner stopAnimating];
        NSError *deviceError = AMCloudError(21,
            @"无法安全保存此设备标识，请解锁设备后重新打开应用");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.manager showError:deviceError presenter:self];
        });
        return;
    }
    NSString *token = AMCloudReadToken();
    if (!token.length) {
        [self loadAccountWebsiteWithToken:nil activationError:nil];
        return;
    }
    NSString *activationToken = token;
    __weak typeof(self) weakSelf = self;
    [self.manager.client activateIOSSession:^(__unused id data, NSError *error) {
        NSString *activeToken = AMCloudReadToken();
        BOOL activationIsCurrent = [activeToken isEqualToString:activationToken];
        if (!error && activationIsCurrent) {
            [weakSelf.manager syncPluginsNow:@"account_activation"];
        }
        NSError *activeError = activationIsCurrent || !activeToken.length ? error : nil;
        [weakSelf loadAccountWebsiteWithToken:activeToken activationError:activeError];
    }];
}

- (void)loadAccountWebsiteWithToken:(NSString *)token activationError:(NSError *)error {
    if (!self.viewIfLoaded || self.webView) return;
    NSString *deviceIdentifier = AMCloudDeviceIdentifier();
    if (!deviceIdentifier.length) {
        [self.spinner stopAnimating];
        [self.manager showError:AMCloudError(21,
            @"无法安全保存此设备标识，请解锁设备后重新打开应用") presenter:self];
        return;
    }
    NSDictionary *bootstrap = @{
        @"context": @{
            @"platform": @"ios",
            @"deviceId": deviceIdentifier,
            @"deviceName": AMCloudDeviceName()
        },
        @"token": token ?: @""
    };
    NSData *bootstrapData = [NSJSONSerialization dataWithJSONObject:bootstrap options:0 error:nil];
    NSString *bootstrapJSON = [[NSString alloc] initWithData:bootstrapData
                                                    encoding:NSUTF8StringEncoding] ?: @"{}";
    NSString *source = [NSString stringWithFormat:
        @"(function(){if(location.protocol!=='https:'||location.hostname!=='am.meowcr.cn'||"
         @"(location.port&&location.port!=='443')){return;}var b=%@;"
         @"window.AF_NATIVE_CONTEXT=b.context||{};"
         @"try{var k='am-native-account-bootstrapped';if(sessionStorage.getItem(k)!=='1'){"
         @"if(b.token){localStorage.setItem('af-token',b.token);}else{localStorage.removeItem('af-token');}"
         @"sessionStorage.setItem(k,'1');}}catch(e){}})();",
        bootstrapJSON];
    WKUserContentController *content = [WKUserContentController new];
    [content addUserScript:[[WKUserScript alloc] initWithSource:source
                                                 injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                              forMainFrameOnly:YES]];
    [content addScriptMessageHandler:
        [AMCloudWeakScriptMessageHandler handlerWithTarget:self] name:@"amAccount"];
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.userContentController = content;
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectZero
                                            configuration:configuration];
    webView.translatesAutoresizingMaskIntoConstraints = NO;
    webView.navigationDelegate = self;
    webView.customUserAgent = @"AutFengApp/ios AMProjCloud";
    self.webView = webView;
    [self.view insertSubview:webView belowSubview:self.spinner];
    [NSLayoutConstraint activateConstraints:@[
        [webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [webView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    NSURL *URL = [NSURL URLWithString:@"https://am.meowcr.cn/me.html?embed=1&platform=ios"];
    [webView loadRequest:[NSURLRequest requestWithURL:URL
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                     timeoutInterval:60]];

    if (error && (error.code == 401 || error.code == 403)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"iOS 设备需要重新登录"
                message:error.localizedDescription ?: @"当前设备登录状态已失效"
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"知道了"
                                                     style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    }
}

- (void)closeAccountWebsite {
    if (self.navigationController.presentingViewController &&
        self.navigationController.viewControllers.firstObject == self) {
        [self.navigationController dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)userContentController;
    if (![message.name isEqualToString:@"amAccount"] ||
        ![message.body isKindOfClass:NSDictionary.class]) return;
    WKFrameInfo *frameInfo = message.frameInfo;
    WKSecurityOrigin *origin = frameInfo.securityOrigin;
    BOOL trustedOrigin = frameInfo.isMainFrame &&
        [origin.protocol.lowercaseString isEqualToString:@"https"] &&
        [origin.host.lowercaseString isEqualToString:@"am.meowcr.cn"] &&
        (origin.port == 0 || origin.port == 443);
    if (!trustedOrigin) {
        AMCloudDiagnostic(@"cloud.account.web_message_rejected", @{
            @"main_frame": @(frameInfo.isMainFrame),
            @"scheme": origin.protocol ?: @"",
            @"host": origin.host ?: @"",
            @"port": @(origin.port)
        });
        return;
    }
    NSDictionary *body = message.body;
    if ([body[@"type"] isEqualToString:@"profile"]) {
        NSDictionary *profile = [body[@"user"] isKindOfClass:NSDictionary.class]
            ? body[@"user"] : nil;
        if (profile) [self.manager applyAccountProfile:profile];
        return;
    }
    if (![body[@"type"] isEqualToString:@"token"]) return;
    NSString *token = [body[@"token"] isKindOfClass:NSString.class] ? body[@"token"] : @"";
    BOOL stored = token.length ? AMCloudWriteToken(token) : YES;
    if (!token.length) AMCloudDeleteToken();
    AMCloudDiagnostic(@"cloud.account.web_token", @{
        @"present": @(token.length > 0), @"stored": @(stored)
    });
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *URL = navigationAction.request.URL;
    if (AMCloudIsTrustedAccountURL(URL)) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }

    BOOL mainNavigation = !navigationAction.targetFrame ||
        navigationAction.targetFrame.isMainFrame;
    AMCloudDiagnostic(@"cloud.account.web_navigation_rejected", @{
        @"url": URL.absoluteString ?: @"",
        @"main_frame": @(mainNavigation)
    });
    if (mainNavigation &&
        ([URL.scheme.lowercaseString isEqualToString:@"https"] ||
         [URL.scheme.lowercaseString isEqualToString:@"http"])) {
        [UIApplication.sharedApplication openURL:URL options:@{}
                               completionHandler:nil];
    }
    decisionHandler(WKNavigationActionPolicyCancel);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    (void)navigation;
    [self.spinner stopAnimating];
    self.spinner.hidden = YES;
    AMCloudDiagnostic(@"cloud.account.web_loaded", @{
        @"url": webView.URL.absoluteString ?: @""
    });
    // 网页登录完成后再从同源 localStorage 读取一次 token。脚本消息仍是主通道，
    // 这里负责覆盖 WKWebView 首次挂载时偶发漏掉消息的情况。
    [webView evaluateJavaScript:
        @"(function(){try{return localStorage.getItem('af-token')||'';}catch(e){return '';}})();"
        completionHandler:^(id value, NSError *error) {
        NSString *token = [value isKindOfClass:NSString.class] ? value : @"";
        if (error || !token.length) return;
        BOOL stored = AMCloudWriteToken(token);
        BOOL verified = stored && [AMCloudReadToken() isEqualToString:token];
        AMCloudDiagnostic(@"cloud.account.web_token_recovered", @{
            @"stored": @(stored), @"verified": @(verified)
        });
    }];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation
       withError:(NSError *)error {
    (void)webView;
    (void)navigation;
    [self.spinner stopAnimating];
    AMCloudDiagnostic(@"cloud.account.web_failed", @{
        @"error": error.localizedDescription ?: @""
    });
    [self.manager showError:error presenter:self];
}

- (void)dealloc {
    [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"amAccount"];
}

@end

@implementation AMCloudWeakScriptMessageHandler

+ (instancetype)handlerWithTarget:(id<WKScriptMessageHandler>)target {
    AMCloudWeakScriptMessageHandler *handler = [AMCloudWeakScriptMessageHandler new];
    handler.target = target;
    return handler;
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.target userContentController:userContentController didReceiveScriptMessage:message];
}

@end

@implementation AMCloudManager

+ (instancetype)shared {
    static AMCloudManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [AMCloudManager new];
        manager.client = [AMCloudClient new];
    });
    return manager;
}

- (void)installWithImportHandler:(AMCloudImportHandler)importHandler {
    self.importHandler = importHandler;
    NSString *startupToken = nil;
    uint64_t startupGeneration = 0;
    NSString *startupAuthorizationKey = nil;
    AMCloudReadAuthContext(&startupToken, &startupGeneration,
                           &startupAuthorizationKey);
    if (!startupToken.length) {
        AMCloudPluginsRemoveAllIf(^BOOL{
            return AMCloudAuthMatches(nil, startupGeneration);
        });
    } else {
        AMCloudPluginsRestoreInstalledReleaseForAuthorization(
            startupAuthorizationKey, startupGeneration);
    }
    AMCloudPluginsInstallBundleHooks();
    AMCloudInstallProjectsHooks();
    AMCloudAttachVisibleProjectsControllers();
    [NSNotificationCenter.defaultCenter
        addObserver:self selector:@selector(applicationDidBecomeActive:)
               name:UIApplicationDidBecomeActiveNotification object:nil];
    if (!self.pluginSyncInstalled) {
        self.pluginSyncInstalled = YES;
        [NSNotificationCenter.defaultCenter
            addObserver:self selector:@selector(pluginTokenChanged:)
                   name:AMCloudTokenChangedNotification object:nil];
        self.pluginSyncTimer = [NSTimer scheduledTimerWithTimeInterval:60.0
            target:self selector:@selector(pluginSyncTimerFired:)
            userInfo:nil repeats:YES];
        self.pluginSyncTimer.tolerance = 10.0;
		if (startupToken.length) [self loadCachedAccountAvatar];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            [self syncPluginsNow:@"install"];
        });
    }
    for (NSNumber *delay in @[@0, @1, @3]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            AMCloudInstallProjectsHooks();
            AMCloudAttachVisibleProjectsControllers();
        });
    }
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    AMCloudInstallProjectsHooks();
    AMCloudAttachVisibleProjectsControllers();
    [self showPluginDownloadNoticeIfPossible];
    [self syncPluginsNow:@"did_become_active"];
	[self refreshAccountAvatar];
}

- (void)pluginTokenChanged:(NSNotification *)notification {
    (void)notification;
    self.pluginSyncOperationID = nil;
    self.pluginSyncInFlight = NO;
    self.pluginSyncPending = NO;
    [self cancelPluginDownloadNotice];
	if (!AMCloudReadToken().length) {
		[self clearAccountAvatar];
		return;
	}
	[self clearAccountAvatar];
	[self refreshAccountAvatar];
    [self syncPluginsNow:@"token_changed"];
}

- (NSURL *)accountAvatarCacheURL {
    NSURL *directory = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
                                                             inDomains:NSUserDomainMask].firstObject;
    return [directory URLByAppendingPathComponent:AMCloudAvatarCacheFilename isDirectory:NO];
}

- (void)loadCachedAccountAvatar {
    NSData *data = [NSData dataWithContentsOfURL:[self accountAvatarCacheURL]];
    UIImage *image = data.length ? [UIImage imageWithData:data scale:UIScreen.mainScreen.scale] : nil;
    if (image) {
        self.accountAvatarImage = image;
        [self updateAccountEntryImage];
    }
}

- (UIImage *)circularAvatarImage:(UIImage *)source {
    if (!source || source.size.width <= 0 || source.size.height <= 0) return nil;
    CGFloat side = 30.0;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0);
    CGRect bounds = CGRectMake(0, 0, side, side);
    [[UIBezierPath bezierPathWithOvalInRect:bounds] addClip];
    CGFloat scale = MAX(side / source.size.width, side / source.size.height);
    CGSize drawSize = CGSizeMake(source.size.width * scale, source.size.height * scale);
    CGRect drawRect = CGRectMake((side - drawSize.width) * 0.5,
                                 (side - drawSize.height) * 0.5,
                                 drawSize.width, drawSize.height);
    [source drawInRect:drawRect];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
	return [result imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

- (NSURL *)resolvedAvatarURL:(NSString *)value {
    NSString *text = [value isKindOfClass:NSString.class] ? [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    if (!text.length) return nil;
    NSURL *URL = [NSURL URLWithString:text];
    if (!URL.scheme.length) URL = [NSURL URLWithString:text relativeToURL:[NSURL URLWithString:@"https://am.meowcr.cn"]].absoluteURL;
    if (![[URL.scheme lowercaseString] isEqualToString:@"https"]) return nil;
    NSString *host = URL.host.lowercaseString;
    if (![host isEqualToString:@"am.meowcr.cn"] &&
        ![host isEqualToString:@"q.qlogo.cn"] &&
        ![host hasSuffix:@".qlogo.cn"] &&
        ![host hasSuffix:@".qq.com"]) return nil;
    return URL;
}

- (void)applyAccountProfile:(NSDictionary *)profile {
    if (![profile isKindOfClass:NSDictionary.class] || !AMCloudReadToken().length) return;
    NSString *value = [profile[@"avatarUrl"] isKindOfClass:NSString.class]
        ? profile[@"avatarUrl"] : @"";
    NSURL *URL = [self resolvedAvatarURL:value];
    if (!URL) {
        [self clearAccountAvatar];
        return;
    }
    NSString *URLText = URL.absoluteString;
    if ([self.accountAvatarURL isEqualToString:URLText] && self.accountAvatarImage) {
        [self updateAccountEntryImage];
        return;
    }
    NSString *requestID = NSUUID.UUID.UUIDString;
    self.accountAvatarRequestID = requestID;
    __weak typeof(self) weakSelf = self;
    [self.client loadAvatarURL:URL completion:^(NSData *data, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || ![self.accountAvatarRequestID isEqualToString:requestID] || !AMCloudReadToken().length) return;
        UIImage *decoded = error ? nil : [UIImage imageWithData:data scale:UIScreen.mainScreen.scale];
        UIImage *image = [self circularAvatarImage:decoded];
        if (!image) return;
        self.accountAvatarURL = URLText;
        self.accountAvatarImage = image;
        NSData *cacheData = UIImagePNGRepresentation(image);
        if (cacheData.length) [cacheData writeToURL:[self accountAvatarCacheURL] options:NSDataWritingAtomic error:nil];
        [self updateAccountEntryImage];
        UIViewController *account = self.accountController;
        if ([account respondsToSelector:@selector(reloadCloudData)]) {
            [(AMCloudAccountViewController *)account reloadCloudData];
        }
    }];
}

- (void)refreshAccountAvatar {
    if (!AMCloudReadToken().length) {
        [self clearAccountAvatar];
        return;
    }
	if (self.accountAvatarRefreshInFlight) return;
	self.accountAvatarRefreshInFlight = YES;
    __weak typeof(self) weakSelf = self;
    [self.client loadMe:^(NSDictionary *data, NSError *error) {
		weakSelf.accountAvatarRefreshInFlight = NO;
        if (!error && data) [weakSelf applyAccountProfile:data];
    }];
}

- (void)clearAccountAvatar {
    self.accountAvatarRequestID = NSUUID.UUID.UUIDString;
	self.accountAvatarRefreshInFlight = NO;
    self.accountAvatarURL = nil;
    self.accountAvatarImage = nil;
    [NSFileManager.defaultManager removeItemAtURL:[self accountAvatarCacheURL] error:nil];
    [self updateAccountEntryImage];
}

- (void)updateAccountEntryImage {
    UIViewController *controller = self.lastProjectsController;
    if (controller) [self attachAccountEntryToController:controller];
}

- (void)pluginSyncTimerFired:(NSTimer *)timer {
    (void)timer;
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        [self syncPluginsNow:@"foreground_timer"];
    }
}

- (void)syncPluginsNow:(NSString *)reason {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self syncPluginsNow:reason];
        });
        return;
    }
    NSString *token = nil;
    NSString *authorizationKey = nil;
    uint64_t authorizationGeneration = 0;
    AMCloudReadAuthContext(&token, &authorizationGeneration, &authorizationKey);
    if (!token.length) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            AMCloudPluginsRemoveAllIf(^BOOL{
                return AMCloudAuthMatches(nil, authorizationGeneration);
            });
        });
        return;
    }
    if (self.pluginSyncInFlight) {
        if (![reason isEqualToString:@"foreground_timer"]) {
            self.pluginSyncPending = YES;
        }
        return;
    }
    self.pluginSyncInFlight = YES;
    NSString *operationID = NSUUID.UUID.UUIDString;
    self.pluginSyncOperationID = operationID;
    AMCloudDiagnostic(@"cloud.plugins.sync_begin", @{ @"reason": reason ?: @"unknown" });
    __weak typeof(self) weakSelf = self;
    [self.client loadPluginManifest:^(NSDictionary *manifest, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (![self.pluginSyncOperationID isEqualToString:operationID]) return;
        if (!AMCloudAuthMatches(token, authorizationGeneration)) {
            [self finishPluginSyncAllowingPending:YES];
            return;
        }
        if (error) {
            AMCloudDiagnostic(@"cloud.plugins.manifest_failed", @{
                @"reason": reason ?: @"unknown",
                @"error": error.localizedDescription ?: @""
            });
            [self finishPluginSyncAllowingPending:NO];
            return;
        }
        BOOL enabled = [manifest[@"enabled"] boolValue];
        NSDictionary *release = [manifest[@"release"] isKindOfClass:NSDictionary.class]
            ? manifest[@"release"] : nil;
        if (!enabled || !release) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                BOOL cleared = AMCloudPluginsRemoveAllIf(^BOOL{
                    return AMCloudAuthMatches(token, authorizationGeneration);
                });
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (![self.pluginSyncOperationID isEqualToString:operationID]) return;
                    if (cleared) {
                        AMCloudDiagnostic(@"cloud.plugins.cleared", @{
                            @"reason": enabled ? @"no_published_release" : @"permission_disabled"
                        });
                    }
                    [self finishPluginSyncAllowingPending:YES];
                });
            });
            return;
        }
        NSString *releaseID = [release[@"id"] isKindOfClass:NSString.class]
            ? release[@"id"] : nil;
        NSString *sha256 = [release[@"sha256"] isKindOfClass:NSString.class]
            ? [release[@"sha256"] lowercaseString] : nil;
        NSDictionary *state = AMCloudPluginsCurrentState();
        if (![state[@"release_id"] isEqualToString:releaseID] ||
            ![[state[@"sha256"] lowercaseString] isEqualToString:sha256]) {
            AMCloudPluginsActivateInstalledRelease(
                releaseID, sha256, authorizationKey, authorizationGeneration);
            state = AMCloudPluginsCurrentState();
        }
        if (releaseID.length && sha256.length == 64 &&
            [state[@"release_id"] isEqualToString:releaseID] &&
            [[state[@"sha256"] lowercaseString] isEqualToString:sha256]) {
            AMCloudDiagnostic(@"cloud.plugins.up_to_date", @{
                @"release_id": releaseID,
                @"effect_count": state[@"effect_count"] ?: @0
            });
            [self finishPluginSyncAllowingPending:YES];
            return;
        }
        [self beginPluginDownloadNoticeForRelease:release operationID:operationID
            token:token authorizationGeneration:authorizationGeneration];
        [self.client downloadPluginRelease:release completion:^(NSDictionary *download,
                                                                 NSError *downloadError) {
            NSURL *archiveURL = [download[@"url"] isKindOfClass:NSURL.class]
                ? download[@"url"] : nil;
            NSURL *cleanupURL = [download[@"cleanup"] isKindOfClass:NSURL.class]
                ? download[@"cleanup"] : archiveURL;
            if (![self.pluginSyncOperationID isEqualToString:operationID]) {
                if (cleanupURL) {
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        [NSFileManager.defaultManager removeItemAtURL:cleanupURL error:nil];
                    });
                }
                return;
            }
            if (!AMCloudAuthMatches(token, authorizationGeneration)) {
                if (cleanupURL) {
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        [NSFileManager.defaultManager removeItemAtURL:cleanupURL error:nil];
                    });
                }
                [self finishPluginDownloadNoticeInstalled:NO state:nil error:nil
                    cancelled:YES operationID:operationID];
                [self finishPluginSyncAllowingPending:YES];
                return;
            }
            if (downloadError || !archiveURL) {
                AMCloudDiagnostic(@"cloud.plugins.download_failed", @{
                    @"release_id": releaseID ?: @"",
                    @"error": downloadError.localizedDescription ?: @"missing download"
                });
                [self finishPluginDownloadNoticeInstalled:NO state:nil
                    error:downloadError ?: AMCloudError(24, @"云端插件下载失败")
                    cancelled:NO operationID:operationID];
                [self finishPluginSyncAllowingPending:NO];
                return;
            }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSError *installError = nil;
                BOOL tokenUnchanged = AMCloudAuthMatches(token, authorizationGeneration);
                BOOL installed = tokenUnchanged && AMCloudPluginsInstallArchive(
                    archiveURL, releaseID, sha256, authorizationKey,
                    authorizationGeneration, ^BOOL(dispatch_block_t commit) {
                        return AMCloudCommitIfAuthMatches(
                            token, authorizationGeneration, commit);
                    }, &installError);
                if (installed && !AMCloudAuthMatches(token, authorizationGeneration)) {
                    installed = NO;
                    tokenUnchanged = NO;
                }
                [NSFileManager.defaultManager removeItemAtURL:cleanupURL error:nil];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (![self.pluginSyncOperationID isEqualToString:operationID]) return;
                    if (installed) {
                        NSDictionary *newState = AMCloudPluginsCurrentState();
                        AMCloudDiagnostic(@"cloud.plugins.installed", @{
                            @"release_id": releaseID ?: @"",
                            @"effect_count": newState[@"effect_count"] ?: @0
                        });
                        [self finishPluginDownloadNoticeInstalled:YES state:newState
                            error:nil cancelled:NO operationID:operationID];
                    } else if (tokenUnchanged) {
                        AMCloudDiagnostic(@"cloud.plugins.install_failed", @{
                            @"release_id": releaseID ?: @"",
                            @"error": installError.localizedDescription ?: @"unknown"
                        });
                        [self finishPluginDownloadNoticeInstalled:NO state:nil
                            error:installError ?: AMCloudError(25, @"云端插件安装失败")
                            cancelled:NO operationID:operationID];
                    } else {
                        [self finishPluginDownloadNoticeInstalled:NO state:nil
                            error:nil cancelled:YES operationID:operationID];
                    }
                    [self finishPluginSyncAllowingPending:installed || !tokenUnchanged];
                });
            });
        }];
    }];
}

- (void)beginPluginDownloadNoticeForRelease:(NSDictionary *)release
                                operationID:(NSString *)operationID
                                      token:(NSString *)token
                         authorizationGeneration:(uint64_t)authorizationGeneration {
    if (!operationID.length || !token.length ||
        !AMCloudAuthMatches(token, authorizationGeneration)) return;
    NSNumber *size = [release[@"sizeBytes"] isKindOfClass:NSNumber.class]
        ? release[@"sizeBytes"] : nil;
    self.pluginDownloadNoticeOperationID = operationID;
    self.pluginDownloadNoticeToken = token;
    self.pluginDownloadNoticeGeneration = authorizationGeneration;
    self.pluginDownloadNoticeTitle = @"正在下载云端插件";
    self.pluginDownloadNoticeMessage = size.longLongValue > 0
        ? [NSString stringWithFormat:@"正在自动下载 %@ 的云端插件，完成前请勿退出软件。",
                                      AMCloudByteText(size.longLongValue)]
        : @"正在自动下载云端插件，完成前请勿退出软件。";
    self.pluginDownloadNoticeBusy = YES;
    self.pluginDownloadNoticeSuppressed = NO;
    [self showPluginDownloadNoticeIfPossible];
}

- (void)finishPluginDownloadNoticeInstalled:(BOOL)installed
                                      state:(NSDictionary *)state
                                      error:(NSError *)error
                                  cancelled:(BOOL)cancelled
                                operationID:(NSString *)operationID {
    if (![self.pluginDownloadNoticeOperationID isEqualToString:operationID]) return;
    BOOL authenticationMatches = AMCloudAuthMatches(
        self.pluginDownloadNoticeToken, self.pluginDownloadNoticeGeneration);
    if (cancelled || !authenticationMatches) {
        [self cancelPluginDownloadNotice];
        return;
    }
    NSNumber *effectCount = [state[@"effect_count"] isKindOfClass:NSNumber.class]
        ? state[@"effect_count"] : nil;
    self.pluginDownloadNoticeBusy = NO;
    self.pluginDownloadNoticeSuppressed = NO;
    self.pluginDownloadNoticeTitle = installed
        ? @"云端插件下载完成" : @"云端插件下载失败";
    self.pluginDownloadNoticeMessage = installed
        ? (effectCount.unsignedIntegerValue > 0
            ? [NSString stringWithFormat:@"已安装 %@ 个插件效果，重新打开效果页面即可使用。",
                                          effectCount]
            : @"插件已经安装，重新打开效果页面即可使用。")
        : (error.localizedDescription ?: @"请检查网络后重新打开软件重试。");
    [self.pluginDownloadOverlay removeFromSuperview];
    self.pluginDownloadOverlay = nil;
    [self showPluginDownloadNoticeIfPossible];
}

- (void)showPluginDownloadNoticeIfPossible {
    if (!self.pluginDownloadNoticeOperationID.length ||
        (self.pluginDownloadNoticeBusy && self.pluginDownloadNoticeSuppressed) ||
        self.pluginDownloadOverlay) return;
    if (!AMCloudAuthMatches(self.pluginDownloadNoticeToken,
                            self.pluginDownloadNoticeGeneration)) {
        [self cancelPluginDownloadNotice];
        return;
    }
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
        if (window) break;
    }
    if (!window) return;

    UIView *overlay = [[UIView alloc] initWithFrame:window.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.36];
    UIView *panel = [UIView new];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = UIColor.systemBackgroundColor;
    panel.layer.cornerRadius = 8;
    panel.layer.masksToBounds = YES;
    [overlay addSubview:panel];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textAlignment = NSTextAlignmentCenter;
    title.text = self.pluginDownloadNoticeTitle;
    UILabel *message = [UILabel new];
    message.translatesAutoresizingMaskIntoConstraints = NO;
    message.font = [UIFont systemFontOfSize:13];
    message.textColor = UIColor.secondaryLabelColor;
    message.textAlignment = NSTextAlignmentCenter;
    message.numberOfLines = 0;
    message.text = self.pluginDownloadNoticeMessage;
    [panel addSubview:title];
    [panel addSubview:message];

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    spinner.hidden = !self.pluginDownloadNoticeBusy;
    if (self.pluginDownloadNoticeBusy) [spinner startAnimating];
    [panel addSubview:spinner];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [button setTitle:self.pluginDownloadNoticeBusy ? @"隐藏" : @"好"
            forState:UIControlStateNormal];
    [button addTarget:self action:@selector(hidePluginDownloadNotice)
     forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:button];
    NSLayoutConstraint *panelWidth =
        [panel.widthAnchor constraintEqualToConstant:320];
    panelWidth.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        panelWidth,
        [panel.widthAnchor constraintLessThanOrEqualToAnchor:overlay.widthAnchor
                                                   multiplier:0.82],
        [title.topAnchor constraintEqualToAnchor:panel.topAnchor constant:20],
        [title.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:18],
        [title.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-18],
        [message.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [message.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:18],
        [message.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-18],
        [spinner.topAnchor constraintEqualToAnchor:message.bottomAnchor constant:14],
        [spinner.centerXAnchor constraintEqualToAnchor:panel.centerXAnchor],
        [button.topAnchor constraintEqualToAnchor:spinner.bottomAnchor constant:10],
        [button.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [button.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [button.heightAnchor constraintEqualToConstant:46],
        [button.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor]
    ]];
    self.pluginDownloadOverlay = overlay;
    [window addSubview:overlay];
}

- (void)hidePluginDownloadNotice {
    [self.pluginDownloadOverlay removeFromSuperview];
    self.pluginDownloadOverlay = nil;
    if (self.pluginDownloadNoticeBusy) {
        self.pluginDownloadNoticeSuppressed = YES;
    } else {
        [self cancelPluginDownloadNotice];
    }
}

- (void)cancelPluginDownloadNotice {
    [self.pluginDownloadOverlay removeFromSuperview];
    self.pluginDownloadOverlay = nil;
    self.pluginDownloadNoticeOperationID = nil;
    self.pluginDownloadNoticeToken = nil;
    self.pluginDownloadNoticeGeneration = 0;
    self.pluginDownloadNoticeTitle = nil;
    self.pluginDownloadNoticeMessage = nil;
    self.pluginDownloadNoticeBusy = NO;
    self.pluginDownloadNoticeSuppressed = NO;
}

- (void)finishPluginSyncAllowingPending:(BOOL)allowPending {
    self.pluginSyncInFlight = NO;
    self.pluginSyncOperationID = nil;
    if (!allowPending) {
        self.pluginSyncPending = NO;
        return;
    }
    if (!self.pluginSyncPending) return;
    self.pluginSyncPending = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        [self syncPluginsNow:@"pending"];
    });
}

- (void)attachAccountEntryToController:(UIViewController *)controller {
    if (!AMCloudIsProjectsControllerClass(controller.class)) return;
    if (controller.viewIfLoaded.window && !controller.viewIfLoaded.hidden &&
        controller.viewIfLoaded.alpha > 0.01) {
        self.lastProjectsController = controller;
    }
    NSArray<UIBarButtonItem *> *current = controller.navigationItem.rightBarButtonItems ?: @[];
    UIImage *image = self.accountAvatarImage;
    if (@available(iOS 13.0, *)) image = [UIImage systemImageNamed:@"person.crop.circle"];
	if (self.accountAvatarImage) image = self.accountAvatarImage;
    UIBarButtonItem *accountItem = image
        ? [[UIBarButtonItem alloc] initWithImage:image style:UIBarButtonItemStylePlain
                                         target:self action:@selector(showAccountEntry:)]
        : [[UIBarButtonItem alloc] initWithTitle:@"账户" style:UIBarButtonItemStylePlain
                                          target:self action:@selector(showAccountEntry:)];
    accountItem.accessibilityIdentifier = AMCloudAccountEntryIdentifier;
    accountItem.accessibilityLabel = @"猫鹤账户";
    NSMutableArray<UIBarButtonItem *> *updated = [current mutableCopy];
    if (updated.count) updated[0] = accountItem;
    else [updated addObject:accountItem];
    controller.navigationItem.rightBarButtonItems = updated;
	if (AMCloudReadToken().length && !self.accountAvatarImage && !self.accountAvatarRequestID.length) {
		[self refreshAccountAvatar];
	}
    AMCloudDiagnostic(@"cloud.account.entry_attached", @{
        @"controller": AMCloudClassName(controller),
        @"previous_item_count": @(current.count)
    });
}

- (void)showAccountEntry:(id)sender {
    UIViewController *presenter = AMCloudTopController(nil) ?: self.lastProjectsController;
    AMCloudDiagnostic(@"cloud.account.tap", @{
        @"sender": AMCloudClassName(sender),
        @"presenter": AMCloudClassName(presenter),
        @"authenticated": @(AMCloudReadToken().length > 0)
    });
    if (AMCloudIsProjectsControllerClass(presenter.class)) {
        self.lastProjectsController = presenter;
    }
    [self showAccountFrom:presenter];
}

- (UIAlertController *)busyAlert:(NSString *)title presenter:(UIViewController *)presenter {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:@"\n" preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [alert.view addSubview:spinner];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:alert.view.centerXAnchor],
        [spinner.bottomAnchor constraintEqualToAnchor:alert.view.bottomAnchor constant:-18]
    ]];
    [spinner startAnimating];
    [AMCloudTopController(presenter) presentViewController:alert animated:YES completion:nil];
    return alert;
}

- (void)showError:(NSError *)error presenter:(UIViewController *)presenter {
    UIViewController *top = AMCloudTopController(presenter);
    if (!top) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"云工程"
        message:error.localizedDescription ?: @"操作失败"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
                                            handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

- (void)showAuthenticationFrom:(UIViewController *)presenter
                     completion:(dispatch_block_t)completion {
    [self showAuthenticationFrom:presenter completion:completion cancellation:nil];
}

- (void)showAuthenticationFrom:(UIViewController *)presenter
                     completion:(dispatch_block_t)completion
                    cancellation:(dispatch_block_t)cancellation {
    UIViewController *top = AMCloudTopController(presenter);
    AMCloudDiagnostic(@"cloud.account.auth_route", @{
        @"presenter": AMCloudClassName(presenter),
        @"top": AMCloudClassName(top)
    });
    if (!top) {
        AMCloudDiagnostic(@"cloud.account.route_failed", @{
            @"stage": @"authentication", @"reason": @"missing_presenter"
        });
        return;
    }
    UIAlertController *choice = [UIAlertController alertControllerWithTitle:@"猫鹤账户"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [choice addAction:[UIAlertAction actionWithTitle:@"登录" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            AMCloudAfterAlertAction(^{
                [weakSelf showCredentialsFrom:top registerAccount:NO completion:completion];
            });
        }]];
    [choice addAction:[UIAlertAction actionWithTitle:@"注册" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            AMCloudAfterAlertAction(^{
                [weakSelf showCredentialsFrom:top registerAccount:YES completion:completion];
            });
        }]];
    [choice addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
        handler:^(__unused UIAlertAction *action) {
            AMCloudDiagnostic(@"cloud.account.auth_cancelled", @{
                @"presenter": AMCloudClassName(presenter)
            });
            if (cancellation) cancellation();
        }]];
    UIPopoverPresentationController *popover = choice.popoverPresentationController;
    if (popover) {
        popover.sourceView = top.view;
        popover.sourceRect = CGRectMake(CGRectGetMaxX(top.view.bounds) - 30, 30, 1, 1);
    }
    AMCloudDiagnostic(@"cloud.account.auth_present_begin", @{
        @"top": AMCloudClassName(top)
    });
    [top presentViewController:choice animated:YES completion:^{
        AMCloudDiagnostic(@"cloud.account.auth_present_completed", @{
            @"top": AMCloudClassName(top)
        });
    }];
}

- (void)showCredentialsFrom:(UIViewController *)presenter registerAccount:(BOOL)registerAccount
                  completion:(dispatch_block_t)completion {
    NSString *title = registerAccount ? @"注册猫鹤账户" : @"登录猫鹤账户";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"用户名";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.textContentType = UITextContentTypeUsername;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"密码";
        field.secureTextEntry = YES;
        field.textContentType = registerAccount
            ? UITextContentTypeNewPassword : UITextContentTypePassword;
    }];
    if (registerAccount) {
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = @"昵称（可选）";
            field.textContentType = UITextContentTypeNickname;
        }];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:registerAccount ? @"注册" : @"登录"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *username = [alert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *password = alert.textFields.count > 1 ? alert.textFields[1].text : @"";
        NSString *nickname = alert.textFields.count > 2 ? alert.textFields[2].text : @"";
        if (!username.length || !password.length) {
            AMCloudAfterAlertAction(^{
                [weakSelf showError:AMCloudError(10, @"请输入用户名和密码")
                          presenter:presenter];
            });
            return;
        }
        AMCloudAfterAlertAction(^{
            UIAlertController *busy = [weakSelf busyAlert:
                registerAccount ? @"正在注册" : @"正在登录" presenter:presenter];
            [weakSelf.client loginUsername:username password:password nickname:nickname
                           registerAccount:registerAccount completion:^(id data, NSError *error) {
                (void)data;
                [busy dismissViewControllerAnimated:YES completion:^{
                    if (error) [weakSelf showError:error presenter:presenter];
                    else if (completion) completion();
                }];
            }];
        });
    }]];
    [AMCloudTopController(presenter) presentViewController:alert animated:YES completion:nil];
}

- (UIViewController *)newAccountControllerForRoute:(NSString *)route {
    AMCloudDiagnostic(@"cloud.account.controller_create_begin", @{
        @"route": route ?: @""
    });
    AMCloudAccountWebViewController *account = [AMCloudAccountWebViewController new];
    account.manager = self;
    account.route = route ?: @"";
    self.accountController = account;
    AMCloudDiagnostic(@"cloud.account.controller_created", @{
        @"route": route ?: @"",
        @"controller": AMCloudClassName(account)
    });
    return account;
}

- (void)reloadAccountControllerIfSupported {
    UIViewController *account = self.accountController;
    if ([account respondsToSelector:@selector(reloadCloudData)]) {
        [(AMCloudAccountViewController *)account reloadCloudData];
    }
}

- (void)showAccountFrom:(UIViewController *)presenter {
    AMCloudDiagnostic(@"cloud.account.token_read_begin", @{
        @"route": @"modal"
    });
    BOOL authenticated = AMCloudReadToken().length > 0;
    AMCloudDiagnostic(@"cloud.account.token_read_end", @{
        @"route": @"modal",
        @"authenticated": @(authenticated)
    });
    AMCloudDiagnostic(@"cloud.account.top_controller_begin", @{
        @"route": @"modal",
        @"presenter": AMCloudClassName(presenter)
    });
    UIViewController *top = AMCloudTopController(presenter);
    AMCloudDiagnostic(@"cloud.account.top_controller_end", @{
        @"route": @"modal",
        @"top": AMCloudClassName(top)
    });
    AMCloudDiagnostic(@"cloud.account.route", @{
        @"presenter": AMCloudClassName(presenter),
        @"top": AMCloudClassName(top),
        @"authenticated": @(authenticated)
    });
    if (!top) {
        AMCloudDiagnostic(@"cloud.account.route_failed", @{
            @"stage": @"account", @"reason": @"missing_presenter"
        });
        return;
    }
    @try {
        UIViewController *account = [self newAccountControllerForRoute:@"modal"];
        UINavigationController *navigation = [[UINavigationController alloc]
            initWithRootViewController:account];
        navigation.modalPresentationStyle = UIModalPresentationAutomatic;
        AMCloudDiagnostic(@"cloud.account.present_begin", @{
            @"top": AMCloudClassName(top),
            @"navigation": AMCloudClassName(navigation)
        });
        [top presentViewController:navigation animated:YES completion:^{
            AMCloudDiagnostic(@"cloud.account.present_completed", @{
                @"top": AMCloudClassName(top),
                @"visible": AMCloudClassName(navigation.visibleViewController)
            });
        }];
        AMCloudDiagnostic(@"cloud.account.present_returned", @{
            @"top": AMCloudClassName(top)
        });
    } @catch (NSException *exception) {
        AMCloudDiagnostic(@"cloud.account.exception", @{
            @"stage": @"show_account",
            @"name": exception.name ?: @"",
            @"reason": exception.reason ?: @""
        });
    }
}

- (void)beginUploadFile:(NSURL *)fileURL title:(NSString *)title
              presenter:(UIViewController *)presenter {
    if (!fileURL || ![NSFileManager.defaultManager isReadableFileAtPath:fileURL.path]) {
        [self showError:AMCloudError(11, @"导出的项目包已不可读取，请重新导出")
                presenter:presenter];
        return;
    }
    if (!AMCloudReadToken().length) {
        __weak typeof(self) weakSelf = self;
        [self showAuthenticationFrom:presenter completion:^{
            [weakSelf beginUploadFile:fileURL title:title presenter:presenter];
        }];
        return;
    }
    UIAlertController *busy = [self busyAlert:@"正在读取云工程" presenter:presenter];
    __weak typeof(self) weakSelf = self;
    [self.client loadProjects:^(NSDictionary *data, NSError *error) {
        [busy dismissViewControllerAnimated:YES completion:^{
            if (error) {
                [weakSelf showError:error presenter:presenter];
                return;
            }
            [weakSelf chooseUploadTarget:data[@"projects"] fileURL:fileURL
                                   title:title presenter:presenter];
        }];
    }];
}

- (void)chooseUploadTarget:(NSArray *)projects fileURL:(NSURL *)fileURL
                      title:(NSString *)title presenter:(UIViewController *)presenter {
    UIViewController *top = AMCloudTopController(presenter);
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"上传云工程"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"新建云工程" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            AMCloudAfterAlertAction(^{
                [weakSelf promptCreateAndUpload:fileURL title:title presenter:presenter];
            });
        }]];
    for (NSDictionary *project in [projects isKindOfClass:NSArray.class] ? projects : @[]) {
        NSString *projectTitle = [project[@"title"] isKindOfClass:NSString.class]
            ? project[@"title"] : @"未命名工程";
        [sheet addAction:[UIAlertAction actionWithTitle:projectTitle style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                AMCloudAfterAlertAction(^{
                    [weakSelf uploadFile:fileURL title:title toProject:project presenter:presenter];
                });
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                            handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = top.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds),
                                       CGRectGetMidY(top.view.bounds), 1, 1);
    }
    [top presentViewController:sheet animated:YES completion:nil];
}

- (void)promptCreateAndUpload:(NSURL *)fileURL title:(NSString *)title
                    presenter:(UIViewController *)presenter {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建云工程"
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"工程名称";
        field.text = title.length ? title : fileURL.lastPathComponent.stringByDeletingPathExtension;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"创建并上传" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
        NSString *name = [alert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length) name = @"未命名工程";
        AMCloudAfterAlertAction(^{
            UIAlertController *busy = [weakSelf busyAlert:@"正在创建云工程" presenter:presenter];
            [weakSelf.client createProject:name completion:^(NSDictionary *data, NSError *error) {
                [busy dismissViewControllerAnimated:YES completion:^{
                    NSDictionary *project = [data[@"project"] isKindOfClass:NSDictionary.class]
                        ? data[@"project"] : nil;
                    if (error || !project) {
                        [weakSelf showError:error ?: AMCloudError(12, @"创建云工程失败")
                                  presenter:presenter];
                    } else {
                        [weakSelf uploadFile:fileURL title:title toProject:project presenter:presenter];
                    }
                }];
            }];
        });
    }]];
    [AMCloudTopController(presenter) presentViewController:alert animated:YES completion:nil];
}

- (void)uploadFile:(NSURL *)fileURL title:(NSString *)title
          toProject:(NSDictionary *)project presenter:(UIViewController *)presenter {
    NSString *projectID = [project[@"id"] isKindOfClass:NSString.class] ? project[@"id"] : nil;
    if (!projectID.length) {
        [self showError:AMCloudError(13, @"云工程标识无效") presenter:presenter];
        return;
    }
    UIAlertController *busy = [self busyAlert:@"正在上传项目包" presenter:presenter];
    __weak typeof(self) weakSelf = self;
    [self.client uploadFile:fileURL projectID:projectID filename:fileURL.lastPathComponent
                 completion:^(id data, NSError *error) {
        (void)data;
        [busy dismissViewControllerAnimated:YES completion:^{
            if (error) {
                [weakSelf showError:error presenter:presenter];
                return;
            }
            UIViewController *top = AMCloudTopController(presenter);
            UIAlertController *success = [UIAlertController alertControllerWithTitle:@"上传完成"
                message:[project[@"title"] isKindOfClass:NSString.class] ? project[@"title"] : title
                preferredStyle:UIAlertControllerStyleAlert];
            [success addAction:[UIAlertAction actionWithTitle:@"好"
                style:UIAlertActionStyleDefault handler:nil]];
            [top presentViewController:success animated:YES completion:nil];
            [weakSelf reloadAccountControllerIfSupported];
        }];
    }];
}

- (void)showActionsForProject:(NSDictionary *)project
                    presenter:(UIViewController *)presenter {
    UIViewController *top = AMCloudTopController(presenter);
    NSString *title = [project[@"title"] isKindOfClass:NSString.class]
        ? project[@"title"] : @"云工程";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    if ([project[@"currentVersion"] isKindOfClass:NSDictionary.class]) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"下载并导入" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                AMCloudAfterAlertAction(^{
                    [weakSelf downloadAndImportProject:project presenter:presenter];
                });
            }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"版本历史" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                AMCloudAfterAlertAction(^{
                    [weakSelf showVersionsForProject:project presenter:presenter];
                });
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除云工程" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            AMCloudAfterAlertAction(^{
                [weakSelf confirmDeleteProject:project presenter:presenter];
            });
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                            handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = top.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds),
                                       CGRectGetMidY(top.view.bounds), 1, 1);
    }
    [top presentViewController:sheet animated:YES completion:nil];
}

- (void)downloadAndImportProject:(NSDictionary *)project
                       presenter:(UIViewController *)presenter {
    UIAlertController *busy = [self busyAlert:@"正在下载项目包" presenter:presenter];
    __weak typeof(self) weakSelf = self;
    [self.client downloadProject:project completion:^(NSDictionary *data, NSError *error) {
        [busy dismissViewControllerAnimated:YES completion:^{
            NSURL *URL = [data[@"url"] isKindOfClass:NSURL.class] ? data[@"url"] : nil;
            NSString *filename = [data[@"filename"] isKindOfClass:NSString.class]
                ? data[@"filename"] : @"project.amproj";
            NSURL *cleanupURL = [data[@"cleanupURL"] isKindOfClass:NSURL.class]
                ? data[@"cleanupURL"] : URL;
            __block BOOL accepted = NO;
            @try {
                accepted = !error && URL && weakSelf.importHandler
                    ? weakSelf.importHandler(URL, filename, cleanupURL) : NO;
            } @finally {
                if (cleanupURL) {
                    [NSFileManager.defaultManager removeItemAtURL:cleanupURL error:nil];
                }
            }
            if (error || !accepted) {
                [weakSelf showError:error ?: AMCloudError(14, @"项目包未能进入本地导入队列")
                          presenter:presenter];
            } else {
                [presenter dismissViewControllerAnimated:YES completion:nil];
            }
        }];
    }];
}

- (void)showVersionsForProject:(NSDictionary *)project
                     presenter:(UIViewController *)presenter {
    NSString *projectID = [project[@"id"] isKindOfClass:NSString.class] ? project[@"id"] : nil;
    UIAlertController *busy = [self busyAlert:@"正在读取版本历史" presenter:presenter];
    __weak typeof(self) weakSelf = self;
    [self.client loadVersions:projectID completion:^(NSDictionary *data, NSError *error) {
        [busy dismissViewControllerAnimated:YES completion:^{
            if (error) {
                [weakSelf showError:error presenter:presenter];
                return;
            }
            [weakSelf presentVersions:data[@"versions"] project:project presenter:presenter];
        }];
    }];
}

- (void)presentVersions:(NSArray *)versions project:(NSDictionary *)project
               presenter:(UIViewController *)presenter {
    UIViewController *top = AMCloudTopController(presenter);
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"版本历史"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSDictionary *version in [versions isKindOfClass:NSArray.class] ? versions : @[]) {
        NSNumber *number = [version[@"versionNumber"] isKindOfClass:NSNumber.class]
            ? version[@"versionNumber"] : @0;
        NSNumber *size = [version[@"sizeBytes"] isKindOfClass:NSNumber.class]
            ? version[@"sizeBytes"] : @0;
        NSString *label = [NSString stringWithFormat:@"v%@ · %@ · %@", number,
            AMCloudDateText(version[@"createdAt"]), AMCloudByteText(size.longLongValue)];
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                AMCloudAfterAlertAction(^{
                    [weakSelf confirmRestoreVersion:version project:project presenter:presenter];
                });
            }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                            handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = top.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds),
                                       CGRectGetMidY(top.view.bounds), 1, 1);
    }
    [top presentViewController:sheet animated:YES completion:nil];
}

- (void)confirmRestoreVersion:(NSDictionary *)version project:(NSDictionary *)project
                    presenter:(UIViewController *)presenter {
    NSNumber *number = [version[@"versionNumber"] isKindOfClass:NSNumber.class]
        ? version[@"versionNumber"] : @0;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"恢复版本"
        message:[NSString stringWithFormat:@"将 v%@ 设为当前版本？", number]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"恢复" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
        AMCloudAfterAlertAction(^{
            NSString *projectID = project[@"id"];
            NSString *versionID = version[@"id"];
            UIAlertController *busy = [weakSelf busyAlert:@"正在恢复版本" presenter:presenter];
            [weakSelf.client restoreProject:projectID versionID:versionID
                                  completion:^(id data, NSError *error) {
                (void)data;
                [busy dismissViewControllerAnimated:YES completion:^{
                    if (error) [weakSelf showError:error presenter:presenter];
                    else [weakSelf reloadAccountControllerIfSupported];
                }];
            }];
        });
    }]];
    [AMCloudTopController(presenter) presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDeleteProject:(NSDictionary *)project
                   presenter:(UIViewController *)presenter {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除云工程"
        message:@"云端项目及其全部版本将被移入删除状态。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
        AMCloudAfterAlertAction(^{
            UIAlertController *busy = [weakSelf busyAlert:@"正在删除云工程" presenter:presenter];
            [weakSelf.client deleteProject:project[@"id"] completion:^(id data, NSError *error) {
                (void)data;
                [busy dismissViewControllerAnimated:YES completion:^{
                    if (error) [weakSelf showError:error presenter:presenter];
                    else [weakSelf reloadAccountControllerIfSupported];
                }];
            }];
        });
    }]];
    [AMCloudTopController(presenter) presentViewController:alert animated:YES completion:nil];
}

@end

@implementation AMCloudAccountViewController

- (void)viewDidLoad {
    AMCloudDiagnostic(@"cloud.account.view_load_enter", @{
        @"controller": AMCloudClassName(self)
    });
    [super viewDidLoad];
    AMCloudDiagnostic(@"cloud.account.view_load_super_returned", @{
        @"controller": AMCloudClassName(self)
    });
    self.title = @"猫鹤账户";
    self.account = @{};
    self.usage = @{};
    self.projects = @[];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self
        action:@selector(closeAccount)];
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self
        action:@selector(reloadCloudData)];
    UIBarButtonItem *create = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self
        action:@selector(createCloudProject)];
    self.navigationItem.rightBarButtonItems = @[create, refresh];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reloadCloudData)
                  forControlEvents:UIControlEventValueChanged];
    AMCloudDiagnostic(@"cloud.account.view_load_configured", @{
        @"controller": AMCloudClassName(self),
        @"manager": AMCloudClassName(self.manager)
    });
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    AMCloudDiagnostic(@"cloud.account.view_did_appear", @{
        @"controller": AMCloudClassName(self),
        @"navigation": AMCloudClassName(self.navigationController),
        @"presenting": AMCloudClassName(self.presentingViewController)
    });
    [self ensureAccountReady];
}

- (void)ensureAccountReady {
    if (self.contentLoaded || self.authenticationPending) return;
    AMCloudDiagnostic(@"cloud.account.token_read_begin", @{
        @"route": @"controller"
    });
    BOOL authenticated = AMCloudReadToken().length > 0;
    AMCloudDiagnostic(@"cloud.account.token_read_end", @{
        @"route": @"controller",
        @"authenticated": @(authenticated)
    });
    self.authenticated = authenticated;
    [self.tableView reloadData];
    if (authenticated) {
        self.contentLoaded = YES;
        [self reloadCloudData];
        return;
    }

    [self beginAuthentication];
}

- (void)beginAuthentication {
    if (self.authenticationPending) return;

    self.authenticationPending = YES;
    self.authenticated = NO;
    self.contentLoaded = NO;
    [self resetAccountContent];
    __weak typeof(self) weakSelf = self;
    [self.manager showAuthenticationFrom:self completion:^{
        weakSelf.authenticationPending = NO;
        weakSelf.authenticated = YES;
        weakSelf.contentLoaded = YES;
        [weakSelf reloadCloudData];
    } cancellation:^{
        weakSelf.authenticationPending = NO;
        weakSelf.authenticated = NO;
        weakSelf.contentLoaded = NO;
        [weakSelf.tableView reloadData];
    }];
}

- (void)resetAccountContent {
    self.account = @{};
    self.usage = @{};
    self.projects = @[];
    [self.refreshControl endRefreshing];
    [self.tableView reloadData];
}

- (void)closeAccount {
    UINavigationController *navigation = self.navigationController;
    if (navigation.presentingViewController && navigation.viewControllers.firstObject == self) {
        [navigation dismissViewControllerAnimated:YES completion:nil];
    } else if (navigation) {
        [navigation popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)createCloudProject {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"新建云工程"
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"工程名称";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"创建"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *title = [alert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!title.length) return;
        AMCloudAfterAlertAction(^{
            UIAlertController *busy = [weakSelf.manager busyAlert:@"正在创建云工程"
                                                           presenter:weakSelf];
            [weakSelf.manager.client createProject:title completion:^(id data, NSError *error) {
                (void)data;
                [busy dismissViewControllerAnimated:YES completion:^{
                    if (error) [weakSelf.manager showError:error presenter:weakSelf];
                    else [weakSelf reloadCloudData];
                }];
            }];
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)reloadCloudData {
    if (!self.authenticated || !AMCloudReadToken().length) {
        self.authenticated = NO;
        self.contentLoaded = NO;
        [self beginAuthentication];
        return;
    }
    AMCloudDiagnostic(@"cloud.account.reload_begin", @{
        @"controller": AMCloudClassName(self),
        @"manager": AMCloudClassName(self.manager),
        @"client": AMCloudClassName(self.manager.client)
    });
    [self.refreshControl beginRefreshing];
    NSString *requestToken = AMCloudReadToken();
    __weak typeof(self) weakSelf = self;
    [self.manager.client loadMe:^(NSDictionary *data, NSError *error) {
        AMCloudDiagnostic(@"cloud.account.reload_me_result", @{
            @"success": @(error == nil),
            @"error_code": @(error.code),
            @"controller_alive": @(weakSelf != nil)
        });
        if (error) {
            [weakSelf.refreshControl endRefreshing];
            if (error.code == 401) {
                AMCloudInvalidateToken(requestToken);
                NSString *activeToken = AMCloudReadToken();
                if (activeToken.length && ![activeToken isEqualToString:requestToken]) {
                    [weakSelf reloadCloudData];
                } else {
                    weakSelf.authenticated = NO;
                    weakSelf.contentLoaded = NO;
                    weakSelf.authenticationPending = NO;
                    [weakSelf beginAuthentication];
                }
            } else {
                [weakSelf.manager showError:error presenter:weakSelf];
            }
            return;
        }
        weakSelf.authenticated = YES;
        weakSelf.account = data;
        [weakSelf.tableView reloadData];
        [weakSelf.manager.client loadProjects:^(NSDictionary *projectsData,
                                                 NSError *projectsError) {
            AMCloudDiagnostic(@"cloud.account.reload_projects_result", @{
                @"success": @(projectsError == nil),
                @"error_code": @(projectsError.code),
                @"controller_alive": @(weakSelf != nil)
            });
            [weakSelf.refreshControl endRefreshing];
            if (projectsError) {
                [weakSelf.manager showError:projectsError presenter:weakSelf];
                return;
            }
            weakSelf.projects = [projectsData[@"projects"] isKindOfClass:NSArray.class]
                ? projectsData[@"projects"] : @[];
            weakSelf.usage = [projectsData[@"usage"] isKindOfClass:NSDictionary.class]
                ? projectsData[@"usage"] : @{};
            [weakSelf.tableView reloadData];
        }];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section < 2) return 1;
    return MAX(1, self.projects.count);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"猫鹤账户";
    if (section == 1) return @"云空间";
    return @"云工程";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *reuse = @"AMCloudCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                            reuseIdentifier:reuse];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.text = @"";
    cell.detailTextLabel.text = @"";
    if (indexPath.section == 0) {
        if (self.authenticationPending) {
            cell.textLabel.text = @"正在等待登录";
            cell.detailTextLabel.text = @"请在弹出的账户窗口中继续";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (!self.authenticated) {
            cell.textLabel.text = @"登录或注册";
            cell.detailTextLabel.text = @"登录后管理云空间与云工程";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            NSString *nickname = [self.account[@"nickname"] isKindOfClass:NSString.class]
                ? self.account[@"nickname"] : self.account[@"username"];
            cell.textLabel.text = nickname.length ? nickname : @"已登录";
            NSString *username = [self.account[@"username"] isKindOfClass:NSString.class]
                ? self.account[@"username"] : @"";
            NSDictionary *vip = [self.account[@"vip"] isKindOfClass:NSDictionary.class]
                ? self.account[@"vip"] : nil;
            NSString *tier = [vip[@"tier"] isKindOfClass:NSString.class]
                ? [vip[@"tier"] uppercaseString] : @"";
            cell.detailTextLabel.text = tier.length
                ? [NSString stringWithFormat:@"%@ · %@", username, tier]
                : (username.length ? username : @"账户资料尚未加载，可下拉刷新");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if (indexPath.section == 1) {
        if (!self.authenticated) {
            cell.textLabel.text = @"登录后查看云空间";
            cell.detailTextLabel.text = @"";
        } else {
            long long used = [self.usage[@"usedBytes"] longLongValue];
            long long quota = [self.usage[@"quotaBytes"] longLongValue];
            cell.textLabel.text = [NSString stringWithFormat:@"%@ / %@",
                AMCloudByteText(used), AMCloudByteText(quota)];
            cell.detailTextLabel.text = quota > 0 ? @"" : @"当前会员未开通云空间";
        }
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (!self.authenticated) {
        cell.textLabel.text = @"登录后查看云工程";
        cell.detailTextLabel.text = @"";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (!self.projects.count) {
        cell.textLabel.text = @"暂无云工程";
        cell.detailTextLabel.text = @"";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        NSDictionary *project = self.projects[indexPath.row];
        NSDictionary *version = [project[@"currentVersion"] isKindOfClass:NSDictionary.class]
            ? project[@"currentVersion"] : nil;
        cell.textLabel.text = [project[@"title"] isKindOfClass:NSString.class]
            ? project[@"title"] : @"未命名工程";
        if (version) {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"v%@ · %@ · %@",
                version[@"versionNumber"] ?: @0,
                AMCloudByteText([version[@"sizeBytes"] longLongValue]),
                AMCloudDateText(project[@"updatedAt"])];
        } else {
            cell.detailTextLabel.text = @"尚未上传项目包";
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (self.authenticationPending) return;
        if (!self.authenticated) {
            [self beginAuthentication];
            return;
        }
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"猫鹤账户"
            message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:@"退出登录" style:UIAlertActionStyleDestructive
            handler:^(__unused UIAlertAction *action) {
                AMCloudDiagnostic(@"cloud.account.logout_begin", @{
                    @"controller": AMCloudClassName(weakSelf)
                });
                [weakSelf.manager.client logout:^(__unused id data, NSError *error) {
                    AMCloudDiagnostic(@"cloud.account.logout_result", @{
                        @"success": @(error == nil),
                        @"error_code": @(error.code),
                        @"controller_alive": @(weakSelf != nil)
                    });
                    weakSelf.authenticated = NO;
                    weakSelf.authenticationPending = NO;
                    weakSelf.contentLoaded = NO;
                    [weakSelf resetAccountContent];
                    [weakSelf closeAccount];
                }];
            }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                                                handler:nil]];
        UIPopoverPresentationController *popover = sheet.popoverPresentationController;
        if (popover) {
            UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
            popover.sourceView = cell;
            popover.sourceRect = cell.bounds;
        }
        [self presentViewController:sheet animated:YES completion:nil];
    } else if (indexPath.section == 2 && self.projects.count) {
        [self.manager showActionsForProject:self.projects[indexPath.row] presenter:self];
    }
}

@end


void AMCloudSyncInstallPluginHooksEarly(void) {
    NSString *token = nil;
    NSString *authorizationKey = nil;
    uint64_t authorizationGeneration = 0;
    AMCloudReadAuthContext(&token, &authorizationGeneration, &authorizationKey);
    AMCloudPluginsInstallBundleHooks();
    if (token.length) {
        AMCloudPluginsRestoreInstalledReleaseForAuthorization(
            authorizationKey, authorizationGeneration);
    }
}

void AMCloudSyncInstall(AMCloudImportHandler importHandler) {
    [[AMCloudManager shared] installWithImportHandler:importHandler];
}

void AMCloudAuthorizeFeature(NSString *feature, UIViewController *presenter,
                             AMCloudAuthorizationCompletion completion) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AMCloudAuthorizeFeature(feature, presenter, completion);
        });
        return;
    }
    AMCloudManager *manager = [AMCloudManager shared];
    UIViewController *top = AMCloudTopController(presenter);
    void (^deny)(NSError *) = ^(NSError *error) {
        if (completion) completion(NO, error);
        if (!top || top.presentedViewController) return;
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"iOS 权限未通过"
            message:error.localizedDescription ?: @"请登录账户并联系管理员开通权限"
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"打开账户"
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                [manager showAccountFrom:top];
            }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消"
            style:UIAlertActionStyleCancel handler:nil]];
        [top presentViewController:alert animated:YES completion:nil];
    };
    if (!AMCloudReadToken().length) {
        deny(AMCloudError(401, @"请先登录猫鹤账户；iOS 权限由管理员后台开通"));
        return;
    }
    [manager.client authorizeFeature:feature completion:^(__unused id data, NSError *error) {
        AMCloudDiagnostic(@"cloud.authorization.result", @{
            @"feature": feature ?: @"",
            @"allowed": @(error == nil),
            @"error_code": @(error.code)
        });
        if (error) {
            deny(error);
            return;
        }
        if (completion) completion(YES, nil);
    }];
}

UIViewController *AMCloudSyncReplacementForNativeAccountPresentation(
    UIViewController *presenter, UIViewController *controller) {
    if (![NSThread isMainThread] || !presenter || !controller ||
        !AMCloudContainsNativeAccountController(controller, 0)) {
        return nil;
    }
    NSLog(@"[AMProjExport] Replacing native account presentation: %@",
          NSStringFromClass(controller.class));
    AMCloudDiagnostic(@"cloud.account.native_present_intercepted", @{
        @"presenter": AMCloudClassName(presenter),
        @"controller": AMCloudClassName(controller)
    });
    @try {
        AMCloudDiagnostic(@"cloud.account.native_present_dispatch", @{
            @"presenter": AMCloudClassName(presenter)
        });
        AMCloudManager *manager = [AMCloudManager shared];
        if (AMCloudIsProjectsControllerClass(presenter.class)) {
            manager.lastProjectsController = presenter;
        }
        UIViewController *account =
            [manager newAccountControllerForRoute:@"native_present"];
        UINavigationController *navigation = [[UINavigationController alloc]
            initWithRootViewController:account];
        navigation.modalPresentationStyle = controller.modalPresentationStyle;
        AMCloudDiagnostic(@"cloud.account.native_present_replacement_ready", @{
            @"replacement": AMCloudClassName(navigation)
        });
        return navigation;
    } @catch (NSException *exception) {
        AMCloudDiagnostic(@"cloud.account.exception", @{
            @"stage": @"native_present_replacement",
            @"name": exception.name ?: @"",
            @"reason": exception.reason ?: @""
        });
        return nil;
    }
}

UIViewController *AMCloudSyncReplacementForNativeAccountPush(
    UINavigationController *navigationController, UIViewController *controller) {
    if (![NSThread isMainThread] || !navigationController || !controller ||
        !AMCloudContainsNativeAccountController(controller, 0)) {
        return nil;
    }
    NSLog(@"[AMProjExport] Replacing native account push: %@",
          NSStringFromClass(controller.class));
    AMCloudDiagnostic(@"cloud.account.native_push_intercepted", @{
        @"navigation": AMCloudClassName(navigationController),
        @"controller": AMCloudClassName(controller)
    });
    @try {
        UIViewController *presenter = navigationController.visibleViewController ?:
            navigationController;
        AMCloudDiagnostic(@"cloud.account.native_push_dispatch", @{
            @"presenter": AMCloudClassName(presenter)
        });
        AMCloudManager *manager = [AMCloudManager shared];
        if (AMCloudIsProjectsControllerClass(presenter.class)) {
            manager.lastProjectsController = presenter;
        }
        UIViewController *account =
            [manager newAccountControllerForRoute:@"native_push"];
        AMCloudDiagnostic(@"cloud.account.native_push_replacement_ready", @{
            @"replacement": AMCloudClassName(account)
        });
        return account;
    } @catch (NSException *exception) {
        AMCloudDiagnostic(@"cloud.account.exception", @{
            @"stage": @"native_push_replacement",
            @"name": exception.name ?: @"",
            @"reason": exception.reason ?: @""
        });
        return nil;
    }
}

NSArray<UIActivity *> *AMCloudSyncUploadActivities(
    NSURL *fileURL, NSString *projectTitle, UIViewController *presenter) {
    if (!fileURL) return @[];
    AMCloudUploadActivity *activity = [AMCloudUploadActivity new];
    activity.fileURL = fileURL;
    activity.projectTitle = projectTitle.length
        ? projectTitle : fileURL.lastPathComponent.stringByDeletingPathExtension;
    activity.sourcePresenter = presenter;
    return @[activity];
}
