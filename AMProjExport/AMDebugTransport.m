#import "AMDebugTransport.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <dispatch/dispatch.h>
#import <math.h>

AMDebugExportMode const AMDebugExportModeObserve = @"observe";
AMDebugExportMode const AMDebugExportModePlaceholder = @"placeholder";
AMDebugExportMode const AMDebugExportModeFull = @"full";

NSString *const AMDebugTransportMarkerHeader = @"X-AMProj-Debug-Transport";

static NSString *const kAMDebugRequestProperty = @"com.amproj.debug.transport";
static const NSUInteger kAMDebugMaxBufferedEvents = 4096;
static const NSUInteger kAMDebugEventBatchSize = 64;
static const NSUInteger kAMDebugMaxEventPayloadBytes = 128 * 1024;
static const NSUInteger kAMDebugMaxArtifactBytes = 32 * 1024 * 1024;
static const NSTimeInterval kAMDebugHelloInterval = 10.0;
static const NSTimeInterval kAMDebugHelloRetryInterval = 5.0;
static NSString *const kAMDebugPluginVersion = @"10";
static void *kAMDebugQueueKey = &kAMDebugQueueKey;

typedef NS_ENUM(NSInteger, AMDebugBackendState) {
    AMDebugBackendStateUnknown = 0,
    AMDebugBackendStateConnecting,
    AMDebugBackendStateConnected,
    AMDebugBackendStateUnavailable,
    AMDebugBackendStateDisabled,
};

static __weak UIView *AMDebugStatusBanner;
static NSUInteger AMDebugStatusGeneration = 0;
static NSString *AMDebugPreviousInterruptedStage = nil;

static NSString *AMDebugStageFilePath(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [caches stringByAppendingPathComponent:@"AMProjExport.laststage"];
}

static void AMDebugLoadPreviousInterruptedStage(void) {
    NSData *data = [NSData dataWithContentsOfFile:AMDebugStageFilePath()
                                         options:NSDataReadingMappedIfSafe error:nil];
    if (!data.length || data.length > 96) return;
    NSString *stage = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyz0123456789_"] invertedSet];
    if (stage.length && [stage rangeOfCharacterFromSet:invalid].location == NSNotFound) {
        AMDebugPreviousInterruptedStage = stage;
    }
}

static UIWindow *AMDebugForegroundWindow(void) {
    UIApplication *application = UIApplication.sharedApplication;
    UIWindow *fallback = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class] ||
                scene.activationState == UISceneActivationStateUnattached) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.hidden || window.alpha <= 0.0) continue;
                if (window.isKeyWindow) return window;
                if (!fallback && window.windowLevel == UIWindowLevelNormal) fallback = window;
            }
        }
    }
    if (fallback) return fallback;
    for (UIWindow *window in application.windows) {
        if (!window.hidden && window.alpha > 0.0) {
            if (window.isKeyWindow) return window;
            if (!fallback && window.windowLevel == UIWindowLevelNormal) fallback = window;
        }
    }
    return fallback;
}

static NSString *AMDebugBackendStateText(AMDebugBackendState state) {
    switch (state) {
        case AMDebugBackendStateConnecting: return @"后端连接中";
        case AMDebugBackendStateConnected: return @"后端已连接";
        case AMDebugBackendStateUnavailable: return @"后端不可达，导出不受影响";
        case AMDebugBackendStateDisabled: return @"后端未配置，导出不受影响";
        default: return @"调试已启动";
    }
}

static UIColor *AMDebugBackendStateColor(AMDebugBackendState state) {
    switch (state) {
        case AMDebugBackendStateConnected:
            return [UIColor colorWithRed:0.08 green:0.47 blue:0.27 alpha:0.94];
        case AMDebugBackendStateUnavailable:
        case AMDebugBackendStateDisabled:
            return [UIColor colorWithRed:0.64 green:0.27 blue:0.08 alpha:0.94];
        default:
            return [UIColor colorWithRed:0.12 green:0.16 blue:0.25 alpha:0.94];
    }
}

