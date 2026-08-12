#import "AMEditorCustomization.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void (*AMEditorOriginalProjectEditLayout)(id, SEL) = NULL;

static UIButton *AMEditorButtonForKey(id controller, NSString *key) {
    if (!controller || !key.length) return nil;
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

static void AMEditorCustomizeProjectEditController(id controller) {
    UIButton *quickActionsButton =
        AMEditorButtonForKey(controller, @"quickActionsButton");
    if (quickActionsButton) {
        quickActionsButton.hidden = YES;
        quickActionsButton.userInteractionEnabled = NO;
        quickActionsButton.accessibilityElementsHidden = YES;
    }

    UIButton *addLibraryButton =
        AMEditorButtonForKey(controller, @"addLibraryButton");
    UIImage *image = AMEditorAddLayerImage();
    if (!addLibraryButton || !image) return;

    addLibraryButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
    addLibraryButton.adjustsImageWhenHighlighted = NO;
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
