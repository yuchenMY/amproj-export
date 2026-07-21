#import "AMDebugTransport.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import <arpa/inet.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <math.h>
#import <net/if.h>
#import <poll.h>
#import <stdio.h>
#import <stdlib.h>
#import <sys/socket.h>
#import <unistd.h>

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
static const NSTimeInterval kAMDebugDiscoveryRetryInterval = 15.0;
static const NSTimeInterval kAMDebugDiscoveryTimeout = 1.5;
static const NSUInteger kAMDebugDiscoveryMaxPacketBytes = 512;
static const NSUInteger kAMDebugDiscoveryMaxSubnetHosts = 1024;
static NSString *const kAMDebugPluginVersion = @"29";
static void *kAMDebugQueueKey = &kAMDebugQueueKey;

static BOOL AMDebugPrivateIPv4(uint32_t address) {
    return (address & 0xff000000U) == 0x0a000000U ||
        (address & 0xfff00000U) == 0xac100000U ||
        (address & 0xffff0000U) == 0xc0a80000U ||
        (address & 0xffff0000U) == 0xa9fe0000U;
}

static NSString *AMDebugHexNonce(void) {
    uint8_t bytes[16];
    arc4random_buf(bytes, sizeof(bytes));
    char output[sizeof(bytes) * 2 + 1];
    for (NSUInteger index = 0; index < sizeof(bytes); index++) {
        snprintf(output + index * 2, 3, "%02x", bytes[index]);
    }
    output[sizeof(bytes) * 2] = '\0';
    return [NSString stringWithUTF8String:output];
}

static NSString *AMDebugDiscoveryProof(NSString *token, NSString *message) {
    NSData *key = [token dataUsingEncoding:NSUTF8StringEncoding];
    NSData *body = [message dataUsingEncoding:NSASCIIStringEncoding];
    if (!key.length || !body.length) return nil;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, body.bytes, body.length, digest);
    NSData *data = [NSData dataWithBytes:digest length:sizeof(digest)];
    NSString *encoded = [data base64EncodedStringWithOptions:0];
    encoded = [encoded stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    encoded = [encoded stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [encoded stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"="]];
}

static BOOL AMDebugDiscoveryInterface(struct ifaddrs *interface) {
    if (!interface || !interface->ifa_addr || interface->ifa_addr->sa_family != AF_INET) return NO;
    unsigned int flags = interface->ifa_flags;
    if (!(flags & IFF_UP) || (flags & IFF_LOOPBACK)) return NO;
    NSString *name = [NSString stringWithUTF8String:interface->ifa_name ?: ""];
    if (!name.length || [name hasPrefix:@"utun"] || [name hasPrefix:@"pdp_ip"] ||
        [name hasPrefix:@"awdl"] || [name hasPrefix:@"llw"]) return NO;
    uint32_t address = ntohl(((struct sockaddr_in *)interface->ifa_addr)->sin_addr.s_addr);
    return AMDebugPrivateIPv4(address);
}

