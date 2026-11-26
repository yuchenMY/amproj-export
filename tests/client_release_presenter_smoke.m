// Execute the production routing function against UIKit's relevant container contracts.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "AMClientReleasePolicy.h"
#include <assert.h>
#include <stdio.h>
enum { UISceneActivationStateForegroundActive = 0, UIWindowLevelNormal = 0 };
@class UIWindow;
@interface UIView : NSObject
@property(nonatomic,weak) UIWindow *window;
@property(nonatomic,weak) UIView *superview;
@property(nonatomic,strong) NSArray<UIView *> *subviews;
@property(nonatomic,strong) NSObject *nextResponder;
@property(nonatomic) BOOL hidden;
@property(nonatomic) double alpha;
@property(nonatomic) CGRect bounds;
@property(nonatomic) CGPoint testOrigin;
- (BOOL)isDescendantOfView:(UIView *)parent;
- (CGPoint)convertPoint:(CGPoint)point toView:(UIView *)view;
@end
@implementation UIView
- (instancetype)init { if((self=[super init])){_alpha=1;_bounds=CGRectMake(0,0,390,600);_subviews=@[];}return self; }
- (BOOL)isDescendantOfView:(UIView *)parent { for(UIView *v=self;v;v=v.superview)if(v==parent)return YES;return NO; }
- (CGPoint)convertPoint:(CGPoint)point toView:(UIView *)view {
    (void)view;for(UIView *v=self;v;v=v.superview){point.x+=v.testOrigin.x;point.y+=v.testOrigin.y;}return point;
}
@end
@interface UIViewController : NSObject
@property(nonatomic,strong) UIViewController *presentedViewController;
@property(nonatomic,strong) NSArray<UIViewController *> *childViewControllers;
@property(nonatomic,strong) UIView *viewIfLoaded;
@property(nonatomic,weak) UIViewController *parentViewController;
@end
@implementation UIViewController
- (instancetype)init {if((self=[super init])){_childViewControllers=@[];_viewIfLoaded=[UIView new];}return self;}
@end
@interface NodeHostingControllerWithCustomStatusbarContent : UIViewController @end
@implementation NodeHostingControllerWithCustomStatusbarContent @end
@interface _TtGC7SwiftUI14_UIHostingViewV8Homepage8HomeView_ : UIView @end
@implementation _TtGC7SwiftUI14_UIHostingViewV8Homepage8HomeView_ @end
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
@interface AMHomeUIController : UIViewController @end
@implementation AMHomeUIController @end
@interface UIScene : NSObject
@property(nonatomic) NSInteger activationState;
@end
@implementation UIScene @end
@interface UIWindow : UIView
@property(nonatomic) BOOL isKeyWindow;
@property(nonatomic) double windowLevel;
@property(nonatomic,strong) UIViewController *rootViewController;
@property(nonatomic,strong) UIView *testHit;
@property(nonatomic,strong) UIView *testOverlay;
@property(nonatomic) BOOL coverLower;
@property(nonatomic) BOOL nativeTabBar;
- (UIView *)hitTest:(CGPoint)point withEvent:(id)event;
@end
@implementation UIWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(id)event {
    (void)event;
    if(self.testOverlay && (!self.coverLower || point.y>400))return self.testOverlay;
    if(self.nativeTabBar && point.y>=730)return self;
    return self.testHit;
}
@end
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
    for(UIViewController *c in @[nav,main,tabs,home])c.viewIfLoaded.window=window;
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
    // Actual 865 shape: a generic SwiftUI root contains MainNC as a normal child.
    NodeHostingControllerWithCustomStatusbarContent *root=[NodeHostingControllerWithCustomStatusbarContent new];
    root.viewIfLoaded.window=window;root.childViewControllers=@[nav];window.rootViewController=root;main.embedTBC=tabs;
    assert(AMReleaseTopController()==home && AMReleaseControllerIsBrowsing(home));
    NodeHostingControllerWithCustomStatusbarContent *host=[NodeHostingControllerWithCustomStatusbarContent new];
    host.viewIfLoaded.window=window;tabs.selectedViewController=host;
    UIView *native=[_TtGC7SwiftUI14_UIHostingViewV8Homepage8HomeView_ new];native.window=window;
    host.viewIfLoaded.subviews=@[native];native.superview=host.viewIfLoaded;window.testHit=native;
    assert(AMReleaseTopController()==host && AMReleaseControllerIsBrowsing(host));
    // Captured 865 geometry: body starts at y103, height727, tab bar covers y730..844.
    native.testOrigin=CGPointMake(0,103);native.bounds=CGRectMake(0,0,390,727);window.nativeTabBar=YES;
    assert(AMReleaseControllerIsBrowsing(host));
    native.testOrigin=CGPointZero;native.bounds=CGRectMake(0,0,390,600);window.nativeTabBar=NO;
    native.hidden=YES;assert(!AMReleaseControllerIsBrowsing(host));native.hidden=NO;
    native.alpha=0;assert(!AMReleaseControllerIsBrowsing(host));native.alpha=1;
    window.testOverlay=[UIView new];window.coverLower=YES;
    assert(!AMReleaseControllerIsBrowsing(host));window.testOverlay=nil;
    // A modal belonging to a visible child must veto the generic root, even if home is behind it.
    UIViewController *child=[UIViewController new];child.viewIfLoaded.window=window;host.childViewControllers=@[child];
    child.presentedViewController=share;assert(!AMReleaseControllerIsBrowsing(host));child.presentedViewController=nil;
    host.childViewControllers=@[editor];editor.viewIfLoaded.window=window;
    assert(!AMReleaseControllerIsBrowsing(host));
    editor.viewIfLoaded.hidden=YES;assert(AMReleaseControllerIsBrowsing(host));editor.viewIfLoaded.hidden=NO;
    editor.viewIfLoaded.alpha=0;assert(AMReleaseControllerIsBrowsing(host));editor.viewIfLoaded.alpha=1;
    editor.viewIfLoaded.window=nil;
    assert(AMReleaseControllerIsBrowsing(host));
    host.viewIfLoaded.subviews=@[];assert(!AMReleaseControllerIsBrowsing(host));
    host.childViewControllers=@[];host.parentViewController=tabs;tabs.parentViewController=main;
    AMHomeUIController *customHome=[AMHomeUIController new];customHome.viewIfLoaded.window=window;
    customHome.viewIfLoaded.nextResponder=customHome;
    main.childViewControllers=@[tabs,customHome];main.viewIfLoaded.subviews=@[tabs.viewIfLoaded,customHome.viewIfLoaded];
    window.testHit=customHome.viewIfLoaded;
    assert(AMReleaseControllerIsBrowsing(host));
    customHome.presentedViewController=share;assert(!AMReleaseControllerIsBrowsing(host));customHome.presentedViewController=nil;
    customHome.viewIfLoaded.hidden=YES;assert(!AMReleaseControllerIsBrowsing(host));customHome.viewIfLoaded.hidden=NO;
    editor.viewIfLoaded.window=window;editor.parentViewController=main;
    assert(!AMReleaseControllerIsBrowsing(editor));
    puts("CLIENT_RELEASE_PRESENTER_PASS");
} }
