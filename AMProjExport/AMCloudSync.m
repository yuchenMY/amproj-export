#import "AMCloudSync.h"
#import "AMDebugTransport.h"

#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <objc/runtime.h>

static NSString *const AMCloudAPIBase = @"https://am.meowcr.cn/api";
static NSString *const AMCloudKeychainService = @"com.ayakameow.ambeta.amproj-cloud";
static NSString *const AMCloudKeychainAccount = @"bearer-token";
static NSString *const AMCloudErrorDomain = @"com.ayakameow.amproj.cloud";
static NSString *const AMCloudAccountEntryIdentifier = @"AMCloudAccountEntry";

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

static NSString *AMCloudReadToken(void) {
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

static BOOL AMCloudWriteToken(NSString *token) {
    if (!token.length) return NO;
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

static void AMCloudDeleteToken(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: AMCloudKeychainService,
        (__bridge id)kSecAttrAccount: AMCloudKeychainAccount
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
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
- (void)logout:(AMCloudResult)completion;
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
        if (response.statusCode == 401 && authenticated) AMCloudDeleteToken();
        AMCloudCompleteOnMain(completion, payload, responseError);
    }] resume];
}

- (void)loginUsername:(NSString *)username password:(NSString *)password
             nickname:(NSString *)nickname registerAccount:(BOOL)registerAccount
           completion:(AMCloudResult)completion {
    NSMutableDictionary *body = [@{
        @"username": username ?: @"",
        @"password": password ?: @""
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

- (void)logout:(AMCloudResult)completion {
    [self performMethod:@"POST" path:@"/auth/logout" body:@{}
          authenticated:YES completion:^(id data, NSError *error) {
        AMCloudDeleteToken();
        if (completion) completion(data, error);
    }];
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
            if (response.statusCode == 401) AMCloudDeleteToken();
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
            if (response.statusCode == 401) AMCloudDeleteToken();
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

@end

@class AMCloudManager;

@interface AMCloudAccountViewController : UITableViewController
@property(nonatomic, strong) AMCloudManager *manager;
@property(nonatomic, copy) NSDictionary *account;
@property(nonatomic, copy) NSDictionary *usage;
@property(nonatomic, copy) NSArray<NSDictionary *> *projects;
- (void)reloadCloudData;
- (void)createCloudProject;
@end

@interface AMCloudManager : NSObject
@property(nonatomic, strong) AMCloudClient *client;
@property(nonatomic, copy) AMCloudImportHandler importHandler;
@property(nonatomic, weak) UIViewController *lastProjectsController;
@property(nonatomic, weak) AMCloudAccountViewController *accountController;
+ (instancetype)shared;
- (void)installWithImportHandler:(AMCloudImportHandler)importHandler;
- (void)attachAccountEntryToController:(UIViewController *)controller;
- (void)showAccountEntry:(id)sender;
- (void)showAccountFrom:(UIViewController *)presenter;
- (void)showAuthenticationFrom:(UIViewController *)presenter
                     completion:(dispatch_block_t)completion;
- (void)beginUploadFile:(NSURL *)fileURL title:(NSString *)title
              presenter:(UIViewController *)presenter;
- (void)showActionsForProject:(NSDictionary *)project
                    presenter:(UIViewController *)presenter;
- (void)showError:(NSError *)error presenter:(UIViewController *)presenter;
@end

@interface AMCloudManager ()
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
    AMCloudInstallProjectsHooks();
    AMCloudAttachVisibleProjectsControllers();
    [NSNotificationCenter.defaultCenter
        addObserver:self selector:@selector(applicationDidBecomeActive:)
               name:UIApplicationDidBecomeActiveNotification object:nil];
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
}

- (void)attachAccountEntryToController:(UIViewController *)controller {
    if (!AMCloudIsProjectsControllerClass(controller.class)) return;
    if (controller.viewIfLoaded.window && !controller.viewIfLoaded.hidden &&
        controller.viewIfLoaded.alpha > 0.01) {
        self.lastProjectsController = controller;
    }
    NSArray<UIBarButtonItem *> *current = controller.navigationItem.rightBarButtonItems ?: @[];
    if ([current.firstObject.accessibilityIdentifier
            isEqualToString:AMCloudAccountEntryIdentifier]) return;
    UIImage *image = nil;
    if (@available(iOS 13.0, *)) image = [UIImage systemImageNamed:@"person.crop.circle"];
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
                                            handler:nil]];
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

- (void)showAccountFrom:(UIViewController *)presenter {
    BOOL authenticated = AMCloudReadToken().length > 0;
    UIViewController *top = AMCloudTopController(presenter);
    AMCloudDiagnostic(@"cloud.account.route", @{
        @"presenter": AMCloudClassName(presenter),
        @"top": AMCloudClassName(top),
        @"authenticated": @(authenticated)
    });
    if (!authenticated) {
        __weak typeof(self) weakSelf = self;
        [self showAuthenticationFrom:presenter completion:^{
            [weakSelf showAccountFrom:presenter];
        }];
        return;
    }
    if (!top) {
        AMCloudDiagnostic(@"cloud.account.route_failed", @{
            @"stage": @"account", @"reason": @"missing_presenter"
        });
        return;
    }
    @try {
        AMCloudDiagnostic(@"cloud.account.controller_create_begin", @{
            @"top": AMCloudClassName(top)
        });
        AMCloudAccountViewController *account = [[AMCloudAccountViewController alloc]
            initWithStyle:UITableViewStyleInsetGrouped];
        AMCloudDiagnostic(@"cloud.account.controller_created", @{
            @"controller": AMCloudClassName(account)
        });
        account.manager = self;
        self.accountController = account;
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
            [weakSelf.accountController reloadCloudData];
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
                    else [weakSelf.accountController reloadCloudData];
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
                    else [weakSelf.accountController reloadCloudData];
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
    [self reloadCloudData];
}

- (void)closeAccount {
    [self dismissViewControllerAnimated:YES completion:nil];
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
    AMCloudDiagnostic(@"cloud.account.reload_begin", @{
        @"controller": AMCloudClassName(self),
        @"manager": AMCloudClassName(self.manager),
        @"client": AMCloudClassName(self.manager.client)
    });
    [self.refreshControl beginRefreshing];
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
                [weakSelf dismissViewControllerAnimated:YES completion:^{
                    [weakSelf.manager showAuthenticationFrom:weakSelf.manager.lastProjectsController
                                                   completion:^{
                        [weakSelf.manager showAccountFrom:weakSelf.manager.lastProjectsController];
                    }];
                }];
            } else {
                [weakSelf.manager showError:error presenter:weakSelf];
            }
            return;
        }
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
    if (section == 0) return @"账户";
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
            ? [NSString stringWithFormat:@"%@ · %@", username, tier] : username;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 1) {
        long long used = [self.usage[@"usedBytes"] longLongValue];
        long long quota = [self.usage[@"quotaBytes"] longLongValue];
        cell.textLabel.text = [NSString stringWithFormat:@"%@ / %@",
            AMCloudByteText(used), AMCloudByteText(quota)];
        cell.detailTextLabel.text = quota > 0 ? @"" : @"当前会员未开通云空间";
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
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"猫鹤账户"
            message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:@"退出登录" style:UIAlertActionStyleDestructive
            handler:^(__unused UIAlertAction *action) {
                [weakSelf.manager.client logout:^(__unused id data, __unused NSError *error) {
                    [weakSelf dismissViewControllerAnimated:YES completion:nil];
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


void AMCloudSyncInstall(AMCloudImportHandler importHandler) {
    [[AMCloudManager shared] installWithImportHandler:importHandler];
}

BOOL AMCloudSyncHandleNativeAccountPresentation(
    UIViewController *presenter, UIViewController *controller,
    void (^completion)(void)) {
    if (![NSThread isMainThread] || !presenter || !controller ||
        !AMCloudContainsNativeAccountController(controller, 0)) {
        return NO;
    }
    NSLog(@"[AMProjExport] Replacing native account presentation: %@",
          NSStringFromClass(controller.class));
    AMCloudDiagnostic(@"cloud.account.native_present_intercepted", @{
        @"presenter": AMCloudClassName(presenter),
        @"controller": AMCloudClassName(controller),
        @"completion_present": @(completion != nil)
    });
    // 原生展示已被取消，执行其 completion 可能访问仅属于 MyAccountVC 的状态。
    (void)completion;
    dispatch_async(dispatch_get_main_queue(), ^{
        AMCloudDiagnostic(@"cloud.account.native_present_dispatch", @{
            @"presenter": AMCloudClassName(presenter)
        });
        AMCloudManager *manager = [AMCloudManager shared];
        if (AMCloudIsProjectsControllerClass(presenter.class)) {
            manager.lastProjectsController = presenter;
        }
        [manager showAccountFrom:presenter];
    });
    return YES;
}

BOOL AMCloudSyncHandleNativeAccountPush(
    UINavigationController *navigationController, UIViewController *controller) {
    if (![NSThread isMainThread] || !navigationController || !controller ||
        !AMCloudContainsNativeAccountController(controller, 0)) {
        return NO;
    }
    NSLog(@"[AMProjExport] Replacing native account push: %@",
          NSStringFromClass(controller.class));
    AMCloudDiagnostic(@"cloud.account.native_push_intercepted", @{
        @"navigation": AMCloudClassName(navigationController),
        @"controller": AMCloudClassName(controller)
    });
    __weak UINavigationController *weakNavigationController = navigationController;
    dispatch_async(dispatch_get_main_queue(), ^{
        UINavigationController *navigation = weakNavigationController;
        if (!navigation) {
            AMCloudDiagnostic(@"cloud.account.route_failed", @{
                @"stage": @"native_push_dispatch",
                @"reason": @"navigation_released"
            });
            return;
        }
        UIViewController *presenter = navigation.visibleViewController ?: navigation;
        AMCloudDiagnostic(@"cloud.account.native_push_dispatch", @{
            @"presenter": AMCloudClassName(presenter)
        });
        AMCloudManager *manager = [AMCloudManager shared];
        if (AMCloudIsProjectsControllerClass(presenter.class)) {
            manager.lastProjectsController = presenter;
        }
        [manager showAccountFrom:presenter];
    });
    return YES;
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