static void AMDebugShowStatusAttempt(NSString *mode, AMDebugBackendState state,
                                     NSUInteger attempt, NSUInteger generation) {
    if (generation != AMDebugStatusGeneration) return;
    UIWindow *window = AMDebugForegroundWindow();
    if (!window) {
        if (attempt < 8) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2),
                           dispatch_get_main_queue(), ^{
                AMDebugShowStatusAttempt(mode, state, attempt + 1, generation);
            });
        }
        return;
    }

    UILabel *banner = [AMDebugStatusBanner isKindOfClass:UILabel.class]
        ? (UILabel *)AMDebugStatusBanner : nil;
    if (!banner || banner.superview != window) {
        [banner removeFromSuperview];
        banner = [[UILabel alloc] initWithFrame:CGRectZero];
        banner.userInteractionEnabled = NO;
        banner.textAlignment = NSTextAlignmentCenter;
        banner.textColor = UIColor.whiteColor;
        banner.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        banner.layer.cornerRadius = 10.0;
        banner.layer.masksToBounds = YES;
        banner.numberOfLines = 1;
        banner.alpha = 0.0;
        banner.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                  UIViewAutoresizingFlexibleBottomMargin;
        [window addSubview:banner];
        AMDebugStatusBanner = banner;
    }

    CGFloat top = MAX(window.safeAreaInsets.top, 8.0) + 5.0;
    banner.frame = CGRectMake(12.0, top, MAX(window.bounds.size.width - 24.0, 120.0), 34.0);
    NSString *interruptedStage = AMDebugPreviousInterruptedStage;
    if (interruptedStage.length) {
        banner.text = [NSString stringWithFormat:@"AMProj v%@ · 上次中断：%@",
                       kAMDebugPluginVersion, interruptedStage];
        banner.backgroundColor = [UIColor colorWithRed:0.68 green:0.10 blue:0.10 alpha:0.95];
        AMDebugPreviousInterruptedStage = nil;
        [NSFileManager.defaultManager removeItemAtPath:AMDebugStageFilePath() error:nil];
    } else {
        banner.text = [NSString stringWithFormat:@"AMProj v%@ · %@ · %@",
                       kAMDebugPluginVersion, mode.length ? mode : @"full",
                       AMDebugBackendStateText(state)];
        banner.backgroundColor = AMDebugBackendStateColor(state);
    }
    [window bringSubviewToFront:banner];

    [UIView animateWithDuration:0.18 animations:^{ banner.alpha = 1.0; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (generation != AMDebugStatusGeneration || banner != AMDebugStatusBanner) return;
        [UIView animateWithDuration:0.22 animations:^{ banner.alpha = 0.0; }
                         completion:^(__unused BOOL finished) { [banner removeFromSuperview]; }];
    });
}

static void AMDebugShowStatus(NSString *mode, AMDebugBackendState state) {
    NSString *modeSnapshot = [mode copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        AMDebugStatusGeneration += 1;
        AMDebugShowStatusAttempt(modeSnapshot, state, 0, AMDebugStatusGeneration);
    });
}

static NSNumber *AMDebugNowMilliseconds(void) {
    return @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0));
}

static BOOL AMDebugValidMode(NSString *mode) {
    return [mode isEqualToString:AMDebugExportModeObserve] ||
           [mode isEqualToString:AMDebugExportModePlaceholder] ||
           [mode isEqualToString:AMDebugExportModeFull];
}

static id AMDebugJSONValue(id value, NSUInteger depth) {
    if (!value || value == NSNull.null) return NSNull.null;
    if (depth > 8) return @"<max-depth>";
    if ([value isKindOfClass:NSString.class]) {
        NSString *string = value;
        if (string.length <= 8192) return string;
        return [[string substringToIndex:8192] stringByAppendingString:@"<truncated>"];
    }
    if ([value isKindOfClass:NSNumber.class]) {
        double number = [value doubleValue];
        return isfinite(number) ? value : [value description];
    }
    if ([value isKindOfClass:NSURL.class]) return [value absoluteString] ?: @"";
    if ([value isKindOfClass:NSDate.class]) {
        return @((long long)([(NSDate *)value timeIntervalSince1970] * 1000.0));
    }
    if ([value isKindOfClass:NSError.class]) {
        NSError *error = value;
        return @{
            @"domain": error.domain ?: @"",
            @"code": @(error.code),
            @"description": error.localizedDescription ?: @""
        };
    }
    if ([value isKindOfClass:NSData.class]) {
        return @{ @"data_length": @([(NSData *)value length]) };
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        __block NSUInteger count = 0;
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id object, BOOL *stop) {
            if (count++ >= 256) {
                result[@"_truncated"] = @YES;
                *stop = YES;
                return;
            }
            NSString *name = [key isKindOfClass:NSString.class] ? key : [key description];
            if (name) result[name] = AMDebugJSONValue(object, depth + 1);
        }];
        return result;
    }
    if ([value isKindOfClass:NSArray.class] || [value isKindOfClass:NSSet.class]) {
        NSArray *objects = [value isKindOfClass:NSArray.class] ? value : [(NSSet *)value allObjects];
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:MIN(objects.count, 256)];
        NSUInteger count = 0;
        for (id object in objects) {
            if (count++ >= 256) {
                [result addObject:@"<truncated>"];
                break;
            }
            [result addObject:AMDebugJSONValue(object, depth + 1)];
        }
        return result;
    }
    return [value description] ?: @"<unknown>";
}

@interface AMDebugTransport ()

