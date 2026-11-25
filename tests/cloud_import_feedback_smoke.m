// 猫鹤 AM · 云导入结果排队，覆盖重复文件、后台、弹窗与转场。
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <assert.h>
#include <stdio.h>

typedef NS_ENUM(NSInteger, UIApplicationState) { UIApplicationStateActive, UIApplicationStateBackground };
enum { UIAlertControllerStyleAlert, UIAlertActionStyleDefault };
@interface UIApplication : NSObject
@property(nonatomic) UIApplicationState applicationState;
+ (instancetype)sharedApplication;
@end
@implementation UIApplication
+ (instancetype)sharedApplication { static UIApplication *app; if (!app) app = [self new]; return app; }
@end
@interface UIView : NSObject
@property(nonatomic, strong) NSObject *window;
@end
@implementation UIView @end
@interface UIViewController : NSObject
@property(nonatomic, strong) UIView *viewIfLoaded;
@property(nonatomic, strong) UIViewController *presentedViewController;
@property(nonatomic, weak) UIViewController *presentingViewController;
@property(nonatomic, strong) UIViewController *parentViewController;
@property(nonatomic, strong) NSObject *transitionCoordinator;
@property(nonatomic) BOOL isBeingPresented;
@property(nonatomic) BOOL isBeingDismissed;
@property(nonatomic) NSUInteger presentations;
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(dispatch_block_t)completion;
@end
@implementation UIViewController
- (void)presentViewController:(UIViewController *)controller animated:(BOOL)animated completion:(dispatch_block_t)completion {
    assert(!self.presentedViewController);
    self.presentations++;
    self.presentedViewController = controller;
    controller.presentingViewController = self;
    controller.viewIfLoaded = self.viewIfLoaded;
    if (completion) completion();
}
@end
@interface UIDocumentPickerViewController : UIViewController @end
@implementation UIDocumentPickerViewController @end
@interface UIAlertAction : NSObject
@property(nonatomic, copy) void (^handler)(UIAlertAction *);
+ (instancetype)actionWithTitle:(NSString *)title style:(NSInteger)style handler:(void (^)(UIAlertAction *))handler;
@end
@implementation UIAlertAction
+ (instancetype)actionWithTitle:(NSString *)title style:(NSInteger)style handler:(void (^)(UIAlertAction *))handler {
    UIAlertAction *action = [self new]; action.handler = handler; return action;
}
@end
@interface UIAlertController : UIViewController
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *message;
@property(nonatomic, strong) UIAlertAction *action;
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(NSInteger)style;
- (void)addAction:(UIAlertAction *)action;
@end
@implementation UIAlertController
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(NSInteger)style {
    UIAlertController *alert = [self new]; alert.title = title; alert.message = message; return alert;
}
- (void)addAction:(UIAlertAction *)action { self.action = action; }
@end
static NSMutableArray *jobs;
static UIViewController *currentTop;
static NSUInteger diagnostics;
static UIViewController *AMCloudTopController(UIViewController *base) {
    return currentTop.presentedViewController ?: currentTop;
}
static void AMCloudDiagnostic(NSString *event, NSDictionary *fields) {
    assert([event isEqualToString:@"cloud.import_result_presented"]);
    assert([fields[@"result"] length] > 0);
    diagnostics++;
}
static void schedule(dispatch_block_t block) { [jobs addObject:[block copy]]; }
static void runOne(void) {
    assert(jobs.count > 0);
    dispatch_block_t block = jobs.firstObject;
    [jobs removeObjectAtIndex:0];
    block();
}
static void AMCloudAfterAlertAction(dispatch_block_t block) { schedule(block); }
#define dispatch_after(time, queue, block) schedule(block)
@interface AMCloudManager : NSObject
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *importResultNotices;
@property(nonatomic) BOOL importResultRetryScheduled;
@property(nonatomic) NSUInteger refreshes;
@property(nonatomic, weak) UIAlertController *ownedAlert;
- (void)enqueueImportResultTitle:(NSString *)title message:(NSString *)message;
- (void)showNextImportResult;
- (void)refreshWindowCloudOverlayVisibility;
- (void)rememberCloudLibraryAlert:(UIAlertController *)alert;
@end
@implementation AMCloudManager
- (void)refreshWindowCloudOverlayVisibility { self.refreshes++; }
- (void)rememberCloudLibraryAlert:(UIAlertController *)alert { self.ownedAlert = alert; }
// AMPROJ_PRODUCTION_FEEDBACK_METHODS
@end
static UIViewController *visibleController(Class cls) {
    UIViewController *controller = [cls new];
    controller.viewIfLoaded = [UIView new];
    controller.viewIfLoaded.window = [NSObject new];
    return controller;
}
static void acknowledge(UIViewController *host) {
    UIAlertController *alert = (id)host.presentedViewController;
    assert([alert isKindOfClass:UIAlertController.class]);
    host.presentedViewController = nil;
    alert.presentingViewController = nil;
    alert.action.handler(alert.action);
}
int main(void) {
    @autoreleasepool {
        for (NSUInteger state = 0; state < 11; state++) {
            jobs = [NSMutableArray array];
            AMCloudManager *manager = [AMCloudManager new];
            UIApplication.sharedApplication.applicationState = UIApplicationStateActive;
            currentTop = visibleController(UIViewController.class);
            if (state == 0) currentTop = nil;
            if (state == 1) currentTop = visibleController(UIAlertController.class);
            if (state == 2) currentTop = visibleController(UIDocumentPickerViewController.class);
            if (state == 3) currentTop.isBeingPresented = YES;
            if (state == 4) currentTop.isBeingDismissed = YES;
            if (state == 5) UIApplication.sharedApplication.applicationState = UIApplicationStateBackground;
            if (state == 6) currentTop.viewIfLoaded.window = nil;
            if (state == 7) currentTop.transitionCoordinator = [NSObject new];
            if (state == 8 || state == 9) {
                currentTop.parentViewController = visibleController(UIViewController.class);
                if (state == 8) currentTop.parentViewController.isBeingPresented = YES;
                if (state == 9) currentTop.parentViewController.transitionCoordinator = [NSObject new];
            }
            UIViewController *presenting;
            if (state == 10) {
                presenting = visibleController(UIViewController.class);
                presenting.isBeingDismissed = YES;
                currentTop.presentingViewController = presenting;
            }
            [manager enqueueImportResultTitle:@"文件已存在" message:@"未重复创建"];
            assert(manager.importResultNotices.count == 1 && jobs.count == 1);
            assert(currentTop.presentations == 0 && manager.refreshes == 0);
            [manager showNextImportResult];
            assert(jobs.count == 1);
            currentTop = visibleController(UIViewController.class);
            UIApplication.sharedApplication.applicationState = UIApplicationStateActive;
            runOne();
            UIAlertController *shown = (id)currentTop.presentedViewController;
            assert([shown.title isEqualToString:@"文件已存在"]);
            assert([shown.message isEqualToString:@"未重复创建"]);
            assert(manager.ownedAlert == shown && manager.refreshes == 1);
            assert(manager.importResultNotices.count == 0 && currentTop.presentations == 1);
            acknowledge(currentTop); runOne();
            assert(currentTop.presentations == 1 && jobs.count == 0);
        }
        jobs = [NSMutableArray array];
        AMCloudManager *manager = [AMCloudManager new];
        currentTop = nil;
        [manager enqueueImportResultTitle:@"导入完成" message:@"first"];
        [manager enqueueImportResultTitle:@"文件已存在" message:@"second"];
        assert(jobs.count == 1 && manager.importResultNotices.count == 2);
        currentTop = visibleController(UIViewController.class);
        runOne();
        assert([((UIAlertController *)currentTop.presentedViewController).message isEqualToString:@"first"]);
        acknowledge(currentTop); runOne();
        assert([((UIAlertController *)currentTop.presentedViewController).message isEqualToString:@"second"]);
        acknowledge(currentTop); runOne();
        assert(currentTop.presentations == 2 && manager.importResultNotices.count == 0);
        assert(jobs.count == 0 && diagnostics == 13);
        puts("CLOUD_IMPORT_FEEDBACK_PASS");
    }
}
