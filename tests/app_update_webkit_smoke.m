// 使用真实 WebKit 编译生产规则，并复现旧过滤表达式被拒绝的情况。
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import "AMAppUpdatePolicy.h"

static void Require(BOOL value) { if (!value) abort(); }
static BOOL Compile(WKContentRuleListStore *store, NSString *rules) {
    __block BOOL done = NO, accepted = NO;
    NSString *identifier = [@"AMUpdateRuleTest-" stringByAppendingString:NSUUID.UUID.UUIDString];
    [store compileContentRuleListForIdentifier:identifier encodedContentRuleList:rules completionHandler:^(WKContentRuleList *list, NSError *error) {
        accepted = list != nil && error == nil;
        done = YES;
        if (error) fprintf(stderr, "WEBKIT_RULE_COMPILER: %s/%ld %s\n", error.domain.UTF8String, (long)error.code, error.localizedDescription.UTF8String);
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    while (!done && deadline.timeIntervalSinceNow > 0) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    Require(done);
    return accepted;
}
int main(void) { @autoreleasepool {
    NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    Require([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil]);
    WKContentRuleListStore *store = [WKContentRuleListStore storeWithURL:directory];
    NSString *old = @"[{\"trigger\":{\"url-filter\":\"^https://am[.]ayakameow[.]cn/(api/public/sign/|install/|ota/)\"},\"action\":{\"type\":\"block\"}}]";
    Require(!Compile(store, old));
    NSString *current = AMAppUpdateAssociationRules();
    Require(Compile(store, current));
    NSArray *rules = [NSJSONSerialization JSONObjectWithData:[current dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    Require(rules.count == 3);
    for (NSString *path in @[@"api/public/sign/fixture", @"install/fixture", @"ota/manifest/fixture", @"ota/ipa/fixture", @"", @"api/app-update/link", @"api/public/config", @"udid/mobileconfig/fixture", @"app.js"]) {
        NSString *url = [@"https://am.ayakameow.cn/" stringByAppendingString:path];
        BOOL blocked = NO;
        for (NSDictionary *rule in rules) {
            Require([rule[@"action"][@"type"] isEqual:@"block"]);
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:rule[@"trigger"][@"url-filter"] options:NSRegularExpressionCaseInsensitive error:nil];
            blocked |= [regex firstMatchInString:url options:0 range:NSMakeRange(0, url.length)] != nil;
        }
        BOOL expected = [path hasPrefix:@"api/public/sign/"] || [path hasPrefix:@"install/"] || [path hasPrefix:@"ota/"];
        Require(blocked == expected);
    }
    [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
    puts("APP_UPDATE_WEBKIT_RULES_PASS");
} return 0; }