@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong, nullable) dispatch_source_t flushTimer;
@property(nonatomic, strong, nullable) dispatch_source_t pollTimer;
@property(nonatomic, strong, nullable) NSURLSession *URLSession;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *pendingEvents;
@property(nonatomic, strong) NSMutableSet<NSString *> *capturedTransactions;
@property(nonatomic, strong) NSArray *notificationTokens;
@property(nonatomic, strong) id protocolVersion;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, copy) NSString *mode;
@property(nonatomic, copy, nullable) NSString *activeTransactionIdentifier;
@property(nonatomic, copy, nullable) NSString *commandCursor;
@property(nonatomic, strong) NSDictionary *helloMetadata;
@property(nonatomic, readwrite, getter=isEnabled) BOOL enabled;
@property(nonatomic, copy, readwrite) NSString *sessionIdentifier;
@property(nonatomic, copy, readwrite, nullable) NSURL *baseURL;
@property(nonatomic) uint64_t sequence;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL foreground;
@property(nonatomic) BOOL eventsInFlight;
@property(nonatomic) BOOL helloInFlight;
@property(nonatomic) BOOL helloDelivered;
@property(nonatomic) BOOL pollInFlight;
@property(nonatomic) BOOL captureNextPending;
@property(nonatomic) AMDebugBackendState backendState;
@property(nonatomic) NSTimeInterval eventRetryDelay;
@property(nonatomic) NSTimeInterval nextEventAttempt;
@property(nonatomic) NSTimeInterval nextHelloAttempt;
@property(nonatomic) NSUInteger eventBatchCountLimit;

- (instancetype)initPrivate;
- (void)performSync:(dispatch_block_t)block;
- (void)installApplicationObservers;
- (void)startTimers;
- (void)stopTimers;
- (void)appendEvent:(NSString *)name fields:(NSDictionary *)fields;
- (NSMutableURLRequest *)requestForPath:(NSString *)path method:(NSString *)method;
- (void)sendHelloForce:(BOOL)force;
- (void)flushEvents;
- (nullable NSData *)eventBodyForBatch:(NSArray<NSDictionary *> *)batch;
- (void)appendRejectedEventSummary:(NSDictionary *)event
                             reason:(NSString *)reason
                       encodedBytes:(NSUInteger)encodedBytes
                         HTTPStatus:(NSInteger)HTTPStatus;
- (void)pollCommands;
- (void)applyCommand:(NSDictionary *)command;
- (void)acknowledgeCommands:(NSArray *)identifiers;
- (void)uploadArtifactBody:(NSData *)body
                      name:(NSString *)name
                  mimeType:(NSString *)mimeType
               transaction:(NSString *)transactionIdentifier;

@end

@implementation AMDebugTransport

+ (instancetype)shared {
    static AMDebugTransport *transport;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        transport = [[self alloc] initPrivate];
    });
    return transport;
}

+ (instancetype)sharedTransport {
    return self.shared;
}

