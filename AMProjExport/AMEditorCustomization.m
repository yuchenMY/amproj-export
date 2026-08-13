#import "AMEditorCustomization.h"

#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void (*AMEditorOriginalProjectEditLayout)(id, SEL) = NULL;
static UICollectionViewCell *(*AMEditorOriginalEffectBrowserCellForItem)(
    id, SEL, UICollectionView *, NSIndexPath *) = NULL;
static const void *AMEditorOtherCategoryBackgroundKey =
    &AMEditorOtherCategoryBackgroundKey;

static UIView *AMEditorViewForKey(id controller, NSString *key) {
    if (!controller || !key.length) return nil;
    SEL selector = NSSelectorFromString(key);
    if ([controller respondsToSelector:selector]) {
        id value = ((id (*)(id, SEL))(void *)objc_msgSend)(controller, selector);
        if ([value isKindOfClass:UIView.class]) return value;
    }
    @try {
        id value = [controller valueForKey:key];
        return [value isKindOfClass:UIView.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static UIButton *AMEditorButtonForKey(id controller, NSString *key) {
    UIView *view = AMEditorViewForKey(controller, key);
    return [view isKindOfClass:UIButton.class] ? (UIButton *)view : nil;
}

static void AMEditorCollectControls(UIView *view,
                                    NSMutableArray<UIControl *> *controls) {
    if (!view) return;
    if ([view isKindOfClass:UIControl.class]) {
        [controls addObject:(UIControl *)view];
    }
    for (UIView *subview in view.subviews) {
        AMEditorCollectControls(subview, controls);
    }
}

static void AMEditorHideView(UIView *view) {
    if (!view) return;
    view.hidden = YES;
    view.alpha = 0;
    view.userInteractionEnabled = NO;
    view.accessibilityElementsHidden = YES;
}

static UIControl *AMEditorFindMirroredQuickActionsControl(
    UIView *rootView, UIView *addLibraryView) {
    if (!rootView || !addLibraryView || !addLibraryView.superview) return nil;

    CGRect addFrame = [addLibraryView.superview convertRect:addLibraryView.frame
                                                    toView:rootView];
    if (CGRectIsEmpty(addFrame) || CGRectIsNull(addFrame)) return nil;
    CGFloat rootWidth = CGRectGetWidth(rootView.bounds);
    if (rootWidth <= 0 || CGRectGetMidX(addFrame) <= rootWidth * 0.5) return nil;

    CGPoint expectedCenter = CGPointMake(rootWidth - CGRectGetMidX(addFrame),
                                         CGRectGetMidY(addFrame));
    CGFloat verticalTolerance = MAX(44, CGRectGetHeight(addFrame) * 0.75);
    CGFloat bestScore = CGFLOAT_MAX;
    UIControl *bestControl = nil;
    NSMutableArray<UIControl *> *controls = [NSMutableArray array];
    AMEditorCollectControls(rootView, controls);
    for (UIControl *control in controls) {
        if (control == addLibraryView || control.hidden || control.alpha < 0.01 ||
            !control.superview) continue;
        CGRect frame = [control.superview convertRect:control.frame toView:rootView];
        CGFloat width = CGRectGetWidth(frame);
        CGFloat height = CGRectGetHeight(frame);
        if (width < 36 || height < 36 || width > 120 || height > 120 ||
            CGRectGetMidX(frame) >= rootWidth * 0.4 ||
            fabs(CGRectGetMidY(frame) - expectedCenter.y) > verticalTolerance) {
            continue;
        }
        CGFloat dx = CGRectGetMidX(frame) - expectedCenter.x;
        CGFloat dy = CGRectGetMidY(frame) - expectedCenter.y;
        CGFloat sizeDelta = fabs(width - CGRectGetWidth(addFrame)) +
                            fabs(height - CGRectGetHeight(addFrame));
        CGFloat score = hypot(dx, dy) + sizeDelta * 0.5;
        if (score < bestScore) {
            bestScore = score;
            bestControl = control;
        }
    }
    return bestControl;
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
    UIView *quickActionsView =
        AMEditorViewForKey(controller, @"quickActionsButton");
    AMEditorHideView(quickActionsView);

    UIView *rootView = [controller isKindOfClass:UIViewController.class]
        ? ((UIViewController *)controller).view : nil;
    UIControl *mirroredQuickActions =
        AMEditorFindMirroredQuickActionsControl(rootView, addLibraryButton);
    if (mirroredQuickActions && mirroredQuickActions != quickActionsView) {
        AMEditorHideView(mirroredQuickActions);
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

static void AMEditorCollectLabels(UIView *view,
                                  NSMutableArray<UILabel *> *labels) {
    if (!view) return;
    if ([view isKindOfClass:UILabel.class]) {
        [labels addObject:(UILabel *)view];
    }
    for (UIView *subview in view.subviews) {
        AMEditorCollectLabels(subview, labels);
    }
}

static NSString *AMEditorNormalizedTitle(NSString *title) {
    if (![title isKindOfClass:NSString.class]) return @"";
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    return [[title stringByTrimmingCharactersInSet:whitespace] lowercaseString];
}

static BOOL AMEditorIsOtherCategoryCell(UICollectionViewCell *cell,
                                        UICollectionView *collectionView,
                                        NSIndexPath *indexPath) {
    Class categoryCellClass = AMEditorCategoryCellClass();
    if (!categoryCellClass || ![cell isKindOfClass:categoryCellClass]) return NO;
    NSString *otherTitle = [NSBundle.mainBundle
        localizedStringForKey:@"fxcat_other" value:@"Other" table:nil];
    NSSet<NSString *> *knownTitles = [NSSet setWithObjects:
        AMEditorNormalizedTitle(otherTitle), @"other", @"\u5176\u4ed6", nil];
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    AMEditorCollectLabels(cell.contentView, labels);
    for (UILabel *label in labels) {
        if ([knownTitles containsObject:AMEditorNormalizedTitle(label.text)]) {
            return YES;
        }
    }

    NSInteger itemCount = [collectionView numberOfItemsInSection:indexPath.section];
    return itemCount >= 12 && indexPath.item == itemCount - 1;
}

static void AMEditorCollectImageViews(UIView *view,
                                      NSMutableArray<UIImageView *> *imageViews) {
    if (!view) return;
    if ([view isKindOfClass:UIImageView.class]) {
        [imageViews addObject:(UIImageView *)view];
    }
    for (UIView *subview in view.subviews) {
        AMEditorCollectImageViews(subview, imageViews);
    }
}

static UIImageView *AMEditorCategoryBackgroundImageView(
    UICollectionViewCell *cell) {
    NSMutableArray<UIImageView *> *imageViews = [NSMutableArray array];
    AMEditorCollectImageViews(cell.contentView, imageViews);
    UIImageView *bestImageView = nil;
    CGFloat bestArea = 0;
    for (UIImageView *imageView in imageViews) {
        if (imageView.hidden || imageView.alpha < 0.01) continue;
        CGRect frame = [imageView.superview convertRect:imageView.frame
                                                 toView:cell.contentView];
        CGRect visibleFrame = CGRectIntersection(frame, cell.contentView.bounds);
        CGFloat area = CGRectGetWidth(visibleFrame) * CGRectGetHeight(visibleFrame);
        if (area > bestArea) {
            bestArea = area;
            bestImageView = imageView;
        }
    }
    return bestImageView;
}

static void AMEditorRestoreCategoryCell(UICollectionViewCell *cell) {
    UIImageView *installedView = objc_getAssociatedObject(
        cell, AMEditorOtherCategoryBackgroundKey);
    [installedView removeFromSuperview];
    objc_setAssociatedObject(cell, AMEditorOtherCategoryBackgroundKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void AMEditorCustomizeCategoryCell(UICollectionViewCell *cell,
                                          UICollectionView *collectionView,
                                          NSIndexPath *indexPath) {
    AMEditorRestoreCategoryCell(cell);
    if (!AMEditorIsOtherCategoryCell(cell, collectionView, indexPath)) {
        return;
    }

    UIImage *image = AMEditorOtherCategoryImage();
    if (!image) return;

    UIImageView *target = AMEditorCategoryBackgroundImageView(cell);
    UIView *container = target ?: cell.contentView;
    UIImageView *imageView = [[UIImageView alloc] initWithFrame:container.bounds];
    imageView.image = image;
    imageView.contentMode = UIViewContentModeScaleAspectFill;
    imageView.clipsToBounds = YES;
    imageView.userInteractionEnabled = NO;
    imageView.accessibilityElementsHidden = YES;
    imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleHeight;
    if (target) {
        [target addSubview:imageView];
    } else {
        [cell.contentView insertSubview:imageView atIndex:0];
    }
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
    AMEditorCustomizeCategoryCell(cell, collectionView, indexPath);
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