static NSURL *AMDebugDiscoverEndpointSync(NSString *token, NSUInteger discoveryPort) {
    if (!token.length || discoveryPort < 1 || discoveryPort > UINT16_MAX) return nil;
    NSString *nonce = AMDebugHexNonce();
    NSString *message = [NSString stringWithFormat:@"discover:1:%@", nonce];
    NSString *proof = AMDebugDiscoveryProof(token, message);
    NSDictionary *probe = @{
        @"type": @"amproj-discover",
        @"version": @1,
        @"nonce": nonce,
        @"proof": proof ?: @""
    };
    NSData *probeData = [NSJSONSerialization dataWithJSONObject:probe options:0 error:nil];
    if (!probeData.length || probeData.length > kAMDebugDiscoveryMaxPacketBytes) return nil;

    int descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (descriptor < 0) return nil;
    int descriptorFlags = fcntl(descriptor, F_GETFL, 0);
    if (descriptorFlags >= 0) fcntl(descriptor, F_SETFL, descriptorFlags | O_NONBLOCK);

    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0 || !interfaces) {
        close(descriptor);
        return nil;
    }

    BOOL sent = NO;
    for (NSUInteger preferredPass = 0; preferredPass < 2 && !sent; preferredPass++) {
        for (struct ifaddrs *item = interfaces; item; item = item->ifa_next) {
            if (!AMDebugDiscoveryInterface(item) || !item->ifa_netmask) continue;
            NSString *name = [NSString stringWithUTF8String:item->ifa_name ?: ""];
            BOOL isWiFi = [name isEqualToString:@"en0"];
            if ((preferredPass == 0) != isWiFi) continue;

            uint32_t address = ntohl(((struct sockaddr_in *)item->ifa_addr)->sin_addr.s_addr);
            uint32_t mask = ntohl(((struct sockaddr_in *)item->ifa_netmask)->sin_addr.s_addr);
            struct sockaddr_in local = {0};
            local.sin_len = sizeof(local);
            local.sin_family = AF_INET;
            local.sin_port = 0;
            local.sin_addr = ((struct sockaddr_in *)item->ifa_addr)->sin_addr;
            if (bind(descriptor, (const struct sockaddr *)&local, sizeof(local)) != 0) continue;
            uint64_t hostCount = (uint64_t)(~mask) + 1;
            if (hostCount > kAMDebugDiscoveryMaxSubnetHosts) mask = 0xffffff00U;
            uint32_t network = address & mask;
            uint32_t broadcast = network | ~mask;
            if (broadcast <= network + 1) continue;

            for (NSUInteger round = 0; round < 2; round++) {
                for (uint32_t host = network + 1; host < broadcast; host++) {
                    if (host == address) continue;
                    struct sockaddr_in target = {0};
                    target.sin_len = sizeof(target);
                    target.sin_family = AF_INET;
                    target.sin_port = htons((uint16_t)discoveryPort);
                    target.sin_addr.s_addr = htonl(host);
                    ssize_t written = sendto(descriptor, probeData.bytes, probeData.length, 0,
                        (const struct sockaddr *)&target, sizeof(target));
                    if (written < 0 && (errno == EAGAIN || errno == ENOBUFS)) {
                        struct pollfd writable = { .fd = descriptor, .events = POLLOUT, .revents = 0 };
                        if (poll(&writable, 1, 2) > 0) {
                            written = sendto(descriptor, probeData.bytes, probeData.length, 0,
                                (const struct sockaddr *)&target, sizeof(target));
                        }
                    }
                    if (written == (ssize_t)probeData.length) sent = YES;
                }
            }
            break;
        }
    }
    freeifaddrs(interfaces);
    if (!sent) {
        close(descriptor);
        return nil;
    }

    CFTimeInterval deadline = CACurrentMediaTime() + kAMDebugDiscoveryTimeout;
    NSURL *result = nil;
    while (!result) {
        CFTimeInterval remaining = deadline - CACurrentMediaTime();
        if (remaining <= 0) break;
        struct pollfd pollDescriptor = { .fd = descriptor, .events = POLLIN, .revents = 0 };
        int milliseconds = (int)ceil(remaining * 1000.0);
        int pollResult = poll(&pollDescriptor, 1, milliseconds);
        if (pollResult <= 0) break;

        uint8_t responseBytes[kAMDebugDiscoveryMaxPacketBytes + 1];
        struct sockaddr_in source = {0};
        socklen_t sourceLength = sizeof(source);
        ssize_t length = recvfrom(descriptor, responseBytes, sizeof(responseBytes), 0,
                                  (struct sockaddr *)&source, &sourceLength);
        if (length <= 0 || length > (ssize_t)kAMDebugDiscoveryMaxPacketBytes ||
            source.sin_family != AF_INET) continue;
        uint32_t sourceAddress = ntohl(source.sin_addr.s_addr);
        if (!AMDebugPrivateIPv4(sourceAddress)) continue;

        NSData *responseData = [NSData dataWithBytes:responseBytes length:(NSUInteger)length];
        NSDictionary *response = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
        if (![response isKindOfClass:NSDictionary.class] ||
            ![response[@"type"] isEqual:@"amproj-offer"] ||
            ![response[@"version"] isEqual:@1] ||
            ![response[@"nonce"] isEqual:nonce] ||
            ![response[@"port"] isKindOfClass:NSNumber.class] ||
            ![response[@"proof"] isKindOfClass:NSString.class]) continue;
        NSInteger HTTPPort = [response[@"port"] integerValue];
        if (HTTPPort < 1 || HTTPPort > UINT16_MAX) continue;
        NSString *offerMessage = [NSString stringWithFormat:@"offer:1:%@:%ld",
                                  nonce, (long)HTTPPort];
        NSString *expectedProof = AMDebugDiscoveryProof(token, offerMessage);
        if (![expectedProof isEqualToString:response[@"proof"]]) continue;

        char sourceText[INET_ADDRSTRLEN];
        if (!inet_ntop(AF_INET, &source.sin_addr, sourceText, sizeof(sourceText))) continue;
        NSURLComponents *components = NSURLComponents.new;
        components.scheme = @"http";
        components.host = [NSString stringWithUTF8String:sourceText];
        components.port = @(HTTPPort);
        result = components.URL;
    }
    close(descriptor);
    return result;
}

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
@property(nonatomic, strong, nullable) NSURLSessionDataTask *helloTask;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *pendingEvents;
@property(nonatomic, strong) NSMutableSet<NSString *> *capturedTransactions;
@property(nonatomic, strong) NSArray *notificationTokens;
@property(nonatomic, strong) id protocolVersion;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, copy) NSString *mode;
@property(nonatomic, copy) NSString *buildIdentifier;
@property(nonatomic, copy, nullable) NSString *activeTransactionIdentifier;
@property(nonatomic, copy, nullable) NSString *commandCursor;
@property(nonatomic, strong) NSDictionary *helloMetadata;
@property(nonatomic, readwrite, getter=isEnabled) BOOL enabled;
@property(nonatomic, copy, readwrite) NSString *sessionIdentifier;
@property(atomic, copy, readwrite, nullable) NSURL *baseURL;
@property(nonatomic, copy, nullable) NSURL *configuredBaseURL;
@property(nonatomic) uint64_t sequence;
@property(nonatomic) NSUInteger endpointGeneration;
@property(nonatomic) NSUInteger discoveryPort;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL foreground;
@property(nonatomic) BOOL eventsInFlight;
@property(nonatomic) BOOL helloInFlight;
@property(nonatomic) BOOL helloDelivered;
@property(nonatomic) BOOL pollInFlight;
@property(nonatomic) BOOL discoveryEnabled;
@property(nonatomic) BOOL discoveryInFlight;
@property(nonatomic) BOOL captureNextPending;
@property(nonatomic) AMDebugBackendState backendState;
@property(nonatomic) NSTimeInterval eventRetryDelay;
@property(nonatomic) NSTimeInterval nextEventAttempt;
@property(nonatomic) NSTimeInterval nextHelloAttempt;
@property(nonatomic) NSTimeInterval nextDiscoveryAttempt;
@property(nonatomic) NSUInteger eventBatchCountLimit;