- (instancetype)initPrivate {
    self = [super init];
    if (!self) return nil;

    _queue = dispatch_queue_create("com.amproj.debug.transport", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_queue, kAMDebugQueueKey, kAMDebugQueueKey, NULL);
    _pendingEvents = [NSMutableArray array];
    _capturedTransactions = [NSMutableSet set];
    _notificationTokens = @[];
    _sessionIdentifier = NSUUID.UUID.UUIDString.lowercaseString;
    _mode = AMDebugExportModeFull;
    _backendState = AMDebugBackendStateUnknown;
    _eventRetryDelay = 1.0;
    _eventBatchCountLimit = kAMDebugEventBatchSize;

    NSURL *configURL = [NSBundle.mainBundle URLForResource:@"AMProjDebugConfig"
                                             withExtension:@"plist"];
    NSDictionary *config = configURL ? [NSDictionary dictionaryWithContentsOfURL:configURL] : nil;
    NSString *baseString = [config[@"BaseURL"] isKindOfClass:NSString.class] ? config[@"BaseURL"] : nil;
    NSString *token = [config[@"Token"] isKindOfClass:NSString.class] ? config[@"Token"] : nil;
    id protocolVersion = config[@"ProtocolVersion"];
    NSString *defaultMode = [config[@"DefaultMode"] isKindOfClass:NSString.class]
        ? [config[@"DefaultMode"] lowercaseString] : nil;
    NSURL *baseURL = baseString.length ? [NSURL URLWithString:baseString] : nil;
    NSString *scheme = baseURL.scheme.lowercaseString;

    if (AMDebugValidMode(defaultMode)) _mode = [defaultMode copy];
    NSCharacterSet *newlines = NSCharacterSet.newlineCharacterSet;
    BOOL safeToken = token.length && [token rangeOfCharacterFromSet:newlines].location == NSNotFound;
    BOOL validProtocolVersion = [protocolVersion isKindOfClass:NSNumber.class] ||
        ([protocolVersion isKindOfClass:NSString.class] && [protocolVersion length]);
    if (([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) &&
        baseURL.host.length && safeToken && validProtocolVersion) {
        _baseURL = [baseURL copy];
        _token = [token copy];
        _protocolVersion = AMDebugJSONValue(protocolVersion, 0);
        _enabled = YES;
    } else {
        _token = @"";
        _protocolVersion = @1;
        _enabled = NO;
    }
    return self;
}

- (void)performSync:(dispatch_block_t)block {
    if (dispatch_get_specific(kAMDebugQueueKey) == kAMDebugQueueKey) {
        block();
    } else {
        dispatch_sync(self.queue, block);
    }
}

- (AMDebugExportMode)currentMode {
    __block NSString *mode;
    [self performSync:^{ mode = [self.mode copy]; }];
    return mode ?: AMDebugExportModeObserve;
}

- (void)start {
    if (!self.enabled) {
        AMDebugShowStatus(self.currentMode, AMDebugBackendStateDisabled);
        return;
    }

    __block BOOL shouldStart = NO;
    [self performSync:^{
        if (!self.started) {
            self.started = YES;
            shouldStart = YES;
        }
    }];
    if (!shouldStart) return;

    UIDevice *device = UIDevice.currentDevice;
    NSBundle *bundle = NSBundle.mainBundle;
    BOOL initiallyForeground = UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
    NSDictionary *metadata = @{
        @"app": @{
            @"bundle_id": bundle.bundleIdentifier ?: @"",
            @"version": [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"",
            @"build": [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"",
            @"process": NSProcessInfo.processInfo.processName ?: @""
        },
        @"device": @{
            @"id": device.identifierForVendor.UUIDString.lowercaseString ?: @"",
            @"model": device.model ?: @"",
            @"system_name": device.systemName ?: @"iOS",
            @"os_version": device.systemVersion ?: @"",
            @"system_version": device.systemVersion ?: @""
        },
        @"plugin": @{
            @"version": kAMDebugPluginVersion
        }
    };

    AMDebugLoadPreviousInterruptedStage();
    AMDebugShowStatus(self.currentMode, AMDebugBackendStateConnecting);

    dispatch_async(self.queue, ^{
        self.foreground = initiallyForeground;
        self.backendState = AMDebugBackendStateConnecting;
        self.helloMetadata = metadata;

        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.timeoutIntervalForRequest = 8.0;
        configuration.timeoutIntervalForResource = 30.0;
        configuration.HTTPMaximumConnectionsPerHost = 2;
        configuration.waitsForConnectivity = NO;
        self.URLSession = [NSURLSession sessionWithConfiguration:configuration];

        [self installApplicationObservers];
        if (self.foreground) {
            [self startTimers];
            [self sendHelloForce:YES];
            [self pollCommands];
            [self flushEvents];
        }
    });
}

- (void)installApplicationObservers {
    __weak typeof(self) weakSelf = self;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    id background = [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                                        object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
        AMDebugTransport *strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(strongSelf.queue, ^{
            [strongSelf flushEvents];
            strongSelf.foreground = NO;
            [strongSelf stopTimers];
        });
    }];
    id foreground = [center addObserverForName:UIApplicationWillEnterForegroundNotification
                                        object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
        AMDebugTransport *strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(strongSelf.queue, ^{
            strongSelf.foreground = YES;
            strongSelf.nextEventAttempt = 0;
            [strongSelf startTimers];
            [strongSelf sendHelloForce:YES];
            [strongSelf pollCommands];
            [strongSelf flushEvents];
        });
    }];
    id active = [center addObserverForName:UIApplicationDidBecomeActiveNotification
                                    object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
        AMDebugTransport *strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(strongSelf.queue, ^{
            strongSelf.foreground = YES;
            strongSelf.nextHelloAttempt = 0;
            [strongSelf startTimers];
            [strongSelf sendHelloForce:YES];
            [strongSelf pollCommands];
            [strongSelf flushEvents];
        });
    }];
    self.notificationTokens = @[background, foreground, active];
}

- (void)startTimers {
    if (!self.flushTimer) {
        __weak typeof(self) weakSelf = self;
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                  NSEC_PER_SEC, NSEC_PER_SEC / 5);
        dispatch_source_set_event_handler(timer, ^{
            [weakSelf flushEvents];
            [weakSelf sendHelloForce:NO];
        });
        dispatch_resume(timer);
        self.flushTimer = timer;
    }
    if (!self.pollTimer) {
        __weak typeof(self) weakSelf = self;
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                  2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
        dispatch_source_set_event_handler(timer, ^{ [weakSelf pollCommands]; });
        dispatch_resume(timer);
        self.pollTimer = timer;
    }
}

- (void)stopTimers {
    if (self.flushTimer) {
        dispatch_source_cancel(self.flushTimer);
        self.flushTimer = nil;
    }
    if (self.pollTimer) {
        dispatch_source_cancel(self.pollTimer);
        self.pollTimer = nil;
    }
}

- (void)emitEvent:(NSString *)name fields:(NSDictionary<NSString *,id> *)fields {
    if (!self.enabled || !name.length) return;
    NSString *eventName = [name copy];
    NSDictionary *fieldSnapshot = [fields copy] ?: @{};
    dispatch_async(self.queue, ^{
        NSDictionary *safeFields = AMDebugJSONValue(fieldSnapshot, 0);
        [self appendEvent:eventName fields:safeFields];
        if (self.pendingEvents.count >= kAMDebugEventBatchSize) [self flushEvents];
    });
}

