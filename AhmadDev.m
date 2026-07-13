// AhmadDev.m — 替换已有 AhmadDev.dylib，登录绕过 + Oracle 重定向
// 不改 Mach-O 头，用现有 LC_LOAD 通道，不触发完整性校验
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ====== Part A: 登录绕过（hook FIRAuth.currentUser） ======
@interface AMFakeUser : NSObject @end
@implementation AMFakeUser
- (NSString *)uid { return @"ayakameow"; }
- (NSString *)email { return @"pro@ayakameow.cn"; }
- (BOOL)isAnonymous { return NO; }
- (BOOL)isEmailVerified { return YES; }
@end

static id (*orig_currentUser)(id, SEL);
static AMFakeUser *gFake = nil;

static id hooked_currentUser(id self, SEL _cmd) {
    id real = orig_currentUser(self, _cmd);
    return real ?: gFake;
}

static void tryHookFIRAuth(void) {
    Class c = NSClassFromString(@"FIRAuth");
    if (!c) return;
    Method m = class_getInstanceMethod(c, @selector(currentUser));
    if (!m || orig_currentUser) return;
    gFake = [AMFakeUser new];
    orig_currentUser = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)hooked_currentUser);
}

// ====== Part B: Oracle 重定向 ======
static NSURLSessionDataTask * (*orig_dataTask)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));

static NSURLSessionDataTask * hooked_dataTask(id self, SEL _cmd, NSURLRequest *req, void (^handler)(NSData *, NSURLResponse *, NSError *)) {
    NSString *host = req.URL.host;
    if ([host containsString:@"oracle.bendingspoonsapps.com"] || [host containsString:@"janus.bendingspoons.com"]) {
        NSURLComponents *c = [NSURLComponents componentsWithString:req.URL.absoluteString];
        c.scheme = @"https"; c.host = @"am.ayakameow.cn";
        if ([host containsString:@"janus.bendingspoons.com"])
            c.path = [@"/api/oracle/janus" stringByAppendingString:c.path ?: @""];
        NSMutableURLRequest *r = [req mutableCopy]; r.URL = c.URL;
        return orig_dataTask(self, _cmd, r, handler);
    }
    return orig_dataTask(self, _cmd, req, handler);
}

static void tryHookOracle(void) {
    Method m = class_getInstanceMethod([NSURLSession class], @selector(dataTaskWithRequest:completionHandler:));
    if (!m || orig_dataTask) return;
    orig_dataTask = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)hooked_dataTask);
}

// ====== 构造器 ======
__attribute__((constructor))
static void _am_init(void) {
    gFake = [AMFakeUser new];

    // Oracle hook: 延迟 1s 等 NSURLSession 初始化
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ tryHookOracle(); });

    // FIRAuth hook: 轮询等待类加载（0.5s 间隔，最多 60s）
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC, 0.1 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        tryHookFIRAuth();
        if (orig_currentUser) dispatch_source_cancel(timer);
    });
    dispatch_resume(timer);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ dispatch_source_cancel(timer); });
}