- (instancetype)initPrivate;
- (void)performSync:(dispatch_block_t)block;
- (void)installApplicationObservers;
- (void)startTimers;
- (void)stopTimers;
- (void)appendEvent:(NSString *)name fields:(NSDictionary *)fields;
- (NSMutableURLRequest *)requestForPath:(NSString *)path method:(NSString *)method;
- (void)sendHelloForce:(BOOL)force;
- (void)startDiscoveryIfNeeded;
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
    NSNumber *configuredDiscoveryPort = [config[@"DiscoveryPort"] isKindOfClass:NSNumber.class]
        ? config[@"DiscoveryPort"] : nil;
    NSNumber *configuredDiscoveryEnabled = [config[@"DiscoveryEnabled"] isKindOfClass:NSNumber.class]
        ? config[@"DiscoveryEnabled"] : nil;
    NSString *defaultMode = [config[@"DefaultMode"] isKindOfClass:NSString.class]
        ? [config[@"DefaultMode"] lowercaseString] : nil;
    NSString *buildIdentifier = [config[@"BuildIdentifier"] isKindOfClass:NSString.class]
        ? config[@"BuildIdentifier"] : nil;
    NSURL *baseURL = baseString.length ? [NSURL URLWithString:baseString] : nil;
    NSString *scheme = baseURL.scheme.lowercaseString;

    if (AMDebugValidMode(defaultMode)) _mode = [defaultMode copy];
    _buildIdentifier = buildIdentifier.length ? [buildIdentifier copy] : @"v29-debug";
    NSCharacterSet *newlines = NSCharacterSet.newlineCharacterSet;
    BOOL safeToken = token.length && [token rangeOfCharacterFromSet:newlines].location == NSNotFound;
    BOOL validProtocolVersion = [protocolVersion isKindOfClass:NSNumber.class] ||
        ([protocolVersion isKindOfClass:NSString.class] && [protocolVersion length]);
    if (([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) &&
        baseURL.host.length && safeToken && validProtocolVersion) {
        _baseURL = [baseURL copy];
        _configuredBaseURL = [baseURL copy];
        _token = [token copy];
        _protocolVersion = AMDebugJSONValue(protocolVersion, 0);
        NSInteger discoveryPort = configuredDiscoveryPort.integerValue;
        if (discoveryPort < 1 || discoveryPort > UINT16_MAX) {
            discoveryPort = baseURL.port.integerValue ?: 8765;
        }
        _discoveryPort = (NSUInteger)discoveryPort;
        _discoveryEnabled = configuredDiscoveryEnabled ? configuredDiscoveryEnabled.boolValue : YES;
        _endpointGeneration = 1;
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
            @"version": kAMDebugPluginVersion,
            @"variant": @"debug",
            @"build_id": self.buildIdentifier ?: @"v29-debug"
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
            strongSelf.nextDiscoveryAttempt = 0;
            [strongSelf startTimers];
            [strongSelf sendHelloForce:YES];
        });
    }];
    id active = [center addObserverForName:UIApplicationDidBecomeActiveNotification
                                    object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
        AMDebugTransport *strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(strongSelf.queue, ^{
            strongSelf.foreground = YES;
            strongSelf.nextHelloAttempt = 0;
            strongSelf.nextDiscoveryAttempt = 0;
            [strongSelf startTimers];
            [strongSelf sendHelloForce:YES];
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
            [weakSelf startDiscoveryIfNeeded];
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
    NSUInteger generation = self.endpointGeneration;
    NSURL *requestBaseURL = [self.baseURL copy];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.URLSession dataTaskWithRequest:request
        completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(weakSelf.queue, ^{
            AMDebugTransport *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (generation != strongSelf.endpointGeneration) return;
            strongSelf.helloInFlight = NO;
            strongSelf.helloTask = nil;
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
                @"base_url": requestBaseURL.absoluteString ?: @""
            }];
            if (previousState != nextState) {
                AMDebugShowStatus(strongSelf.mode, nextState);
            }
            NSTimeInterval delay = strongSelf.helloDelivered ?
                kAMDebugHelloInterval : kAMDebugHelloRetryInterval;
            strongSelf.nextHelloAttempt = NSProcessInfo.processInfo.systemUptime + delay;
            if (strongSelf.helloDelivered) {
                [strongSelf flushEvents];
                [strongSelf pollCommands];
            } else {
                [strongSelf startDiscoveryIfNeeded];
            }
        });
    }];
    self.helloTask = task;
    [task resume];
}