- (void)appendEvent:(NSString *)name fields:(NSDictionary *)fields {
    if (self.pendingEvents.count >= kAMDebugMaxBufferedEvents) {
        [self.pendingEvents removeObjectAtIndex:0];
    }
    self.sequence += 1;
    NSMutableDictionary *event = [@{
        @"session": self.sessionIdentifier,
        @"seq": @(self.sequence),
        @"time_ms": AMDebugNowMilliseconds(),
        @"uptime": @(NSProcessInfo.processInfo.systemUptime),
        @"type": name,
        @"mode": self.mode ?: AMDebugExportModeObserve,
        @"fields": fields ?: @{}
    } mutableCopy];
    if (self.activeTransactionIdentifier.length) {
        event[@"transaction"] = self.activeTransactionIdentifier;
    }
    [self.pendingEvents addObject:event];
}

- (void)flush {
    if (!self.enabled) return;
    dispatch_async(self.queue, ^{
        [self sendHelloForce:NO];
        [self flushEvents];
    });
}

- (NSString *)beginExportTransaction:(NSDictionary<NSString *,id> *)fields {
    return [self beginExportTransaction:@"export" fields:fields];
}

- (NSString *)beginExportTransaction:(NSString *)name
                               fields:(NSDictionary<NSString *,id> *)fields {
    NSString *identifier = NSUUID.UUID.UUIDString.lowercaseString;
    if (!self.enabled) return identifier;
    NSDictionary *safeFields = AMDebugJSONValue(fields ?: @{}, 0);
    [self performSync:^{
        self.activeTransactionIdentifier = identifier;
        BOOL capture = self.captureNextPending;
        self.captureNextPending = NO;
        if (capture) [self.capturedTransactions addObject:identifier];
        NSMutableDictionary *eventFields = [safeFields mutableCopy];
        eventFields[@"name"] = name.length ? name : @"export";
        eventFields[@"capture_artifacts"] = @(capture);
        [self appendEvent:@"export.begin" fields:eventFields];
    }];
    return identifier;
}

- (void)endExportTransaction:(NSString *)transactionIdentifier
                       fields:(NSDictionary<NSString *,id> *)fields {
    if (!transactionIdentifier.length) return;
    NSDictionary *fieldSnapshot = [fields copy] ?: @{};
    dispatch_async(self.queue, ^{
        NSDictionary *safeFields = AMDebugJSONValue(fieldSnapshot, 0);
        BOOL captured = [self.capturedTransactions containsObject:transactionIdentifier];
        NSMutableDictionary *eventFields = [safeFields mutableCopy];
        eventFields[@"capture_artifacts"] = @(captured);
        eventFields[@"transaction"] = transactionIdentifier;
        [self appendEvent:@"export.end" fields:eventFields];
        [self.capturedTransactions removeObject:transactionIdentifier];
        if ([self.activeTransactionIdentifier isEqualToString:transactionIdentifier]) {
            self.activeTransactionIdentifier = nil;
        }
        [self flushEvents];
    });
}

- (BOOL)captureArtifactsForTransaction:(NSString *)transactionIdentifier {
    if (!transactionIdentifier.length) return NO;
    __block BOOL capture = NO;
    [self performSync:^{
        capture = [self.capturedTransactions containsObject:transactionIdentifier];
    }];
    return capture;
}

- (BOOL)uploadArtifactData:(NSData *)data
                      name:(NSString *)name
                  mimeType:(NSString *)mimeType
               transaction:(NSString *)transactionIdentifier {
    if (!data || !name.length || !transactionIdentifier.length) return NO;

    __block BOOL accepted = NO;
    [self performSync:^{
        accepted = self.started && self.URLSession &&
                   [self.capturedTransactions containsObject:transactionIdentifier];
    }];
    if (!accepted) return NO;
    if (data.length > kAMDebugMaxArtifactBytes) {
        [self emitEvent:@"artifact.rejected" fields:@{
            @"reason": @"too_large", @"name": name, @"size": @(data.length)
        }];
        return NO;
    }

    NSData *body = [data copy];
    NSString *artifactName = [name copy];
    NSString *contentType = mimeType.length ? [mimeType copy] : @"application/octet-stream";
    dispatch_async(self.queue, ^{
        [self uploadArtifactBody:body name:artifactName mimeType:contentType
                     transaction:transactionIdentifier];
    });
    return YES;
}

- (NSMutableURLRequest *)requestForPath:(NSString *)path method:(NSString *)method {
    NSURL *URL = [self.baseURL URLByAppendingPathComponent:path];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.HTTPMethod = method;
    request.timeoutInterval = 8.0;
    [request setValue:@"1" forHTTPHeaderField:AMDebugTransportMarkerHeader];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", self.token]
   forHTTPHeaderField:@"Authorization"];
    [request setValue:self.sessionIdentifier forHTTPHeaderField:@"X-AMProj-Session"];
    [request setValue:[self.protocolVersion description]
   forHTTPHeaderField:@"X-AMProj-Protocol-Version"];
    [NSURLProtocol setProperty:@YES forKey:kAMDebugRequestProperty inRequest:request];
    return request;
}

