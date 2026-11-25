// 猫鹤 AM · 执行生产标签核对调度，验证截图预算与快速切页取消。
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
#include "AMCloudTabPolicy.h"
static NSMutableArray *pending;
static void AMCloudTestEnqueue(void (^block)(void)) {
    if (!pending) pending = [NSMutableArray array];
    [pending addObject:[block copy]];
}
static void AMCloudTestDrain(void) {
    while (pending.count) {
        void (^block)(void) = pending.firstObject;
        [pending removeObjectAtIndex:0];
        block();
    }
}
#define dispatch_async(queue, ...) AMCloudTestEnqueue(__VA_ARGS__)
#define dispatch_after(when, queue, ...) AMCloudTestEnqueue(__VA_ARGS__)
@interface AMCloudManager : NSObject
@property(nonatomic) NSUInteger cloudSelectionGeneration;
@property(nonatomic) BOOL cloudTapTargetKnown;
@property(nonatomic) BOOL cloudTapTargetIsCloud;
@property(nonatomic) BOOL nativeCloudSelected;
@property(nonatomic) BOOL libraryVisible;
@property(nonatomic) NSUInteger repairs;
@property(nonatomic) NSUInteger snapshots;
- (void)repairKnownCloudTabForGeneration:(NSUInteger)generation;
- (void)refreshWindowCloudOverlayVisibility;
- (void)scheduleCloudTabReconciliationForGeneration:(NSUInteger)generation verifiedCloudTap:(BOOL)verifiedCloudTap;
@end
@implementation AMCloudManager
- (void)repairKnownCloudTabForGeneration:(NSUInteger)generation {
    if (generation == self.cloudSelectionGeneration) {
        self.repairs++;
        self.libraryVisible = self.cloudTapTargetKnown && self.cloudTapTargetIsCloud;
    }
}
- (void)refreshWindowCloudOverlayVisibility {
    assert(!self.cloudTapTargetKnown);
    self.snapshots++;
    self.libraryVisible = AMCloudTabAllowsDisplay(self.nativeCloudSelected,
        self.cloudTapTargetKnown, self.cloudTapTargetIsCloud);
}
// AMPROJ_PRODUCTION_TAP_SCHEDULE
@end
int main(void) {
    @autoreleasepool {
        AMCloudManager *manager = [AMCloudManager new];
        manager.cloudSelectionGeneration = 1; manager.cloudTapTargetKnown = YES;
        manager.cloudTapTargetIsCloud = YES;
        [manager scheduleCloudTabReconciliationForGeneration:1 verifiedCloudTap:YES];
        assert(pending.count == 2); AMCloudTestDrain();
        assert(manager.repairs == 2 && manager.snapshots == 0 && !manager.cloudTapTargetKnown);
        assert(manager.libraryVisible);
        manager.repairs = 0; manager.cloudSelectionGeneration = 2; manager.cloudTapTargetKnown = YES;
        manager.cloudTapTargetIsCloud = NO; manager.nativeCloudSelected = YES;
        manager.libraryVisible = NO;
        /* 点击行间留白，原生仍是云端：一次真实状态确认必须恢复库。 */
        [manager scheduleCloudTabReconciliationForGeneration:2 verifiedCloudTap:NO];
        assert(pending.count == 1); AMCloudTestDrain();
        assert(manager.repairs == 0 && manager.snapshots == 1 && !manager.cloudTapTargetKnown);
        assert(manager.libraryVisible);
        manager.cloudSelectionGeneration = 3; manager.cloudTapTargetKnown = YES;
        manager.nativeCloudSelected = NO;
        [manager scheduleCloudTabReconciliationForGeneration:3 verifiedCloudTap:NO]; AMCloudTestDrain();
        assert(!manager.libraryVisible);
        manager.snapshots = 0; manager.cloudSelectionGeneration = 3; manager.cloudTapTargetKnown = YES;
        [manager scheduleCloudTabReconciliationForGeneration:3 verifiedCloudTap:YES];
        [manager scheduleCloudTabReconciliationForGeneration:3 verifiedCloudTap:NO];
        manager.cloudSelectionGeneration = 4; AMCloudTestDrain();
        assert(manager.repairs == 0 && manager.snapshots == 0 && manager.cloudTapTargetKnown);
        for (NSUInteger i = 0; i < 100; i++) {
            manager.cloudSelectionGeneration++;
            manager.cloudTapTargetKnown = YES;
            [manager scheduleCloudTabReconciliationForGeneration:manager.cloudSelectionGeneration verifiedCloudTap:i % 2];
        }
        AMCloudTestDrain();
        assert(manager.repairs == 2 && manager.snapshots == 0 && !manager.cloudTapTargetKnown);
        puts("CLOUD_TAP_SCHEDULE_PASS");
    }
}
