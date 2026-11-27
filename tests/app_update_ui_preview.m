// 猫鹤 AM · 用生产控制器渲染更新页面；仅替换网络入口，不发起登记或安装。
#import <UIKit/UIKit.h>
#import "../AMProjExport/AMAppUpdate.m"

@interface AMUpdatePreviewController : AMAppUpdateController
@end
@implementation AMUpdatePreviewController
- (void)prepare { [self renderPreview]; }
- (void)showAssociation { [self renderPreview]; }
- (void)performAction {}
- (void)renderPreview {
    BOOL busy = [NSProcessInfo.processInfo.arguments containsObject:@"--busy"];
    [self setStage:busy ? 1 : 2 title:busy ? @"准备更新" : @"确认安装"];
    [self.action setTitle:busy ? @"重试更新" : @"继续安装" forState:UIControlStateNormal];
    [self setBusy:busy message:busy ? @"正在为此设备签名并校验安装包，请稍候…" : @"安装包已准备好，请点“继续安装”，在安装页确认系统安装。安装完成后即可打开新版本。"];
}
@end

@interface AMUpdatePreviewDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic) UIWindow *window;
@end
@implementation AMUpdatePreviewDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    AMUpdatePreviewController *controller = [AMUpdatePreviewController new];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    self.window.rootViewController = navigation; [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [controller.view layoutIfNeeded];
        UIScrollView *scroll = (UIScrollView *)controller.view.subviews.firstObject;
        CGSize needed = [controller.status sizeThatFits:CGSizeMake(controller.status.bounds.size.width, CGFLOAT_MAX)];
        NSDictionary *report = @{
            @"lightAppearance":@(controller.traitCollection.userInterfaceStyle == UIUserInterfaceStyleLight),
            @"buttonHeight":@(controller.action.bounds.size.height),
            @"messageNotClipped":@(controller.status.bounds.size.height + 1 >= needed.height),
            @"noHorizontalOverflow":@(scroll.contentSize.width <= scroll.bounds.size.width + 1),
            @"steps":@(controller.stepNames.count),
            @"associationHidden":@(controller.webHost.hidden),
            @"busy":@(controller.busy),
            @"buttonEnabled":@(controller.action.enabled),
            @"contentSizeCategory":controller.traitCollection.preferredContentSizeCategory
        };
        NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToURL:[documents URLByAppendingPathComponent:@"ui-report.json"] atomically:YES];
    });
    return YES;
}
@end
int main(int argc, char *argv[]) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AMUpdatePreviewDelegate.class)); } }
