// 猫鹤 AM · 执行生产宿主选择函数的响应链回归。
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
typedef NSRect CGRect;
#define CGRectGetHeight NSHeight
#define CGRectGetMaxY NSMaxY
#define NSStringFromCGRect NSStringFromRect
@interface UIResponder : NSObject
@property(nonatomic, weak) UIResponder *nextResponder;
@end
@implementation UIResponder
@end
@class UIWindow;
@interface UIView : UIResponder
@property(nonatomic) CGRect bounds;
@property(nonatomic) CGRect frame;
@property(nonatomic, weak) UIView *superview;
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic) BOOL hidden;
@property(nonatomic) double alpha;
@property(nonatomic) BOOL userInteractionEnabled;
@property(nonatomic, strong) NSArray<UIView *> *subviews;
- (BOOL)isDescendantOfView:(UIView *)view;
- (CGRect)convertRect:(CGRect)rect toView:(UIView *)view;
@end
@implementation UIView
- (instancetype)init {
    if ((self = [super init])) { _alpha = 1; _subviews = @[]; }
    return self;
}
- (BOOL)isDescendantOfView:(UIView *)view {
    for (UIView *current = self; current; current = current.superview)
        if (current == view) return YES;
    return NO;
}
- (CGRect)convertRect:(CGRect)rect toView:(UIView *)view {
    (void)rect; (void)view; return self.frame;
}
@end
@interface UIWindow : UIView @end
@implementation UIWindow @end
@interface HomepageSelectionHeaderView : UIView @end
@implementation HomepageSelectionHeaderView @end
@interface OtherSelectionHeaderView : UIView @end
@implementation OtherSelectionHeaderView @end
@interface UIViewController : UIResponder
@property(nonatomic, strong) UIView *viewIfLoaded;
@end
@implementation UIViewController @end
@interface UINavigationController : UIViewController @end
@implementation UINavigationController @end
@interface UITabBarController : UIViewController @end
@implementation UITabBarController @end
@interface ProjectsVC : UIViewController @end
@implementation ProjectsVC @end
@interface NodeHostingController : UIViewController @end
@implementation NodeHostingController @end
static BOOL supported865 = YES;
static BOOL AMProjV865ProjectFlowIsRuntimeSupported(void) { return supported865; }
static BOOL AMCloudIsProjectsControllerClass(Class cls) {
    return [NSStringFromClass(cls) hasSuffix:@"ProjectsVC"];
}
// AMPROJ_PRODUCTION_CLOUD_HOST
// AMPROJ_PRODUCTION_PROBE_TREE

int main(void) {
    @autoreleasepool {
        UIView *content = [UIView new];
        content.bounds = NSMakeRect(0, 0, 390, 800);
        HomepageSelectionHeaderView *header = [HomepageSelectionHeaderView new];
        header.bounds = NSMakeRect(0, 0, 390, 48);
        header.frame = NSMakeRect(0, 220, 390, 48);
        header.superview = content;
        for (Class cls in @[ProjectsVC.class, NodeHostingController.class]) {
            UIViewController *owner = [cls new]; owner.viewIfLoaded = content;
            header.nextResponder = owner;
            assert(AMCloudContentHostForHeader(header) == owner);
        }
        NodeHostingController *node = [NodeHostingController new]; node.viewIfLoaded = content;
        header.nextResponder = node;
        supported865 = NO;
        assert(AMCloudContentHostForHeader(header) == nil);
        supported865 = YES;
        OtherSelectionHeaderView *other = [OtherSelectionHeaderView new];
        other.superview = content; other.nextResponder = node;
        assert(AMCloudContentHostForHeader(other) == nil);
        header.superview = nil;
        assert(AMCloudContentHostForHeader(header) == nil);
        header.superview = content;
        content.bounds = NSMakeRect(0, 0, 390, 400);
        assert(AMCloudContentHostForHeader(header) == nil);
        content.bounds = NSMakeRect(0, 0, 390, 800);
        for (Class cls in @[UIViewController.class, UINavigationController.class,
                             UITabBarController.class]) {
            UIViewController *owner = [cls new]; owner.viewIfLoaded = content;
            header.nextResponder = owner;
            assert(AMCloudContentHostForHeader(header) == nil);
        }
        puts("CLOUD_CONTAINMENT_PASS");
#ifdef AMPROJ_PROBE_TREE_TEST
        UIWindow *window = [UIWindow new];
        window.window = window;
        NSMutableArray *children = [NSMutableArray array];
        for (int i = 0; i < 250; i++) [children addObject:[UIView new]];
        HomepageSelectionHeaderView *candidate = [HomepageSelectionHeaderView new];
        children[0] = candidate;
        window.subviews = children;
        NSMutableArray *nodes = [NSMutableArray array];
        assert(AMCloudProbeTree(window, window, 0, nodes) == candidate);
        assert(nodes.count == 180);
        children[0] = [UIView new]; children[249] = candidate;
        [nodes removeAllObjects];
        assert(AMCloudProbeTree(window, window, 0, nodes) == nil);
        assert(nodes.count == 180);
        UIView *hidden = [UIView new]; hidden.hidden = YES;
        hidden.subviews = @[candidate]; window.subviews = @[hidden];
        [nodes removeAllObjects];
        assert(AMCloudProbeTree(window, window, 0, nodes) == nil);
        assert(nodes.count == 2);
        UIView *root = [UIView new], *current = root;
        for (int i = 0; i < 30; i++) {
            UIView *child = [UIView new]; current.subviews = @[child]; current = child;
        }
        [nodes removeAllObjects];
        assert(AMCloudProbeTree(root, window, 0, nodes) == nil);
        assert(nodes.count == 21);
        puts("CLOUD_PROBE_BUDGET_PASS");
#endif
    }
}
