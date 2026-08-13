#import "AMEditorCustomization.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void (*AMEditorOriginalProjectEditLayout)(id, SEL) = NULL;
static UICollectionViewCell *(*AMEditorOriginalEffectBrowserCellForItem)(
    id, SEL, UICollectionView *, NSIndexPath *) = NULL;
static const void *AMEditorOtherCategoryBackgroundKey =
    &AMEditorOtherCategoryBackgroundKey;

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

static UIImage *AMEditorOtherCategoryImage(void) {
    static UIImage *image = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = [NSBundle.mainBundle
            pathForResource:@"ic_category_thumbnail_other"
                     ofType:@"png"
                inDirectory:@"BuiltinCategory/thumb"];
        if (path.length) {
            image = [UIImage imageWithContentsOfFile:path];
        }
    });
    return image;
}

static void AMEditorCustomizeProjectEditController(id controller) {
    UIButton *addLibraryButton =
        AMEditorButtonForKey(controller, @"addLibraryButton");
    UIButton *quickActionsButton =
        AMEditorButtonForKey(controller, @"quickActionsButton");
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

static Class AMEditorEffectBrowserClass(void) {
    Class cls = NSClassFromString(@"AlightMotion.EffectBrowser");
    if (!cls) cls = objc_getClass("_TtC12AlightMotion13EffectBrowser");
    return cls;
}

static Class AMEditorCategoryCellClass(void) {
    Class cls = NSClassFromString(@"AlightMotion.CategoryCell");
    if (!cls) cls = objc_getClass("_TtC12AlightMotion12CategoryCell");
    return cls;
}

static UILabel *AMEditorCategoryCellLabel(UICollectionViewCell *cell) {
    SEL selector = NSSelectorFromString(@"label");
    if (!cell || ![cell respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))(void *)objc_msgSend)(cell, selector);
    return [value isKindOfClass:UILabel.class] ? value : nil;
}

static BOOL AMEditorIsOtherCategoryCell(UICollectionViewCell *cell) {
    Class categoryCellClass = AMEditorCategoryCellClass();
    if (!categoryCellClass || ![cell isKindOfClass:categoryCellClass]) return NO;
    NSString *title = AMEditorCategoryCellLabel(cell).text;
    NSString *otherTitle = [NSBundle.mainBundle
        localizedStringForKey:@"fxcat_other" value:@"Other" table:nil];
    return title.length && [title isEqualToString:otherTitle];
}

static void AMEditorCustomizeCategoryCell(UICollectionViewCell *cell) {
    UIImageView *installedView = objc_getAssociatedObject(
        cell, AMEditorOtherCategoryBackgroundKey);
    if (!AMEditorIsOtherCategoryCell(cell)) {
        if (installedView && cell.backgroundView == installedView) {
            cell.backgroundView = nil;
        }
        objc_setAssociatedObject(cell, AMEditorOtherCategoryBackgroundKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    UIImage *image = AMEditorOtherCategoryImage();
    if (!image) return;
    UIImageView *imageView = installedView ?: [[UIImageView alloc] init];
    imageView.image = image;
    imageView.contentMode = UIViewContentModeScaleAspectFill;
    imageView.clipsToBounds = YES;
    imageView.userInteractionEnabled = NO;
    imageView.accessibilityElementsHidden = YES;
    cell.backgroundView = imageView;
    objc_setAssociatedObject(cell, AMEditorOtherCategoryBackgroundKey, imageView,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UICollectionViewCell *AMEditorEffectBrowserCellForItem(
    id self, SEL selector, UICollectionView *collectionView,
    NSIndexPath *indexPath) {
    UICollectionViewCell *cell = AMEditorOriginalEffectBrowserCellForItem
        ? AMEditorOriginalEffectBrowserCellForItem(
              self, selector, collectionView, indexPath)
        : nil;
    AMEditorCustomizeCategoryCell(cell);
    return cell;
}

static void AMEditorInstallProjectEditCustomization(void) {
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
        method_setImplementation(method, (IMP)AMEditorProjectEditLayout);
    }
}

static void AMEditorInstallEffectBrowserCustomization(void) {
    Class cls = AMEditorEffectBrowserClass();
    SEL selector = @selector(collectionView:cellForItemAtIndexPath:);
    Method method = class_getInstanceMethod(cls, selector);
    if (!cls || !method || method_getNumberOfArguments(method) != 4) return;

    IMP original = method_getImplementation(method);
    if (original == (IMP)AMEditorEffectBrowserCellForItem) return;
    const char *types = method_getTypeEncoding(method);
    if (!types) return;

    AMEditorOriginalEffectBrowserCellForItem = (void *)original;
    if (!class_addMethod(cls, selector, (IMP)AMEditorEffectBrowserCellForItem,
                         types)) {
        method_setImplementation(method, (IMP)AMEditorEffectBrowserCellForItem);
    }
}

void AMEditorCustomizationInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        AMEditorInstallProjectEditCustomization();
        AMEditorInstallEffectBrowserCustomization();
    });
}
