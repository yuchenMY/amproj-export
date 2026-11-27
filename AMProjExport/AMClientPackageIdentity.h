// 猫鹤 AM · 打包器从插件编译标识写入的发布信息，独立于原应用 865。
#import <Foundation/Foundation.h>
// 用户可见的版本只使用包内发布日期；未知日期不拿当前时间冒充。
static inline NSString *AMClientPackageDisplayNameForInfo(NSDictionary *info) {
    NSString *date = info[@"AMProjReleaseDate"];
    NSString *channel = [info[@"AMProjReleaseChannel"] isEqual:@"beta"] ? @"测试版" : @"正式版";
    if (![date isKindOfClass:NSString.class] || date.length != 8 ||
        [date rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound)
        return [NSString stringWithFormat:@"猫鹤AM · %@", channel];
    return [NSString stringWithFormat:@"猫鹤AM · %@ %@", [date substringFromIndex:4], channel];
}
static inline NSString *AMClientPackageDisplayName(void) {
    return AMClientPackageDisplayNameForInfo(NSBundle.mainBundle.infoDictionary ?: @{});
}
static inline NSDictionary *AMClientPackageIdentity(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    id code = info[@"AMProjReleaseCode"], channel = info[@"AMProjReleaseChannel"], build = info[@"AMProjReleaseBuild"];
    return @{@"release": [code isKindOfClass:NSNumber.class] ? code : @0,
        @"channel": [channel isKindOfClass:NSString.class] ? channel : @"legacy",
        @"build": [build isKindOfClass:NSString.class] ? build : @"unknown"};
}
static inline NSString *AMClientPackageRequestScript(void) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:AMClientPackageIdentity() options:0 error:nil];
    NSString *value = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] ?: @"{}";
    return [NSString stringWithFormat:@"(function(){if(location.origin!=='https://am.meowcr.cn')return;const v=%@;"
        "function own(u){try{return new URL(u,location.href).origin==='https://am.meowcr.cn'&&new URL(u,location.href).pathname.startsWith('/api/');}catch(e){return false;}}"
        "function put(h){h.set('X-AM-Release-Code',String(v.release));h.set('X-AM-Release-Channel',v.channel);h.set('X-AM-Release-Build',v.build);}"
        "const f=window.fetch;window.fetch=function(i,o){if(own(typeof i==='string'||i instanceof URL?i:i.url)){o=Object.assign({},o);o.headers=new Headers(o.headers||(i&&i.headers)||{});put(o.headers);}return f.call(this,i,o);};"
        "const open=XMLHttpRequest.prototype.open,send=XMLHttpRequest.prototype.send;XMLHttpRequest.prototype.open=function(m,u){this.__amRelease=own(u);return open.apply(this,arguments);};"
        "XMLHttpRequest.prototype.send=function(){if(this.__amRelease){this.setRequestHeader('X-AM-Release-Code',String(v.release));this.setRequestHeader('X-AM-Release-Channel',v.channel);this.setRequestHeader('X-AM-Release-Build',v.build);}return send.apply(this,arguments);};})();",value];
}
