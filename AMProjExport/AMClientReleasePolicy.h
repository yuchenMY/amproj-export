// 猫鹤 AM · 更新策略输入校验与离线决策，供原生回归直接执行。
#import <Foundation/Foundation.h>
#include <math.h>
static inline BOOL AMClientReleaseInteger(id value, double maximum) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    double number = [value doubleValue];
    return isfinite(number) && number >= 0 && number <= maximum && floor(number) == number;
}
static inline BOOL AMClientReleaseURLValid(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] > 4096) return NO;
    NSURLComponents *url = [NSURLComponents componentsWithString:value];
    return [url.scheme.lowercaseString isEqualToString:@"https"] && url.host.length && !url.user && !url.password;
}
static inline NSDictionary *AMClientReleaseValidatedPolicy(id value, NSString *channel) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *policy = value;
    if (![policy[@"protocol"] isEqual:@1] || ![policy[@"channel"] isEqual:channel] ||
        !([channel isEqual:@"stable"] || [channel isEqual:@"beta"])) return nil;
    for (NSString *key in @[@"revision", @"serverNow", @"forceAfter", @"minimumRelease", @"latestRelease"])
        if (!AMClientReleaseInteger(policy[key], 1000000000000.0)) return nil;
    if ([policy[@"serverNow"] doubleValue] <= 0 ||
        [policy[@"minimumRelease"] doubleValue] > [policy[@"latestRelease"] doubleValue]) return nil;
    for (NSString *key in @[@"enabled", @"retired"])
        if (![policy[key] isKindOfClass:NSNumber.class] ||
            !([policy[key] isEqual:@NO] || [policy[key] isEqual:@YES])) return nil;
    if ([policy[@"retired"] boolValue] && ![channel isEqual:@"beta"]) return nil;
    if (![policy[@"message"] isKindOfClass:NSString.class] || [policy[@"message"] length] > 1000 ||
        ![policy[@"downloadURL"] isKindOfClass:NSString.class]) return nil;
    if ([policy[@"downloadURL"] length] && !AMClientReleaseURLValid(policy[@"downloadURL"])) return nil;
    if ([policy[@"enabled"] boolValue] &&
        (!AMClientReleaseURLValid(policy[@"downloadURL"]) ||
        (![policy[@"retired"] boolValue] && [policy[@"latestRelease"] integerValue] == 0))) return nil;
    return policy;
}
static inline BOOL AMClientReleasePolicyBlocked(NSDictionary *policy, NSInteger code, NSTimeInterval serverTime) {
    if (![policy[@"enabled"] boolValue]) return NO;
    NSTimeInterval deadline = [policy[@"forceAfter"] doubleValue];
    return (deadline == 0 || serverTime >= deadline) &&
        ([policy[@"retired"] boolValue] || code < [policy[@"minimumRelease"] integerValue]);
}
static inline NSDictionary *AMClientReleaseLoadCache(NSURL *url, NSString *channel, NSTimeInterval *receivedAt) {
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfURL:url];
    NSDictionary *policy = AMClientReleaseValidatedPolicy(saved[@"policy"], channel);
    id stamp = saved[@"receivedAt"];
    if (!policy || ![stamp isKindOfClass:NSNumber.class] || !isfinite([stamp doubleValue]) ||
        [stamp doubleValue] <= 0 || [stamp doubleValue] > 1000000000000.0) return nil;
    if (receivedAt) *receivedAt = [stamp doubleValue];
    return policy;
}
static inline BOOL AMClientReleaseSaveCache(NSURL *url, NSDictionary *policy, NSTimeInterval receivedAt) {
    if (![NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    return [@{@"policy":policy,@"receivedAt":@(receivedAt)} writeToURL:url atomically:YES];
}
static inline BOOL AMClientReleaseSafePresenter(NSString *className) {
    // Only established browsing pages may interrupt the user with an update gate.
    return [className isEqual:@"AMHomeUIController"] ||
        [className hasSuffix:@"HomeVC"] || [className hasSuffix:@"ProjectsVC"] ||
        [className hasSuffix:@"ProjectsListVC"] || [className isEqual:@"AMCloudAccountController"];
}