- (void)sendHelloForce:(BOOL)force {
    if (!self.started || !self.foreground || self.helloInFlight) return;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (!force && now < self.nextHelloAttempt) return;

    NSMutableDictionary *payload = [@{
        @"protocol_version": self.protocolVersion,
        @"session": self.sessionIdentifier,
        @"mode": self.mode,
        @"time_ms": AMDebugNowMilliseconds()
    } mutableCopy];
    [payload addEntriesFromDictionary:self.helloMetadata ?: @{}];
    NSError *JSONError;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&JSONError];
    if (!body || JSONError) return;

    NSMutableURLRequest *request = [self requestForPath:@"api/v1/hello" method:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = body;
    self.helloInFlight = YES;
    __weak typeof(self) weakSelf = self;
    [[self.URLSession dataTaskWithRequest:request completionHandler:^(__unused NSData *data,
                                                                      NSURLResponse *response,
                                                                      NSError *error) {
        dispatch_async(weakSelf.queue, ^{
            AMDebugTransport *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.helloInFlight = NO;
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            strongSelf.helloDelivered = !error && status >= 200 && status < 300;
            AMDebugBackendState nextState = strongSelf.helloDelivered
                ? AMDebugBackendStateConnected : AMDebugBackendStateUnavailable;
            AMDebugBackendState previousState = strongSelf.backendState;
            strongSelf.backendState = nextState;
            [strongSelf appendEvent:@"transport.hello" fields:@{
                @"connected": @(strongSelf.helloDelivered),
                @"status": @(status),
                @"error": error ? AMDebugJSONValue(error, 0) : NSNull.null,
                @"base_url": strongSelf.baseURL.absoluteString ?: @""
            }];
            if (previousState != nextState) {
                AMDebugShowStatus(strongSelf.mode, nextState);
            }
            NSTimeInterval delay = strongSelf.helloDelivered ?
                kAMDebugHelloInterval : kAMDebugHelloRetryInterval;
            strongSelf.nextHelloAttempt = NSProcessInfo.processInfo.systemUptime + delay;
            if (strongSelf.helloDelivered) [strongSelf flushEvents];
        });
    }] resume];
}

- (void)flushEvents {
    if (!self.started || !self.URLSession || self.eventsInFlight || !self.pendingEvents.count) return;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now < self.nextEventAttempt) return;

    NSUInteger countLimit = self.eventBatchCountLimit ?: kAMDebugEventBatchSize;
    NSUInteger count = MIN(self.pendingEvents.count, MIN(countLimit, kAMDebugEventBatchSize));
    NSArray *batch = nil;
    NSData *body = nil;
    while (count >= 1) {
        batch = [self.pendingEvents subarrayWithRange:NSMakeRange(0, count)];
        body = [self eventBodyForBatch:batch];
        if (body.length && body.length <= kAMDebugMaxEventPayloadBytes) break;
        if (count == 1) {
            NSDictionary *rejected = batch.firstObject;
            [self.pendingEvents removeObjectAtIndex:0];
            [self appendRejectedEventSummary:rejected
                                      reason:body ? @"payload_too_large" : @"serialization_failed"
                                encodedBytes:body.length
                                  HTTPStatus:0];
            dispatch_async(self.queue, ^{ [self flushEvents]; });
            return;
        }
        count = MAX((NSUInteger)1, count / 2);
    }
    if (!batch.count || !body.length) {
        return;
    }
    [self.pendingEvents removeObjectsInRange:NSMakeRange(0, batch.count)];

    NSMutableURLRequest *request = [self requestForPath:@"api/v1/events" method:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = body;
    self.eventsInFlight = YES;
    __weak typeof(self) weakSelf = self;
    [[self.URLSession dataTaskWithRequest:request completionHandler:^(__unused NSData *data,
                                                                      NSURLResponse *response,
                                                                      NSError *error) {
        dispatch_async(weakSelf.queue, ^{
            AMDebugTransport *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.eventsInFlight = NO;
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            BOOL success = !error && status >= 200 && status < 300;
            if (success) {
                strongSelf.eventRetryDelay = 1.0;
                strongSelf.nextEventAttempt = 0;
                if (strongSelf.pendingEvents.count) [strongSelf flushEvents];
            } else if (status == 413) {
                strongSelf.eventRetryDelay = 1.0;
                strongSelf.nextEventAttempt = 0;
                if (batch.count > 1) {
                    NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, batch.count)];
                    [strongSelf.pendingEvents insertObjects:batch atIndexes:indexes];
                    while (strongSelf.pendingEvents.count > kAMDebugMaxBufferedEvents) {
                        [strongSelf.pendingEvents removeLastObject];
                    }
                    strongSelf.eventBatchCountLimit = MAX((NSUInteger)1, batch.count / 2);
                } else {
                    [strongSelf appendRejectedEventSummary:batch.firstObject
                                                    reason:@"http_413"
                                              encodedBytes:body.length
                                                HTTPStatus:status];
                }
                dispatch_async(strongSelf.queue, ^{ [strongSelf flushEvents]; });
            } else {
                NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, batch.count)];
                [strongSelf.pendingEvents insertObjects:batch atIndexes:indexes];
                while (strongSelf.pendingEvents.count > kAMDebugMaxBufferedEvents) {
                    [strongSelf.pendingEvents removeLastObject];
                }
                strongSelf.nextEventAttempt = NSProcessInfo.processInfo.systemUptime + strongSelf.eventRetryDelay;
                strongSelf.eventRetryDelay = MIN(strongSelf.eventRetryDelay * 2.0, 30.0);
            }
        });
    }] resume];
}

