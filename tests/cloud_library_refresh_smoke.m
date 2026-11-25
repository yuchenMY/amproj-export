// 猫鹤 AM · 执行生产云列表缓存刷新与登录代际回归。
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
#include <math.h>
typedef NSRect CGRect;
#define CGRectGetWidth NSWidth
typedef double CFTimeInterval;
static CFTimeInterval now = 100;
static CFTimeInterval CACurrentMediaTime(void) { return now; }
static uint64_t authGeneration = 1;
static NSString *authToken = @"account-a";
static void AMCloudReadAuthContext(NSString **token, uint64_t *generation, id unused) {
    (void)unused;
    if (token) *token = authToken;
    if (generation) *generation = authGeneration;
}
static BOOL AMCloudAuthMatches(NSString *token, uint64_t generation) {
    return generation == authGeneration && [token isEqualToString:authToken];
}
@interface StubView : NSObject
@property(nonatomic) CGRect bounds;
@property(nonatomic) BOOL hidden;
@property(nonatomic, copy) NSString *text;
@property(nonatomic) NSUInteger updates;
- (void)endRefreshing;
- (void)reloadData;
- (void)layoutSubviews;
@end
@implementation StubView
- (void)endRefreshing { self.updates++; }
- (void)reloadData { self.updates++; }
- (void)layoutSubviews {}
@end
@interface StubConstraint : NSObject
@property(nonatomic) double constant;
@end
@implementation StubConstraint @end
@interface StubClient : NSObject
@property(nonatomic) NSUInteger requests;
@property(nonatomic, copy) void (^completion)(NSDictionary *, NSError *);
- (void)loadProjects:(void (^)(NSDictionary *, NSError *))completion;
@end
@implementation StubClient
- (void)loadProjects:(void (^)(NSDictionary *, NSError *))completion {
    self.requests++; self.completion = completion;
}
@end
@interface AMCloudManager : NSObject
@property(nonatomic, strong) StubClient *client;
@end
@implementation AMCloudManager @end
@interface AMCloudLibraryView : StubView
@property(nonatomic, weak) AMCloudManager *manager;
@property(nonatomic) BOOL loading;
@property(nonatomic) BOOL contentLoaded;
@property(nonatomic) CFTimeInterval lastSuccessfulLoad;
@property(nonatomic, strong) NSArray *projects;
@property(nonatomic, strong) NSDictionary *usage;
@property(nonatomic, strong) StubView *refreshControl;
@property(nonatomic, strong) StubView *tableView;
@property(nonatomic, strong) StubView *stateLabel;
@property(nonatomic, strong) StubView *quotaCaptionLabel;
@property(nonatomic, strong) StubConstraint *quotaBarFillWidth;
@property(nonatomic) NSUInteger applied;
- (void)reload;
- (void)refreshForPresentation;
- (void)applyUsage;
@end
@implementation AMCloudLibraryView
// AMPROJ_PRODUCTION_LIBRARY_REFRESH
// AMPROJ_PRODUCTION_LIBRARY_LAYOUT
- (void)applyUsage { self.applied++; }
@end
int main(void) {
    @autoreleasepool {
        AMCloudManager *manager = [AMCloudManager new]; manager.client = [StubClient new];
        AMCloudLibraryView *view = [AMCloudLibraryView new]; view.manager = manager;
        view.refreshControl = [StubView new]; view.tableView = [StubView new];
        view.stateLabel = [StubView new]; view.quotaCaptionLabel = [StubView new];
        view.quotaBarFillWidth = [StubConstraint new];
        NSDictionary *payload = @{@"projects": @[@{@"title": @"a"}], @"usage": @{@"quotaBytes": @100, @"usedBytes": @25}};
        NSError *failure = [NSError errorWithDomain:@"test" code:1 userInfo:nil];
        [view refreshForPresentation]; [view refreshForPresentation];
        assert(manager.client.requests == 1 && view.loading);
        manager.client.completion(payload, nil);
        assert(view.contentLoaded && !view.loading && view.applied == 1);
        assert(view.projects.count == 1 && view.tableView.updates == 1);
        [view layoutSubviews]; assert(view.quotaBarFillWidth.constant == 0);
        view.bounds = NSMakeRect(0, 0, 390, 450); [view layoutSubviews];
        assert(fabs(view.quotaBarFillWidth.constant - 81.5) < 0.01);
        assert(manager.client.requests == 1);
        now = 129; [view refreshForPresentation]; assert(manager.client.requests == 1);
        now = 130; [view refreshForPresentation]; assert(manager.client.requests == 2);
        manager.client.completion(nil, failure);
        assert(view.projects.count == 1 && view.applied == 1);
        [view reload]; assert(manager.client.requests == 3);
        authGeneration++; authToken = @"account-b";
        manager.client.completion(@{@"projects": @[], @"usage": @{}}, nil);
        assert(view.projects.count == 1 && view.applied == 1);
        view.contentLoaded = NO; view.projects = @[];
        [view reload]; manager.client.completion(nil, failure);
        assert(!view.contentLoaded && view.applied == 1 && !view.tableView.hidden);
        assert([view.stateLabel.text containsString:@"失败"]);
        [view reload]; manager.client.completion(payload, nil);
        assert(view.contentLoaded && view.applied == 2 && view.projects.count == 1);
        puts("CLOUD_LIBRARY_REFRESH_PASS");
    }
}
