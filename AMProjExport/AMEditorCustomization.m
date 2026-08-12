#import "AMEditorCustomization.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void (*AMEditorOriginalProjectEditLayout)(id, SEL) = NULL;

static UIButton *AMEditorButtonForKey(id controller, NSString *key) {
    if (!controller || !key.length) return nil;
    SEL selector = NSSelectorFromString(key);
    if ([controller respondsToSelector:selector]) {
        id value = ((id (*)(id, SEL))(void *)objc_msgSend)(controller, selector);
        if ([value isKindOfClass:UIButton.class]) return value;
    }
    @try {
        id value = [controller valueForKey:key];
        return [value isKindOfClass:UIButton.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static UIImage *AMEditorAddLayerImage(void) {
    static UIImage *image = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = [NSBundle.mainBundle
            pathForResource:@"autfeng_add_layer_button" ofType:@"png"];
        if (path.length) {
            image = [[UIImage imageWithContentsOfFile:path]
                imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        }
    });
    return image;
}

static void AMEditorCollectButtons(UIView *view, NSMutableArray<UIButton *> *buttons) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:UIButton.class]) {
            [buttons addObject:(UIButton *)subview];
        }
        AMEditorCollectButtons(subview, buttons);
    }
}

static UIButton *AMEditorMirroredQuickActionsButton(UIView *root,
                                                     UIButton *addButton) {
    if (!root || !addButton || !addButton.superview) return nil;
    CGPoint addCenter = [addButton.superview convertPoint:addButton.center toView:root];
    CGFloat targetX = CGRectGetWidth(root.bounds) - addCenter.x;
    CGFloat maximumDistance = MAX(48.0, CGRectGetWidth(addButton.bounds));
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    AMEditorCollectButtons(root, buttons);

    UIButton *best = nil;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (UIButton *candidate in buttons) {
        if (candidate == addButton || candidate.hidden || candidate.alpha <= 0.01 ||
            !candidate.superview || CGRectIsEmpty(candidate.bounds)) continue;
        CGPoint center = [candidate.superview convertPoint:candidate.center toView:root];
        if (center.x >= CGRectGetMidX(root.bounds)) continue;
        if (fabs(center.y - addCenter.y) > maximumDistance) continue;

        CGFloat widthRatio = CGRectGetWidth(candidate.bounds) /
            MAX(1.0, CGRectGetWidth(addButton.bounds));
        CGFloat heightRatio = CGRectGetHeight(candidate.bounds) /
            MAX(1.0, CGRectGetHeight(addButton.bounds));
        if (widthRatio < 0.55 || widthRatio > 1.8 ||
            heightRatio < 0.55 || heightRatio > 1.8) continue;

        CGFloat distance = hypot(center.x - targetX, center.y - addCenter.y);
        if (distance <= maximumDistance && distance < bestDistance) {
            best = candidate;
            bestDistance = distance;
        }
    }
    return best;
}

static void AMEditorCustomizeProjectEditController(id controller) {
    UIButton *addLibraryButton =
        AMEditorButtonForKey(controller, @"addLibraryButton");
    UIButton *quickActionsButton =
        AMEditorButtonForKey(controller, @"quickActionsButton");
    if (!quickActionsButton && [controller isKindOfClass:UIViewController.class]) {
        quickActionsButton = AMEditorMirroredQuickActionsButton(
            ((UIViewController *)controller).viewIfLoaded, addLibraryButton);
    }
    if (quickActionsButton) {
        quickActionsButton.hidden = YES;
        quickActionsButton.userInteractionEnabled = NO;
        quickActionsButton.accessibilityElementsHidden = YES;
    }

    UIImage *image = AMEditorAddLayerImage();
    if (!addLibraryButton || !image) return;

    addLibraryButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
    addLibraryButton.adjustsImageWhenHighlighted = NO;
    if (@available(iOS 15.0, *)) {
        UIButtonConfiguration *configuration = addLibraryButton.configuration;
        if (configuration) {
            configuration.image = image;
            addLibraryButton.configuration = configuration;
        }
    }
    [addLibraryButton setImage:image forState:UIControlStateNormal];
    [addLibraryButton setImage:image forState:UIControlStateHighlighted];
    [addLibraryButton setImage:image forState:UIControlStateSelected];
}

static void AMEditorProjectEditLayout(id self, SEL selector) {
    if (AMEditorOriginalProjectEditLayout) {
        AMEditorOriginalProjectEditLayout(self, selector);
    }
    AMEditorCustomizeProjectEditController(self);
}

static Class AMEditorProjectEditClass(void) {
    Class cls = NSClassFromString(@"AlightMotion.ProjectEditVC");
    if (!cls) cls = objc_getClass("_TtC12AlightMotion13ProjectEditVC");
    return cls;
}

void AMEditorCustomizationInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = AMEditorProjectEditClass();
        SEL selector = @selector(viewDidLayoutSubviews);
        Method method = class_getInstanceMethod(cls, selector);
        if (!cls || !method || method_getNumberOfArguments(method) != 2) return;

        IMP original = method_getImplementation(method);
        if (original == (IMP)AMEditorProjectEditLayout) return;
        const char *types = method_getTypeEncoding(method);
        if (!types) return;

        AMEditorOriginalProjectEditLayout = (void *)original;
        if (!class_addMethod(cls, selector, (IMP)AMEditorProjectEditLayout, types)) {
            Method ownMethod = class_getInstanceMethod(cls, selector);
            method_setImplementation(ownMethod, (IMP)AMEditorProjectEditLayout);
        }
    });
}