- (NSData *)eventBodyForBatch:(NSArray<NSDictionary *> *)batch {
    if (!batch.count) return nil;
    NSDictionary *payload = @{
        @"protocol_version": self.protocolVersion,
        @"session": self.sessionIdentifier,
        @"events": batch
    };
    return [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
}

- (void)appendRejectedEventSummary:(NSDictionary *)event
                             reason:(NSString *)reason
                       encodedBytes:(NSUInteger)encodedBytes
                         HTTPStatus:(NSInteger)HTTPStatus {
    NSString *type = [event[@"type"] isKindOfClass:NSString.class] ? event[@"type"] : @"unknown";
    if ([type isEqualToString:@"event.rejected"]) return;
    NSMutableDictionary *fields = [@{
        @"reason": reason ?: @"rejected",
        @"rejected_type": type,
        @"encoded_bytes": @(encodedBytes)
    } mutableCopy];
    id sequence = event[@"seq"];
    if (sequence) fields[@"rejected_seq"] = sequence;
    if (HTTPStatus > 0) fields[@"http_status"] = @(HTTPStatus);
    [self appendEvent:@"event.rejected" fields:fields];
}

- (void)pollCommands {
    if (!self.started || !self.foreground || !self.URLSession || self.pollInFlight) return;

    NSMutableURLRequest *request = [self requestForPath:@"api/v1/commands" method:@"GET"];
    NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    NSMutableArray<NSURLQueryItem *> *query = [NSMutableArray arrayWithObject:
        [NSURLQueryItem queryItemWithName:@"session" value:self.sessionIdentifier]];
    if (self.commandCursor.length) {
        [query addObject:[NSURLQueryItem queryItemWithName:@"after" value:self.commandCursor]];
    }
    components.queryItems = query;
    request.URL = components.URL;
    self.pollInFlight = YES;

    __weak typeof(self) weakSelf = self;
    [[self.URLSession dataTaskWithRequest:request completionHandler:^(NSData *data,
                                                                      NSURLResponse *response,
                                                                      NSError *error) {
        dispatch_async(weakSelf.queue, ^{
            AMDebugTransport *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.pollInFlight = NO;
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            if (error || status < 200 || status >= 300 || !data.length) return;
            id JSON = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSDictionary *responseJSON = [JSON isKindOfClass:NSDictionary.class] ? JSON : nil;
            NSArray *commands = [JSON isKindOfClass:NSArray.class] ? JSON :
                ([responseJSON[@"commands"] isKindOfClass:NSArray.class] ? responseJSON[@"commands"] : @[]);
            NSString *cursor = nil;
            if (responseJSON) {
                id cursorValue = responseJSON[@"next_cursor"] ?: responseJSON[@"cursor"];
                if (cursorValue && cursorValue != NSNull.null) cursor = [cursorValue description];
            }
            NSMutableArray *acknowledged = [NSMutableArray array];
            for (id object in commands) {
                if (![object isKindOfClass:NSDictionary.class]) continue;
                NSDictionary *command = object;
                [strongSelf applyCommand:command];
                id identifier = command[@"id"];
                if (identifier && identifier != NSNull.null) {
                    [acknowledged addObject:AMDebugJSONValue(identifier, 0)];
                    if (!cursor.length) cursor = [identifier description];
                }
            }
            if (cursor.length) strongSelf.commandCursor = cursor;
            if (acknowledged.count) [strongSelf acknowledgeCommands:acknowledged];
        });
    }] resume];
}

- (void)applyCommand:(NSDictionary *)command {
    NSString *kind = nil;
    for (NSString *key in @[@"type", @"command", @"action"]) {
        if ([command[key] isKindOfClass:NSString.class]) {
            kind = [command[key] lowercaseString];
            break;
        }
    }
    NSDictionary *arguments = [command[@"arguments"] isKindOfClass:NSDictionary.class]
        ? command[@"arguments"] : ([command[@"payload"] isKindOfClass:NSDictionary.class]
                                    ? command[@"payload"] : @{});
    if ([kind isEqualToString:@"set_mode"] || [kind isEqualToString:@"set_export_mode"]) {
        NSString *mode = [command[@"mode"] isKindOfClass:NSString.class]
            ? [command[@"mode"] lowercaseString] :
            ([arguments[@"mode"] isKindOfClass:NSString.class] ? [arguments[@"mode"] lowercaseString] : nil);
        if (AMDebugValidMode(mode)) {
            NSString *previous = self.mode;
            self.mode = mode;
            [self appendEvent:@"control.mode_changed" fields:@{
                @"previous": previous ?: @"", @"mode": mode
            }];
            if (![previous isEqualToString:mode]) {
                AMDebugShowStatus(mode, self.backendState);
            }
        }
    } else if ([kind isEqualToString:@"capture_next"]) {
        id enabled = command[@"enabled"] ?: arguments[@"enabled"];
        BOOL armed = [enabled respondsToSelector:@selector(boolValue)] ? [enabled boolValue] : YES;
        self.captureNextPending = armed;
        [self appendEvent:@"control.capture_next" fields:@{ @"armed": @(armed) }];
    } else if ([kind isEqualToString:@"flush"]) {
        [self appendEvent:@"control.flush" fields:@{}];
        [self flushEvents];
    } else if (kind.length) {
        [self appendEvent:@"control.unknown" fields:@{ @"command": kind }];
    }
}

- (void)acknowledgeCommands:(NSArray *)identifiers {
    NSDictionary *payload = @{
        @"session": self.sessionIdentifier,
        @"acknowledged": identifiers
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!body) return;
    NSMutableURLRequest *request = [self requestForPath:@"api/v1/commands" method:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = body;
    [[self.URLSession dataTaskWithRequest:request] resume];
}

- (void)uploadArtifactBody:(NSData *)body
                      name:(NSString *)name
                  mimeType:(NSString *)mimeType
               transaction:(NSString *)transactionIdentifier {
    NSMutableURLRequest *request = [self requestForPath:@"api/v1/artifacts" method:@"POST"];
    request.timeoutInterval = 45.0;
    NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data;
    [request setValue:[nameData base64EncodedStringWithOptions:0]
   forHTTPHeaderField:@"X-AMProj-Artifact-Name-B64"];
    [request setValue:transactionIdentifier forHTTPHeaderField:@"X-AMProj-Transaction"];
    [request setValue:[NSString stringWithFormat:@"%lu", (unsigned long)body.length]
   forHTTPHeaderField:@"X-AMProj-Artifact-Size"];
    NSString *safeType = ([mimeType rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound)
        ? mimeType : @"application/octet-stream";
    [request setValue:safeType forHTTPHeaderField:@"Content-Type"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionUploadTask *task = [self.URLSession uploadTaskWithRequest:request
                                                                 fromData:body
                                                        completionHandler:^(__unused NSData *data,
                                                                            NSURLResponse *response,
                                                                            NSError *error) {
        dispatch_async(weakSelf.queue, ^{
            AMDebugTransport *strongSelf = weakSelf;
            if (!strongSelf) return;
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            BOOL success = !error && status >= 200 && status < 300;
            [strongSelf appendEvent:success ? @"artifact.uploaded" : @"artifact.failed"
                             fields:@{
                @"name": name,
                @"size": @(body.length),
                @"transaction": transactionIdentifier,
                @"status": @(status),
                @"error": error ? AMDebugJSONValue(error, 0) : NSNull.null
            }];
            [strongSelf flushEvents];
        });
    }];
    [task resume];
}

- (BOOL)isInternalURL:(NSURL *)URL {
    if (!URL || !self.baseURL) return NO;
    NSURL *base = self.baseURL;
    if (![URL.scheme.lowercaseString isEqualToString:base.scheme.lowercaseString] ||
        ![URL.host.lowercaseString isEqualToString:base.host.lowercaseString]) return NO;
    NSNumber *URLPort = URL.port ?: ([URL.scheme.lowercaseString isEqualToString:@"https"] ? @443 : @80);
    NSNumber *basePort = base.port ?: ([base.scheme.lowercaseString isEqualToString:@"https"] ? @443 : @80);
    if (![URLPort isEqualToNumber:basePort]) return NO;
    NSString *basePath = base.path.length ? base.path : @"/";
    if ([basePath isEqualToString:@"/"]) return YES;
    if ([URL.path isEqualToString:basePath]) return YES;
    NSString *prefix = [basePath hasSuffix:@"/"] ? basePath : [basePath stringByAppendingString:@"/"];
    return [URL.path hasPrefix:prefix];
}

@end

BOOL AMDebugTransportIsInternalRequest(NSURLRequest *request) {
    if (!request) return NO;
    if ([[request valueForHTTPHeaderField:AMDebugTransportMarkerHeader] isEqualToString:@"1"]) return YES;
    if ([[NSURLProtocol propertyForKey:kAMDebugRequestProperty inRequest:request] boolValue]) return YES;
    return [[AMDebugTransport shared] isInternalURL:request.URL];
}
