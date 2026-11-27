// 猫鹤 AM · 执行生产更新来源、授权元数据和签名身份校验。
#import <Foundation/Foundation.h>
#import "AMAppUpdatePolicy.h"

static void Require(BOOL value) { if (!value) abort(); }
static NSString *Token(NSDictionary *value) {
    NSString *body = [[NSJSONSerialization dataWithJSONObject:value options:0 error:nil] base64EncodedStringWithOptions:0];
    body = [[body stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [body stringByAppendingString:@".fixture-signature"];
}
int main(void) { @autoreleasepool {
    Require(AMAppUpdateTrustedURL([NSURL URLWithString:@"https://am.ayakameow.cn/ota/manifest/test"], @"/ota/manifest/"));
    for (NSString *text in @[@"http://am.ayakameow.cn/ota/manifest/test",@"https://am.ayakameow.cn.evil.example/ota/manifest/test",@"https://am.ayakameow.cn:444/ota/manifest/test",@"https://user@am.ayakameow.cn/ota/manifest/test",@"https://am.ayakameow.cn/not-a-manifest/test",@"itms-services://?url=https://am.ayakameow.cn/ota/manifest/test"])
        Require(!AMAppUpdateTrustedURL([NSURL URLWithString:text], @"/ota/manifest/"));
    NSString *job = @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi012345_-";
    Require(job.length == 43);
    NSURL *manifest = [NSURL URLWithString:[@"https://am.ayakameow.cn/ota/manifest/" stringByAppendingString:job]];
    Require([AMAppUpdateInstallPage(manifest).absoluteString isEqual:[@"https://am.ayakameow.cn/install/" stringByAppendingString:job]]);
    for (NSString *text in @[@"https://other.example/ota/manifest/", @"https://am.ayakameow.cn/ota/manifest/short", [manifest.absoluteString stringByAppendingString:@"/suffix"], [manifest.absoluteString stringByAppendingString:@"?redirect=1"], [manifest.absoluteString stringByAppendingString:@"#fragment"], [manifest.absoluteString stringByAppendingString:@"%2F"], [manifest.absoluteString stringByReplacingOccurrencesOfString:@"https:" withString:@"http:"]])
        Require(!AMAppUpdateInstallPage([NSURL URLWithString:text]));
    NSMutableDictionary *claim = [@{@"v":@1,@"bundleId":@"com.ayakameow.am",@"channel":@"production",@"release":@176,@"teamId":@"TESTTEAM",@"expires":@(NSDate.date.timeIntervalSince1970 + 60)} mutableCopy];
    Require(AMAppUpdateClaim(Token(claim), @"com.ayakameow.am", @"stable", 176) != nil);
    Require(AMAppUpdateClaim(Token(claim), @"com.ayakameow.am.beta", @"beta", 176) == nil);
    Require(AMAppUpdateClaim(Token(claim), @"com.ayakameow.am", @"stable", 177) == nil);
    claim[@"expires"] = @0; Require(AMAppUpdateClaim(Token(claim), @"com.ayakameow.am", @"stable", 176) == nil);
    Require(AMAppUpdateClaim(@"broken", @"com.ayakameow.am", @"stable", 176) == nil);
    NSMutableData *cms = [[@"fixture CMS prefix" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [cms appendData:[NSPropertyListSerialization dataWithPropertyList:@{@"TeamIdentifier":@[@"TESTTEAM"]} format:NSPropertyListXMLFormat_v1_0 options:0 error:nil]];
    [cms appendData:[@"CMS suffix" dataUsingEncoding:NSUTF8StringEncoding]];
    Require([AMAppUpdateProfileTeamFromData(cms) isEqual:@"TESTTEAM"]);
    Require(!AMAppUpdateProfileTeamFromData([@"unreadable" dataUsingEncoding:NSUTF8StringEncoding]));
    puts("APP_UPDATE_POLICY_PASS");
} return 0; }
