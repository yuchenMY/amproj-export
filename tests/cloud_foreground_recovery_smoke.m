// 猫鹤 AM · 前后台保留列表、有界恢复和旧回调取消回归。
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
#include "AMCloudTabPolicy.h"
typedef NSRect CGRect;
#define CGRectZero NSZeroRect
#define CGRectIsEmpty NSIsEmptyRect
#define NSStringFromCGRect NSStringFromRect
static NSMutableArray *pending;
static void enqueue(dispatch_block_t block) { [pending addObject:[block copy]]; }
static void drain(void) {
    while (pending.count) {
        dispatch_block_t block = pending.firstObject;
        [pending removeObjectAtIndex:0]; block();
    }
}
#define dispatch_after(when, queue, ...) enqueue(__VA_ARGS__)
enum { UIApplicationStateActive, UIApplicationStateBackground };
@interface UIApplication : NSObject
@property(nonatomic) NSInteger applicationState;
+ (instancetype)sharedApplication;
@end
@implementation UIApplication
+ (instancetype)sharedApplication { static id app; if (!app) app = [self new]; return app; }
@end
@interface UIView : NSObject
@property(nonatomic, strong) UIView *superview;
@property(nonatomic) CGRect bounds;
@end
@implementation UIView @end
static BOOL allowed = YES;
static BOOL disabled;
static UIView *currentHeader;
static NSInteger selected;
static BOOL AMCloudUIKitDisabled(void) { return disabled; }
static UIView *AMCloudProjectsView(void) { return currentHeader; }
static BOOL AMCloudProjectContainerEligible(UIView *header) { return header != nil; }
static NSInteger AMCloudDetectCloudPillSelected(UIView *header, CGRect *row, CGRect *pill) {
    if (header && selected >= 0) { *row = NSMakeRect(0, 100, 390, 40); *pill = *row; }
    return selected;
}
static NSUInteger hides;
static BOOL AMCloudOverlayWorkAllowed(void) { return allowed; }
static void AMCloudHideWindowOverlayIfNeeded(void) { hides++; }
static void AMCloudDiagnostic(NSString *name, NSDictionary *data) { (void)name; (void)data; }
static void AMClientReleasePresentIfNeeded(void) {}
@interface AMCloudManager : NSObject
@property(nonatomic) NSUInteger cloudSelectionGeneration;
@property(nonatomic) NSUInteger cloudLibraryAlertSelectionGeneration;
@property(nonatomic) BOOL cloudTapTargetKnown;
@property(nonatomic) BOOL cloudForegroundRecoveryPending;
@property(nonatomic, strong) UIView *embeddedLibrary;
@property(nonatomic, strong) UIView *embeddedHeader;
@property(nonatomic, strong) UIView *cloudSubTabHost;
@property(nonatomic, strong) UIView *cloudPillHost;
@property(nonatomic) CGRect cloudSubTabFrame;
@property(nonatomic) CGRect cloudPillFrame;
@property(nonatomic) CGRect cloudPillHostBounds;
@property(nonatomic) BOOL cloudTapTargetIsCloud;
@property(nonatomic) BOOL exerciseActualRefresh;
@property(nonatomic) BOOL ownedAlert;
@property(nonatomic) BOOL recoverySucceeds;
@property(nonatomic) NSUInteger refreshes;
@property(nonatomic) NSUInteger cancellations;
- (void)startCloudOverlayWatchdog;
- (void)reconcileForegroundCloudLibrary;
- (void)applicationDidEnterBackground:(NSNotification *)notification;
- (BOOL)keepsLibraryBehindOwnedAlert;
- (void)refreshWindowCloudOverlayVisibility;
- (void)cancelPluginDownloadNotice;
- (void)actualRefreshWindowCloudOverlayVisibility;
- (void)setCloudLibraryVisible:(BOOL)visible;
- (UIView *)prepareCloudLibrary;
- (void)repairKnownCloudTabForGeneration:(NSUInteger)generation;
- (void)showPreparedCloudLibraryInProjectsView:(UIView *)header row:(CGRect)row;
@end
@implementation AMCloudManager
- (BOOL)keepsLibraryBehindOwnedAlert { return self.ownedAlert; }
- (void)refreshWindowCloudOverlayVisibility {
    self.refreshes++;
    if (self.exerciseActualRefresh) [self actualRefreshWindowCloudOverlayVisibility];
    else if (self.recoverySucceeds) self.cloudForegroundRecoveryPending = NO;
}
- (void)setCloudLibraryVisible:(BOOL)visible {
    assert(!visible);
    self.embeddedLibrary.superview = nil; self.embeddedLibrary = nil; self.embeddedHeader = nil;
}
- (UIView *)prepareCloudLibrary { return nil; }
- (void)repairKnownCloudTabForGeneration:(NSUInteger)generation { (void)generation; }
- (void)showPreparedCloudLibraryInProjectsView:(UIView *)header row:(CGRect)row {
    assert(!CGRectIsEmpty(row));
    self.embeddedLibrary = [UIView new]; self.embeddedLibrary.superview = header;
    self.embeddedHeader = header;
}
- (void)cancelPluginDownloadNotice { self.cancellations++; }
// AMPROJ_PRODUCTION_FOREGROUND_RECOVERY
// AMPROJ_PRODUCTION_FOREGROUND_REFRESH
@end
int main(void) {
    @autoreleasepool {
        pending = [NSMutableArray array];
        AMCloudManager *manager = [AMCloudManager new];
        manager.cloudSelectionGeneration = 9;
        manager.cloudLibraryAlertSelectionGeneration = 9;
        manager.embeddedLibrary = [UIView new];
        UIView *host = [UIView new]; manager.embeddedLibrary.superview = host;
        manager.cloudTapTargetKnown = YES;
        [manager startCloudOverlayWatchdog];
        assert(manager.refreshes == 1 && pending.count == 3);
        [UIApplication sharedApplication].applicationState = UIApplicationStateBackground;
        [manager applicationDidEnterBackground:nil];
        assert(manager.embeddedLibrary.superview == host);
        assert(manager.cloudSelectionGeneration == 10 && !manager.cloudTapTargetKnown);
        assert(manager.cloudLibraryAlertSelectionGeneration == 10);
        assert(!manager.cloudForegroundRecoveryPending && manager.cancellations == 1);
        drain(); assert(manager.refreshes == 1);
        [UIApplication sharedApplication].applicationState = UIApplicationStateActive;
        [manager startCloudOverlayWatchdog]; drain();
        assert(manager.refreshes == 5 && !manager.cloudForegroundRecoveryPending);
        manager.recoverySucceeds = YES;
        [manager startCloudOverlayWatchdog]; drain(); assert(manager.refreshes == 6);
        manager.recoverySucceeds = NO;
        [manager startCloudOverlayWatchdog]; manager.cloudSelectionGeneration++;
        drain(); assert(manager.refreshes == 7);
        allowed = NO;
        [manager startCloudOverlayWatchdog]; drain();
        assert(manager.refreshes == 7 && hides == 4);
        manager.ownedAlert = YES;
        [manager startCloudOverlayWatchdog]; drain();
        assert(manager.refreshes == 7 && hides == 4);
        manager.cloudLibraryAlertSelectionGeneration = 2;
        [manager applicationDidEnterBackground:nil];
        assert(manager.cloudLibraryAlertSelectionGeneration == 2);
        manager = [AMCloudManager new]; manager.exerciseActualRefresh = YES;
        currentHeader = [UIView new]; currentHeader.bounds = NSMakeRect(0, 0, 390, 844);
        manager.embeddedHeader = currentHeader;
        manager.embeddedLibrary = [UIView new]; manager.embeddedLibrary.superview = currentHeader;
        manager.cloudForegroundRecoveryPending = YES; selected = -1;
        [manager refreshWindowCloudOverlayVisibility];
        assert(manager.embeddedLibrary.superview == currentHeader);
        [UIApplication sharedApplication].applicationState = UIApplicationStateActive;
        [manager refreshWindowCloudOverlayVisibility];
        assert(manager.embeddedLibrary.superview == currentHeader);
        selected = 0; [manager refreshWindowCloudOverlayVisibility];
        assert(!manager.embeddedLibrary);
        selected = 1; [manager refreshWindowCloudOverlayVisibility];
        assert(manager.embeddedLibrary.superview == currentHeader && !manager.cloudForegroundRecoveryPending);
        manager.cloudForegroundRecoveryPending = YES; selected = -1;
        currentHeader = [UIView new]; [manager refreshWindowCloudOverlayVisibility];
        assert(!manager.embeddedLibrary);
        selected = 1; [manager refreshWindowCloudOverlayVisibility];
        assert(manager.embeddedLibrary);
        manager.cloudForegroundRecoveryPending = NO; selected = -1;
        [manager refreshWindowCloudOverlayVisibility]; assert(!manager.embeddedLibrary);
        selected = 1; [manager refreshWindowCloudOverlayVisibility]; disabled = YES;
        [manager refreshWindowCloudOverlayVisibility]; assert(!manager.embeddedLibrary);
        puts("CLOUD_FOREGROUND_RECOVERY_PASS");
    }
}
