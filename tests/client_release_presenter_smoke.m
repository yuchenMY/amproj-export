// Execute the production routing function against UIKit's relevant container contracts.
#import <Foundation/Foundation.h>
#import "AMClientReleasePolicy.h"
#include <assert.h>
#include <stdio.h>
enum { UISceneActivationStateForegroundActive = 0, UIWindowLevelNormal = 0 };
@interface UIViewController : NSObject
@property(nonatomic,strong) UIViewController *presentedViewController;
@end
@implementation UIViewController @end
@interface UINavigationController : UIViewController
@property(nonatomic,strong) UIViewController *visibleViewController;
@end
@implementation UINavigationController @end
@interface UITabBarController : UIViewController
@property(nonatomic,strong) UIViewController *selectedViewController;
@end
@implementation UITabBarController @end
@interface CustomTabController : UIViewController
@property(nonatomic,strong) UIViewController *selectedViewController;
@end
@implementation CustomTabController @end
@interface MainVC : UIViewController
@property(nonatomic,strong) UIViewController *embedTBC;
@end
@implementation MainVC @end
@interface HomeVC : UIViewController @end
@implementation HomeVC @end
@interface AMProjShareVideoReplicaVC : UIViewController @end
@implementation AMProjShareVideoReplicaVC @end
@interface EditorVC : UIViewController @end
@implementation EditorVC @end
@interface UIScene : NSObject
@property(nonatomic) NSInteger activationState;
@end
@implementation UIScene @end
@interface UIWindow : NSObject
@property(nonatomic) BOOL isKeyWindow;
@property(nonatomic) double windowLevel;
@property(nonatomic,strong) UIViewController *rootViewController;
@end
@implementation UIWindow @end
@interface UIWindowScene : UIScene
@property(nonatomic,strong) NSArray *windows;
@end
@implementation UIWindowScene @end
@interface UIApplication : NSObject
@property(nonatomic,strong) NSSet *connectedScenes;
+ (instancetype)sharedApplication;
@end
@implementation UIApplication
+ (instancetype)sharedApplication { static UIApplication *app; if(!app)app=[self new];return app; }
@end
// AMPROJ_PRODUCTION_TOP_CONTROLLER
int main(void) { @autoreleasepool {
    UIWindow *window=[UIWindow new];window.isKeyWindow=YES;
    UIWindowScene *scene=[UIWindowScene new];scene.windows=@[window];
    UIApplication.sharedApplication.connectedScenes=[NSSet setWithObject:scene];
    UINavigationController *nav=[UINavigationController new];window.rootViewController=nav;
    MainVC *main=[MainVC new];nav.visibleViewController=main;
    UITabBarController *tabs=[UITabBarController new];main.embedTBC=tabs;
    HomeVC *home=[HomeVC new];tabs.selectedViewController=home;
    assert(AMReleaseTopController()==home && AMClientReleaseSafePresenter(NSStringFromClass(AMReleaseTopController().class)));
    EditorVC *editor=[EditorVC new];home.presentedViewController=editor;
    assert(AMReleaseTopController()==editor && !AMClientReleaseSafePresenter(NSStringFromClass(AMReleaseTopController().class)));
    AMProjShareVideoReplicaVC *share=[AMProjShareVideoReplicaVC new];editor.presentedViewController=share;
    assert(AMReleaseTopController()==share && !AMClientReleaseSafePresenter(NSStringFromClass(AMReleaseTopController().class)));
    home.presentedViewController=nil;
    CustomTabController *custom=[CustomTabController new];main.embedTBC=custom;custom.selectedViewController=home;
    assert(AMReleaseTopController()==home);
    custom.presentedViewController=share;
    assert(AMReleaseTopController()==share && !AMClientReleaseSafePresenter(NSStringFromClass(AMReleaseTopController().class)));
    main.embedTBC=[UIViewController new];
    assert(AMReleaseTopController()==main && !AMClientReleaseSafePresenter(NSStringFromClass(main.class)));
    puts("CLIENT_RELEASE_PRESENTER_PASS");
} }