- (void)startDiscoveryIfNeeded {
    if (!self.started || !self.foreground || !self.discoveryEnabled ||
        self.helloDelivered || self.discoveryInFlight) return;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now < self.nextDiscoveryAttempt) return;
    self.discoveryInFlight = YES;
    self.nextDiscoveryAttempt = now + kAMDebugDiscoveryRetryInterval;

    NSString *token = [self.token copy];
    NSUInteger discoveryPort = self.discoveryPort;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSURL *discoveredURL = AMDebugDiscoverEndpointSync(token, discoveryPort);
        dispatch_async(weakSelf.queue, ^{
            AMDebugTransport *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.discoveryInFlight = NO;
            if (!strongSelf.started || !strongSelf.foreground || strongSelf.helloDelivered) return;
            if (!discoveredURL) {
                [strongSelf appendEvent:@"transport.discovery" fields:@{
                    @"found": @NO,
                    @"port": @(discoveryPort)
                }];
                return;
            }

            BOOL changed = ![strongSelf.baseURL.absoluteString
                isEqualToString:discoveredURL.absoluteString];
            if (changed) {
                strongSelf.endpointGeneration += 1;
                [strongSelf.helloTask cancel];
                strongSelf.helloTask = nil;
                strongSelf.helloInFlight = NO;
                strongSelf.helloDelivered = NO;
                strongSelf.baseURL = discoveredURL;
                strongSelf.commandCursor = nil;
                strongSelf.nextHelloAttempt = 0;
                strongSelf.nextEventAttempt = 0;
                strongSelf.backendState = AMDebugBackendStateConnecting;
                [strongSelf appendEvent:@"transport.discovery" fields:@{
                    @"found": @YES,
                    @"configured_base_url": strongSelf.configuredBaseURL.absoluteString ?: @"",
                    @"discovered_base_url": discoveredURL.absoluteString ?: @""
                }];
                AMDebugShowStatus(strongSelf.mode, AMDebugBackendStateConnecting);
            }
            [strongSelf sendHelloForce:YES];
        });
    });
}

