// 猫鹤 AM · Beta 报告字节预算；优先保留采样与起止记录。
#ifndef AMPROJ_PERFORMANCE_REPORT_H
#define AMPROJ_PERFORMANCE_REPORT_H
#import <Foundation/Foundation.h>
#include "AMProjPerformancePolicy.h"

static inline NSData *AMProjPerformanceEncode(NSDictionary *payload) {
    NSMutableDictionary *report = [payload mutableCopy];
    NSMutableArray<NSDictionary *> *events = [payload[@"events"] mutableCopy];
    NSUInteger originalDropped = [payload[@"events_dropped"] unsignedIntegerValue];
    NSUInteger dropped = 0;
    while (true) {
        report[@"events"] = events;
        report[@"events_dropped"] = @(originalDropped + dropped);
        report[@"byte_budget_events_dropped"] = @(dropped);
        NSData *data = [NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
        if (!data || data.length <= AMPROJ_PERF_MAX_BYTES) return data;
        BOOL touches = NO;
        for (NSDictionary *event in events) {
            if ([event[@"event"] isEqual:@"input.touch"]) { touches = YES; break; }
        }
        NSUInteger quota = MAX((NSUInteger)1, events.count / 4), removed = 0;
        for (NSUInteger i = 0; i < events.count && removed < quota;) {
            NSString *kind = events[i][@"event"];
            BOOL critical = [kind isEqual:@"capture.started"] || [kind isEqual:@"capture.stopped"] ||
                [kind isEqual:@"main_thread.sample"] || [kind hasPrefix:@"main_queue."];
            if ((touches && [kind isEqual:@"input.touch"]) || (!touches && !critical)) {
                [events removeObjectAtIndex:i]; removed++;
            } else i++;
        }
        if (!removed) return nil;
        dropped += removed;
    }
}
#endif
