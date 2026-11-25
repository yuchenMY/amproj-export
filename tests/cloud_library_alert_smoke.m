// 猫鹤 AM · 弹窗期间保留已挂载云内容，覆盖选页、窗口与挂载失效。
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
#include "AMCloudTabPolicy.h"
@class UIWindow;
@interface UIView : NSObject
@property(nonatomic, weak) UIView *superview;
@property(nonatomic, weak) UIWindow *window;
@end
@implementation UIView @end
@interface UIWindow : UIView @end
@implementation UIWindow @end
@interface UIAlertController : NSObject
@property(nonatomic, strong) NSObject *presentingViewController;
@property(nonatomic, strong) UIView *viewIfLoaded;
@end
@implementation UIAlertController @end
static UIWindow *activeWindow;
static UIWindow *AMCloudActiveWindow(void) { return activeWindow; }
@interface AMCloudManager : NSObject
@property(nonatomic, strong) UIView *embeddedLibrary;
@property(nonatomic, weak) UIView *embeddedHeader;
@property(nonatomic, weak) UIAlertController *cloudLibraryAlert;
@property(nonatomic) NSUInteger cloudSelectionGeneration;
@property(nonatomic) NSUInteger cloudLibraryAlertSelectionGeneration;
- (void)rememberCloudLibraryAlert:(UIAlertController *)alert;
- (BOOL)keepsLibraryBehindOwnedAlert;
@end
@implementation AMCloudManager
// AMPROJ_PRODUCTION_ALERT_METHODS
@end
int main(void) {
    @autoreleasepool {
        activeWindow = [UIWindow new];
        UIView *header = [UIView new]; header.window = activeWindow;
        AMCloudManager *manager = [AMCloudManager new];
        manager.embeddedHeader = header;
        manager.embeddedLibrary = [UIView new];
        manager.embeddedLibrary.superview = header;
        manager.cloudSelectionGeneration = 3;
        UIAlertController *alert = [UIAlertController new];
        alert.viewIfLoaded = [UIView new]; alert.viewIfLoaded.window = activeWindow;
        alert.presentingViewController = [NSObject new];
        [manager rememberCloudLibraryAlert:alert];
        assert([manager keepsLibraryBehindOwnedAlert]);
        manager.cloudSelectionGeneration++;
        assert(![manager keepsLibraryBehindOwnedAlert]);
        manager.cloudSelectionGeneration--;
        alert.presentingViewController = nil;
        assert(![manager keepsLibraryBehindOwnedAlert]);
        alert.presentingViewController = [NSObject new];
        UIWindow *other = [UIWindow new]; alert.viewIfLoaded.window = other;
        assert(![manager keepsLibraryBehindOwnedAlert]);
        alert.viewIfLoaded.window = activeWindow;
        manager.embeddedLibrary.superview = nil;
        assert(![manager keepsLibraryBehindOwnedAlert]);
        manager.embeddedLibrary.superview = header;
        manager.cloudLibraryAlert = nil;
        assert(![manager keepsLibraryBehindOwnedAlert]);
        puts("CLOUD_LIBRARY_ALERT_PASS");
    }
}
