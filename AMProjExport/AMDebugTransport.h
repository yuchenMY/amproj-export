#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NSString *AMDebugExportMode NS_TYPED_EXTENSIBLE_ENUM;

FOUNDATION_EXPORT AMDebugExportMode const AMDebugExportModeObserve;
FOUNDATION_EXPORT AMDebugExportMode const AMDebugExportModePlaceholder;
FOUNDATION_EXPORT AMDebugExportMode const AMDebugExportModeFull;

FOUNDATION_EXPORT NSString *const AMDebugTransportMarkerHeader;

@interface AMDebugTransport : NSObject

+ (instancetype)shared;
+ (instancetype)sharedTransport;

@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property(nonatomic, copy, readonly) NSString *sessionIdentifier;
@property(nonatomic, copy, readonly) AMDebugExportMode currentMode;
@property(atomic, copy, readonly, nullable) NSURL *baseURL;

// All network work is asynchronous. Calling start more than once is harmless.
- (void)start;
- (void)emitEvent:(NSString *)name
           fields:(nullable NSDictionary<NSString *, id> *)fields;
// 可从任意线程调用；仅同步等待事件序列化并进入内存队列。在 transport 队列内
// 重入时直接入队，不会再次 dispatch_sync。网络 flush 随后异步执行，属于
// best-effort 投递，不保证进程异常终止前已经到达服务端。
- (void)emitCriticalEvent:(NSString *)name
                   fields:(nullable NSDictionary<NSString *, id> *)fields;
- (void)flush;

// beginExportTransaction consumes a pending capture_next command atomically.
- (NSString *)beginExportTransaction:(nullable NSDictionary<NSString *, id> *)fields;
- (NSString *)beginExportTransaction:(NSString *)name
                               fields:(nullable NSDictionary<NSString *, id> *)fields;
- (void)endExportTransaction:(NSString *)transactionIdentifier
                       fields:(nullable NSDictionary<NSString *, id> *)fields;
- (BOOL)captureArtifactsForTransaction:(NSString *)transactionIdentifier;

// Returns YES only when the data was accepted for an authorized capture.
- (BOOL)uploadArtifactData:(NSData *)data
                      name:(NSString *)name
                  mimeType:(NSString *)mimeType
               transaction:(NSString *)transactionIdentifier;

- (BOOL)isInternalURL:(nullable NSURL *)URL;

- (instancetype)init NS_UNAVAILABLE;

@end

// Network instrumentation must call this before recording an NSURLRequest.
FOUNDATION_EXPORT BOOL AMDebugTransportIsInternalRequest(NSURLRequest *request);

NS_ASSUME_NONNULL_END
