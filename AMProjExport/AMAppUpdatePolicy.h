// 猫鹤 AM · 更新服务来源和本机授权元数据校验。
#import <Foundation/Foundation.h>

static BOOL AMAppUpdateTrustedURL(NSURL *url, NSString *pathPrefix) {
    return [url.scheme.lowercaseString isEqual:@"https"] && [url.host.lowercaseString isEqual:@"am.ayakameow.cn"] &&
        !url.user.length && !url.password.length && (!url.port || url.port.integerValue == 443) &&
        [url.path hasPrefix:pathPrefix];
}

static NSString *AMAppUpdateProfileTeamFromData(NSData *data) {
    if (!data) return nil;
    NSData *start = [@"<?xml" dataUsingEncoding:NSUTF8StringEncoding], *end = [@"</plist>" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange a = [data rangeOfData:start options:0 range:NSMakeRange(0, data.length)];
    NSRange b = [data rangeOfData:end options:NSDataSearchBackwards range:NSMakeRange(0, data.length)];
    if (a.location == NSNotFound || b.location == NSNotFound || b.location < a.location) return nil;
    id profile = [NSPropertyListSerialization propertyListWithData:[data subdataWithRange:NSMakeRange(a.location, NSMaxRange(b) - a.location)] options:NSPropertyListImmutable format:nil error:nil];
    if (![profile isKindOfClass:NSDictionary.class] || ![profile[@"TeamIdentifier"] isKindOfClass:NSArray.class]) return nil;
    id team = [profile[@"TeamIdentifier"] firstObject]; return [team isKindOfClass:NSString.class] ? team : nil;
}

static NSDictionary *AMAppUpdateClaim(NSString *token, NSString *bundle, NSString *channel, NSInteger release) {
    if (![token isKindOfClass:NSString.class] || token.length > 4096) return nil;
    NSArray *parts = [token componentsSeparatedByString:@"."]; if (parts.count != 2) return nil;
    NSString *encoded = [parts[0] stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    encoded = [encoded stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (encoded.length % 4) encoded = [encoded stringByAppendingString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSString *siteChannel = [channel isEqual:@"stable"] ? @"production" : channel;
    return [value[@"v"] isEqual:@1] && [value[@"bundleId"] isEqual:bundle] && [value[@"channel"] isEqual:siteChannel] &&
        [value[@"release"] isKindOfClass:NSNumber.class] && [value[@"release"] integerValue] == release &&
        [value[@"expires"] isKindOfClass:NSNumber.class] && [value[@"expires"] doubleValue] > NSDate.date.timeIntervalSince1970 &&
        [value[@"teamId"] isKindOfClass:NSString.class] ? value : nil;
}
