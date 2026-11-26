// 猫鹤 AM · 网站签名服务与应用内更新入口。
#import <UIKit/UIKit.h>

// 主线程调用。presenter 必须已显示且没有模态页面；Beta 退役走独立正式版迁移。
void AMAppUpdatePresent(UIViewController *presenter, NSURL *website, BOOL retiredBeta);
