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
    BOOL association = [NSProcessInfo.processInfo.arguments containsObject:@"--association"];
    [self setStage:association ? 0 : (busy ? 1 : 2) title:association ? @"关联此设备" : (busy ? @"准备更新" : @"确认安装")];
    [self.action setTitle:association ? @"完成登记，继续更新" : (busy ? @"重试更新" : @"继续安装") forState:UIControlStateNormal];
    [self setBusy:busy message:busy ? @"正在为此设备签名并校验安装包，请稍候…" : @"安装包已准备好，请点“继续安装”，在安装页确认系统安装。安装完成后即可打开新版本。"];
    if (association) {
        [self setBusy:NO message:@"请先在下方完成一次设备登记，再点“完成登记，继续更新”。"];
        self.webHost.hidden = NO;
        self.web = [[WKWebView alloc] initWithFrame:self.webHost.bounds]; self.web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.webHost addSubview:self.web];
    }
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
        CGFloat titleWidth = controller.action.bounds.size.width - controller.action.contentEdgeInsets.left - controller.action.contentEdgeInsets.right;
        CGFloat titleHeight = [controller.action.titleLabel sizeThatFits:CGSizeMake(titleWidth, CGFLOAT_MAX)].height;
        NSDictionary *report = @{
            @"lightAppearance":@(controller.traitCollection.userInterfaceStyle == UIUserInterfaceStyleLight),
            @"buttonHeight":@(controller.action.bounds.size.height),
            @"messageNotClipped":@(controller.status.bounds.size.height + 1 >= needed.height),
            @"buttonTextNotClipped":@(controller.action.bounds.size.height + 1 >= titleHeight + controller.action.contentEdgeInsets.top + controller.action.contentEdgeInsets.bottom),
            @"noHorizontalOverflow":@(scroll.contentSize.width <= scroll.bounds.size.width + 1),
            @"steps":@(controller.stepNames.count),
            @"associationHidden":@(controller.webHost.hidden),
            @"associationHeight":@(controller.webHost.bounds.size.height),
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
