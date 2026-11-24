// 猫鹤 AM · Foundation 宿主模型执行真实扫描函数；辅助功能访问会直接失败。
#import <Foundation/Foundation.h>
#include <assert.h>
static NSUInteger visits = 0;
static NSUInteger accessibilityReads = 0;

@interface CALayer : NSObject
@property(nonatomic, strong) NSArray<CALayer *> *sublayers;
@end
@implementation CALayer
@end
@interface CATextLayer : CALayer
@property(nonatomic, strong) id string;
@end
@implementation CATextLayer
@end
@interface UIView : NSObject
@property(nonatomic, strong) NSArray<UIView *> *nodes;
@property(nonatomic, strong) CALayer *layer;
@property(nonatomic, readonly) NSArray<UIView *> *subviews;
- (id)accessibilityLabel;
- (id)accessibilityValue;
@end
@implementation UIView
- (instancetype)init { if ((self = [super init])) _layer = [CALayer new]; return self; }
- (NSArray *)subviews { visits++; return self.nodes ?: @[]; }
- (id)accessibilityLabel { accessibilityReads++; [NSException raise:@"UnexpectedAX" format:@"label"]; return nil; }
- (id)accessibilityValue { accessibilityReads++; [NSException raise:@"UnexpectedAX" format:@"value"]; return nil; }
@end
@interface UILabel : UIView
@property(nonatomic, copy) NSString *text;
@end
@implementation UILabel
@end
@interface UIButton : UIView
@property(nonatomic, copy) NSString *currentTitle;
@end
@implementation UIButton
@end
@interface UITextView : UIView
@property(nonatomic, copy) NSString *text;
@end
@implementation UITextView
@end
@interface UITextField : UIView
@property(nonatomic, copy) NSString *text;
@end
@implementation UITextField
@end

// AMPROJ_PRODUCTION_WELCOME_WALK

int main(void) {
    @autoreleasepool {
        UIView *root = [UIView new], *parent = root;
        for (int level = 0; level < 20; level++) {
            UIView *next = [UIView new];
            NSMutableArray *nodes = [NSMutableArray arrayWithObject:next];
            for (int i = 0; i < 50; i++) [nodes addObject:[UILabel new]];
            parent.nodes = nodes; parent = next;
        }
        visits = 0;
        assert(amproj_IPAFireFindOverlayView(root, 0) == nil);
        assert(visits == 1021 && accessibilityReads == 0);
        UILabel *nativeLabel = [UILabel new]; nativeLabel.text = @"cracked by blatant";
        UIView *overlay = [UIView new]; overlay.nodes = @[nativeLabel];
        assert(amproj_IPAFireViewContainsMarker(overlay, 0));
        assert(amproj_IPAFireFindOverlayView(overlay, 0) == nativeLabel);
        nativeLabel.text = @"Welcome to my project";
        assert(!amproj_IPAFireViewContainsMarker(overlay, 0));
        CATextLayer *layer = [CATextLayer new]; layer.string = @"@ipafire";
        overlay.layer.sublayers = @[layer];
        assert(amproj_IPAFireViewContainsMarker(overlay, 0));
        assert(accessibilityReads == 0);
        puts("WELCOME_WALK_PASS nodes=1021 accessibility_reads=0");
    }
    return 0;
}