- (void)flushEvents {
    if (!self.started || !self.helloDelivered || !self.URLSession ||
        self.eventsInFlight || !self.pendingEvents.count) return;
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
    NSUInteger generation = self.endpointGeneration;
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
            if (generation != strongSelf.endpointGeneration) {
                if (!success) {
                    NSIndexSet *indexes = [NSIndexSet indexSetWithIndexesInRange:
                        NSMakeRange(0, batch.count)];
                    [strongSelf.pendingEvents insertObjects:batch atIndexes:indexes];
                    while (strongSelf.pendingEvents.count > kAMDebugMaxBufferedEvents) {
                        [strongSelf.pendingEvents removeLastObject];
                    }
                }
                strongSelf.nextEventAttempt = 0;
                if (strongSelf.helloDelivered && strongSelf.pendingEvents.count) {
                    [strongSelf flushEvents];
                }
                return;
            }
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
    if (!self.started || !self.foreground || !self.helloDelivered ||
        !self.URLSession || self.pollInFlight) return;

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
    NSUInteger generation = self.endpointGeneration;

    __weak typeof(self) weakSelf = self;
    [[self.URLSession dataTaskWithRequest:request completionHandler:^(NSData *data,
                                                                      NSURLResponse *response,
                                                                      NSError *error) {
        dispatch_async(weakSelf.queue, ^{
            AMDebugTransport *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.pollInFlight = NO;
            if (generation != strongSelf.endpointGeneration) {
                [strongSelf pollCommands];
                return;
            }
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

    NSUInteger generation = self.endpointGeneration;
    NSURL *requestBaseURL = [self.baseURL copy];
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
            BOOL staleEndpoint = generation != strongSelf.endpointGeneration;
            NSString *eventName = staleEndpoint ? @"artifact.stale_endpoint" :
                (success ? @"artifact.uploaded" : @"artifact.failed");
            [strongSelf appendEvent:eventName
                             fields:@{
                @"name": name,
                @"size": @(body.length),
                @"transaction": transactionIdentifier,
                @"status": @(status),
                @"delivered": @(success),
                @"request_base_url": requestBaseURL.absoluteString ?: @"",
                @"current_base_url": strongSelf.baseURL.absoluteString ?: @"",
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
