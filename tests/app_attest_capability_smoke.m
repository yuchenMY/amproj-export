// 猫鹤 AM · 真实 ObjC 能力检测调用、特定异常与安装边界回归。
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#include <assert.h>
#include <string.h>
#include <stdatomic.h>
#include <stdio.h>
static BOOL supportedRuntime;
static BOOL amproj_runtimeIsBuild865(void) { return supportedRuntime; }
static Class lookupClass;
static Class testClassLookup(NSString *name) {
    assert([name isEqualToString:@"DCAppAttestService"]);
    return lookupClass;
}
#define NSClassFromString testClassLookup
static _Atomic unsigned int calls, notes;
static NSInteger mode;
static void AMProjCrashNote(NSString *format, ...) { (void)format; atomic_fetch_add(&notes, 1); }
@interface DCDeviceMetadataDaemonConnection : NSObject @end
@implementation DCDeviceMetadataDaemonConnection @end
@interface CapabilityBase : NSObject
- (BOOL)isSupported;
- (void)generateKeyWithCompletionHandler:(void (^)(NSString *, NSError *))completion;
@end
@implementation CapabilityBase
- (BOOL)isSupported {
    atomic_fetch_add(&calls, 1);
    if (mode == 2) {
        id connection = [DCDeviceMetadataDaemonConnection new];
        return ((BOOL (*)(id, SEL))objc_msgSend)(connection, NSSelectorFromString(@"appAttestType"));
    }
    if (mode == 3) [NSException raise:NSRangeException format:@"unrelated framework exception"];
    if (mode == 4) [NSException raise:NSInvalidArgumentException
        format:@"-[OtherConnection appAttestType]: unrecognized selector sent to instance 0x1234"];
    if (mode == 5) [NSException raise:NSInvalidArgumentException
        format:@"-[DCDeviceMetadataDaemonConnection otherMethod]: unrecognized selector sent to instance 0x1234"];
    return mode == 1;
}
- (void)generateKeyWithCompletionHandler:(void (^)(NSString *, NSError *))completion {
    completion(nil, [NSError errorWithDomain:@"fixture" code:17 userInfo:nil]);
}
@end
@interface DCAppAttestService : CapabilityBase @end
@implementation DCAppAttestService @end
@interface WrongSignature : NSObject
- (id)isSupported;
@end
@implementation WrongSignature
- (id)isSupported { return @YES; }
@end
// AMPROJ_PRODUCTION_ATTEST_GUARD
int main(void) {
    @autoreleasepool {
        SEL selector = NSSelectorFromString(@"isSupported");
        IMP original = class_getMethodImplementation(CapabilityBase.class, selector);
        lookupClass = DCAppAttestService.class;
        amproj_installAppAttestCapabilityGuard();
        assert(class_getMethodImplementation(lookupClass, selector) == original);
        supportedRuntime = YES; lookupClass = Nil;
        amproj_installAppAttestCapabilityGuard(); assert(!amproj_originalAppAttestIsSupported);
        lookupClass = NSObject.class; amproj_installAppAttestCapabilityGuard();
        assert(!amproj_originalAppAttestIsSupported);
        lookupClass = WrongSignature.class; amproj_installAppAttestCapabilityGuard();
        assert(!amproj_originalAppAttestIsSupported);
        lookupClass = DCAppAttestService.class;
        dispatch_apply(100, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t index) {
            @autoreleasepool { (void)index; amproj_installAppAttestCapabilityGuard(); }
        });
        assert(class_getMethodImplementation(lookupClass, selector) != original);
        assert(class_getMethodImplementation(CapabilityBase.class, selector) == original);
        DCAppAttestService *service = [DCAppAttestService new];
        mode = 1; assert(service.isSupported);
        mode = 0; assert(!service.isSupported);
        mode = 2; assert(!service.isSupported && atomic_load(&notes) == 1);
        for (mode = 3; mode <= 5; mode++) {
            BOOL propagated = NO;
            @try { (void)service.isSupported; }
            @catch (NSException *exception) {
                propagated = YES;
                assert([exception.name isEqualToString:mode == 3 ? NSRangeException : NSInvalidArgumentException]);
            }
            assert(propagated);
        }
        assert(atomic_load(&notes) == 1 && atomic_load(&calls) == 6);
        __block BOOL completionCalled = NO;
        [service generateKeyWithCompletionHandler:^(NSString *key, NSError *error) {
            assert(!key && error.code == 17); completionCalled = YES;
        }]; assert(completionCalled);
        mode = 1;
        dispatch_apply(100, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t index) {
            @autoreleasepool {
                (void)index; amproj_installAppAttestCapabilityGuard(); assert(service.isSupported);
            }
        });
        assert(atomic_load(&calls) == 106 && atomic_load(&notes) == 1);
        assert(class_getMethodImplementation(CapabilityBase.class, selector) == original);
        puts("APP_ATTEST_CAPABILITY_GUARD_PASS");
    }
}
