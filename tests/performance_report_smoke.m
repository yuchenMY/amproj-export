// 猫鹤 AM · 实际 JSON 编码与字节预算的宿主验证。
#import "../AMProjExport/AMProjPerformanceReport.h"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        NSMutableArray *events = [NSMutableArray arrayWithObject:@{@"event": @"capture.started"}];
        NSString *large = [@"x" stringByPaddingToLength:1024 withString:@"x" startingAtIndex:0];
        for (int i = 0; i < 1024; i++) [events addObject:@{@"event": @"input.touch", @"fields": @{@"fixture": large}}];
        for (int i = 0; i < 32; i++) [events addObject:@{@"event": @"main_thread.sample", @"fields": @{@"fixture": large}}];
        [events addObject:@{@"event": @"capture.stopped"}];
        NSDictionary *payload = @{@"events": events, @"events_dropped": @3};
        NSData *data = AMProjPerformanceEncode(payload);
        assert(data && data.length <= AMPROJ_PERF_MAX_BYTES);
        NSDictionary *report = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *retained = report[@"events"];
        assert([report[@"byte_budget_events_dropped"] unsignedIntegerValue] > 0);
        assert([report[@"events_dropped"] unsignedIntegerValue] ==
               3 + [report[@"byte_budget_events_dropped"] unsignedIntegerValue]);
        assert([retained.firstObject[@"event"] isEqual:@"capture.started"]);
        assert([retained.lastObject[@"event"] isEqual:@"capture.stopped"]);
        NSUInteger probes = 0;
        for (NSDictionary *event in retained) if ([event[@"event"] isEqual:@"main_thread.sample"]) probes++;
        assert(probes == 32 && events.count == 1058);
        puts("PERFORMANCE_REPORT_BUDGET_PASS");
    }
    return 0;
}
