#import "AMEditorCustomization.h"
#import "AMCloudSync.h"

#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void (*AMEditorOriginalProjectEditLayout)(id, SEL) = NULL;
static UICollectionViewCell *(*AMEditorOriginalEffectBrowserCellForItem)(
    id, SEL, UICollectionView *, NSIndexPath *) = NULL;
static void (*AMEditorOriginalCategoryCellLayout)(id, SEL) = NULL;
static void (*AMEditorOriginalEffectPickerMainCellLayout)(id, SEL) = NULL;
static void (*AMEditorOriginalEffectGroupSelection)(
    id, SEL, UITableView *, NSIndexPath *) = NULL;
static void (*AMEditorOriginalEffectPanelPresetSelection)(
    id, SEL, UITableView *, NSIndexPath *) = NULL;
static void (*AMEditorOriginalEffectPersistSelection)(
    id, SEL, UICollectionView *, NSIndexPath *) = NULL;
static void (*AMEditorOriginalEffectCategorySelection)(
    id, SEL, UICollectionView *, NSIndexPath *) = NULL;
static void (*AMEditorOriginalEffectRecommendSelection)(
    id, SEL, UICollectionView *, NSIndexPath *) = NULL;
static void (*AMEditorOriginalEffectSearchSelection)(
    id, SEL, UICollectionView *, NSIndexPath *) = NULL;
static const void *AMEditorOtherCategoryBackgroundKey =
    &AMEditorOtherCategoryBackgroundKey;
static __weak UIAlertController *AMEditorEffectLoginAlert = nil;

static UIViewController *AMEditorViewControllerForObject(id object) {
    if ([object isKindOfClass:UIViewController.class]) {
        return (UIViewController *)object;
    }
    UIResponder *responder = [object isKindOfClass:UIResponder.class]
        ? (UIResponder *)object : nil;
    while (responder) {
        responder = responder.nextResponder;
        if ([responder isKindOfClass:UIViewController.class]) {
            return (UIViewController *)responder;
        }
    }
    return nil;
}

static UIViewController *AMEditorTopViewController(UIViewController *controller) {
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    while (controller) {
        NSValue *identity = [NSValue
            valueWithPointer:(__bridge const void *)controller];
        if ([visited containsObject:identity]) break;
        [visited addObject:identity];
        UIViewController *next = controller.presentedViewController;
        if (!next && [controller isKindOfClass:UINavigationController.class]) {
            next = ((UINavigationController *)controller).visibleViewController;
        }
        if (!next && [controller isKindOfClass:UITabBarController.class]) {
            next = ((UITabBarController *)controller).selectedViewController;
        }
        if (!next || !next.viewIfLoaded.window) break;
        controller = next;
    }
    return controller.viewIfLoaded.window ? controller : nil;
}

static void AMEditorDeselectEffectItem(id listView, NSIndexPath *indexPath) {
    if (!indexPath) return;
    if ([listView isKindOfClass:UICollectionView.class]) {
        [(UICollectionView *)listView deselectItemAtIndexPath:indexPath
                                                    animated:YES];
    } else if ([listView isKindOfClass:UITableView.class]) {
        [(UITableView *)listView deselectRowAtIndexPath:indexPath animated:YES];
    }
}

static BOOL AMEditorAllowEffectSelection(id owner, id listView,
                                         NSIndexPath *indexPath) {
    if (AMCloudSyncHasLoggedInAccount()) return YES;
    AMEditorDeselectEffectItem(listView, indexPath);

    UIViewController *presenter = AMEditorTopViewController(
        AMEditorViewControllerForObject(owner));
    if (!presenter || AMEditorEffectLoginAlert) return NO;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"请先登录"
        message:@"登录 AyakaMeow 账户后即可使用效果。"
        preferredStyle:UIAlertControllerStyleAlert];
    AMEditorEffectLoginAlert = alert;
    __weak UIViewController *weakPresenter = presenter;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
        style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
            AMEditorEffectLoginAlert = nil;
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"去登录"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            AMEditorEffectLoginAlert = nil;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                AMCloudSyncShowAccountLoginFrom(weakPresenter);
            });
        }]];
    [presenter presentViewController:alert animated:YES completion:nil];
    return NO;
}

static void AMEditorEffectGroupSelection(
    id self, SEL selector, UITableView *tableView, NSIndexPath *indexPath) {
    if (!AMEditorAllowEffectSelection(self, tableView, indexPath)) return;
    if (AMEditorOriginalEffectGroupSelection) {
        AMEditorOriginalEffectGroupSelection(
            self, selector, tableView, indexPath);
    }
}

static void AMEditorEffectPanelPresetSelection(
    id self, SEL selector, UITableView *tableView, NSIndexPath *indexPath) {
    if (!AMEditorAllowEffectSelection(self, tableView, indexPath)) return;
    if (AMEditorOriginalEffectPanelPresetSelection) {
        AMEditorOriginalEffectPanelPresetSelection(
            self, selector, tableView, indexPath);
    }
}

static void AMEditorEffectPersistSelection(
    id self, SEL selector, UICollectionView *collectionView,
    NSIndexPath *indexPath) {
    if (!AMEditorAllowEffectSelection(self, collectionView, indexPath)) return;
    if (AMEditorOriginalEffectPersistSelection) {
        AMEditorOriginalEffectPersistSelection(
            self, selector, collectionView, indexPath);
    }
}

static void AMEditorEffectCategorySelection(
    id self, SEL selector, UICollectionView *collectionView,
    NSIndexPath *indexPath) {
    if (!AMEditorAllowEffectSelection(self, collectionView, indexPath)) return;
    if (AMEditorOriginalEffectCategorySelection) {
        AMEditorOriginalEffectCategorySelection(
            self, selector, collectionView, indexPath);
    }
}

static void AMEditorEffectRecommendSelection(
    id self, SEL selector, UICollectionView *collectionView,
    NSIndexPath *indexPath) {
    if (!AMEditorAllowEffectSelection(self, collectionView, indexPath)) return;
    if (AMEditorOriginalEffectRecommendSelection) {
        AMEditorOriginalEffectRecommendSelection(
            self, selector, collectionView, indexPath);
    }
}

static void AMEditorEffectSearchSelection(
    id self, SEL selector, UICollectionView *collectionView,
    NSIndexPath *indexPath) {
    if (!AMEditorAllowEffectSelection(self, collectionView, indexPath)) return;
    if (AMEditorOriginalEffectSearchSelection) {
        AMEditorOriginalEffectSearchSelection(
            self, selector, collectionView, indexPath);
    }
}

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
    CGRect rootBounds = rootView.bounds;
    CGFloat rootWidth = CGRectGetWidth(rootView.bounds);
    CGFloat rootHeight = CGRectGetHeight(rootBounds);
    CGFloat addWidth = CGRectGetWidth(addFrame);
    CGFloat addHeight = CGRectGetHeight(addFrame);
    CGFloat rootMidX = CGRectGetMidX(rootBounds);
    CGFloat bottomEdgeY = CGRectGetMaxY(rootBounds) -
        MAX(0, rootView.safeAreaInsets.bottom);
    CGFloat maximumBottomDistance =
        MAX(44, MIN(72, addHeight * 1.25));
    if (rootWidth <= 0 || rootHeight <= 0 || addWidth <= 0 || addHeight <= 0 ||
        CGRectGetMidX(addFrame) <= rootMidX + MAX(24, addWidth * 0.5) ||
        fabs(bottomEdgeY - CGRectGetMaxY(addFrame)) > maximumBottomDistance) {
        return nil;
    }

    CGPoint expectedCenter = CGPointMake(
        CGRectGetMinX(rootBounds) + CGRectGetMaxX(rootBounds) -
            CGRectGetMidX(addFrame),
        CGRectGetMidY(addFrame));
    CGFloat horizontalTolerance = MAX(8, MIN(16, addWidth * 0.22));
    CGFloat verticalTolerance = MAX(6, MIN(14, addHeight * 0.18));
    CGFloat widthTolerance = MAX(5, addWidth * 0.12);
    CGFloat heightTolerance = MAX(5, addHeight * 0.12);
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
        CGFloat dx = CGRectGetMidX(frame) - expectedCenter.x;
        CGFloat dy = CGRectGetMidY(frame) - expectedCenter.y;
        CGFloat widthDelta = fabs(width - addWidth);
        CGFloat heightDelta = fabs(height - addHeight);
        if (CGRectIsEmpty(frame) || CGRectIsNull(frame) ||
            CGRectGetMidX(frame) >= rootMidX - MAX(24, addWidth * 0.5) ||
            fabs(bottomEdgeY - CGRectGetMaxY(frame)) >
                maximumBottomDistance ||
            fabs(dx) > horizontalTolerance ||
            fabs(dy) > verticalTolerance || widthDelta > widthTolerance ||
            heightDelta > heightTolerance) {
            continue;
        }
        CGFloat score = hypot(dx, dy) + (widthDelta + heightDelta) * 0.5;
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

static Class AMEditorEffectPickerMainCellClass(void) {
    Class cls = NSClassFromString(@"AlightMotion.EffectPickerMainCell");
    if (!cls) cls = objc_getClass("_TtC12AlightMotion20EffectPickerMainCell");
    return cls;
}

static Class AMEditorEffectGroupControllerClass(void) {
    Class cls = NSClassFromString(@"AlightMotion.EffectGroupController");
    if (!cls) {
        cls = objc_getClass("_TtC12AlightMotion21EffectGroupController");
    }
    return cls;
}

static Class AMEditorEffectPickerPanelContentClass(void) {
    Class cls = NSClassFromString(@"AlightMotion.EffectPickerPanelContentVC");
    if (!cls) {
        cls = objc_getClass("_TtC12AlightMotion26EffectPickerPanelContentVC");
    }
    return cls;
}

static Class AMEditorEffectPickerPersistCollectionClass(void) {
    Class cls = NSClassFromString(
        @"AlightMotion.EffectPickerPersistCollectionView");
    if (!cls) {
        cls = objc_getClass(
            "_TtC12AlightMotion33EffectPickerPersistCollectionView");
    }
    return cls;
}

static Class AMEditorEffectPickerCategoryClass(void) {
    Class cls = NSClassFromString(@"AlightMotion.EffectPickerCategoryVC");
    if (!cls) {
        cls = objc_getClass("_TtC12AlightMotion22EffectPickerCategoryVC");
    }
    return cls;
}

static Class AMEditorEffectPickerRecommendCollectionClass(void) {
    Class cls = NSClassFromString(
        @"AlightMotion.EffectPickerRecommendCollectionView");
    if (!cls) {
        cls = objc_getClass(
            "_TtC12AlightMotion35EffectPickerRecommendCollectionView");
    }
    return cls;
}

static Class AMEditorEffectPickerSearchClass(void) {
    Class cls = NSClassFromString(@"AlightMotion.EffectPickerSearchVC");
    if (!cls) {
        cls = objc_getClass("_TtC12AlightMotion20EffectPickerSearchVC");
    }
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

static UILabel *AMEditorCategoryCellLabel(UICollectionViewCell *cell) {
    UIView *view = AMEditorViewForKey(cell, @"label");
    if (![view isKindOfClass:UILabel.class]) {
        view = AMEditorViewForKey(cell, @"titleLabel");
    }
    return [view isKindOfClass:UILabel.class] ? (UILabel *)view : nil;
}

static BOOL AMEditorTitleMatchesKnownTitles(
    NSString *title, NSSet<NSString *> *knownTitles) {
    NSString *normalized = AMEditorNormalizedTitle(title);
    return normalized.length && [knownTitles containsObject:normalized];
}

static BOOL AMEditorViewContainsOtherAccessibilityTitle(
    UIView *view, NSSet<NSString *> *knownTitles) {
    if (!view) return NO;
    if (AMEditorTitleMatchesKnownTitles(view.accessibilityLabel, knownTitles)) {
        return YES;
    }
    for (UIView *subview in view.subviews) {
        if (AMEditorViewContainsOtherAccessibilityTitle(subview, knownTitles)) {
            return YES;
        }
    }
    return NO;
}

static BOOL AMEditorIsOtherCategoryCell(UICollectionViewCell *cell) {
    Class categoryCellClass = AMEditorCategoryCellClass();
    Class pickerCellClass = AMEditorEffectPickerMainCellClass();
    BOOL isSupportedCell =
        (categoryCellClass && [cell isKindOfClass:categoryCellClass]) ||
        (pickerCellClass && [cell isKindOfClass:pickerCellClass]);
    if (!isSupportedCell) return NO;
    NSString *otherTitle = [NSBundle.mainBundle
        localizedStringForKey:@"fxcat_other" value:@"Other" table:nil];
    NSMutableSet<NSString *> *knownTitles =
        [NSMutableSet setWithObjects:@"other", @"\u5176\u4ed6", nil];
    NSString *localizedTitle = AMEditorNormalizedTitle(otherTitle);
    if (localizedTitle.length) [knownTitles addObject:localizedTitle];

    UILabel *outletLabel = AMEditorCategoryCellLabel(cell);
    if (AMEditorTitleMatchesKnownTitles(outletLabel.text, knownTitles) ||
        AMEditorTitleMatchesKnownTitles(outletLabel.accessibilityLabel,
                                        knownTitles)) {
        return YES;
    }

    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    AMEditorCollectLabels(cell.contentView, labels);
    for (UILabel *label in labels) {
        if (label != outletLabel &&
            (AMEditorTitleMatchesKnownTitles(label.text, knownTitles) ||
             AMEditorTitleMatchesKnownTitles(label.accessibilityLabel,
                                             knownTitles))) {
            return YES;
        }
    }
    return AMEditorViewContainsOtherAccessibilityTitle(cell.contentView,
                                                        knownTitles) ||
           AMEditorTitleMatchesKnownTitles(cell.accessibilityLabel, knownTitles);
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
    UIView *thumbnail = AMEditorViewForKey(cell, @"thumbnailImageView");
    if ([thumbnail isKindOfClass:UIImageView.class]) {
        return (UIImageView *)thumbnail;
    }

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

static void AMEditorRemoveOtherCategoryBackground(UICollectionViewCell *cell) {
    UIImageView *installedView = objc_getAssociatedObject(
        cell, AMEditorOtherCategoryBackgroundKey);
    [installedView removeFromSuperview];
    objc_setAssociatedObject(cell, AMEditorOtherCategoryBackgroundKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void AMEditorCustomizeCategoryCell(UICollectionViewCell *cell,
                                          UICollectionView *collectionView,
                                          NSIndexPath *indexPath) {
    (void)collectionView;
    (void)indexPath;
    if (!AMEditorIsOtherCategoryCell(cell)) {
        AMEditorRemoveOtherCategoryBackground(cell);
        return;
    }

    UIImage *image = AMEditorOtherCategoryImage();
    if (!image) return;

    UIImageView *installedView = objc_getAssociatedObject(
        cell, AMEditorOtherCategoryBackgroundKey);
    if (installedView.superview) {
        installedView.image = image;
        installedView.frame = installedView.superview.bounds;
        return;
    }
    if (installedView) {
        objc_setAssociatedObject(cell, AMEditorOtherCategoryBackgroundKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

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

static void AMEditorCategoryCellLayout(id self, SEL selector) {
    if (AMEditorOriginalCategoryCellLayout) {
        AMEditorOriginalCategoryCellLayout(self, selector);
    }
    if ([self isKindOfClass:UICollectionViewCell.class]) {
        AMEditorCustomizeCategoryCell((UICollectionViewCell *)self, nil, nil);
    }
}

static void AMEditorEffectPickerMainCellLayout(id self, SEL selector) {
    if (AMEditorOriginalEffectPickerMainCellLayout) {
        AMEditorOriginalEffectPickerMainCellLayout(self, selector);
    }
    if ([self isKindOfClass:UICollectionViewCell.class]) {
        AMEditorCustomizeCategoryCell((UICollectionViewCell *)self, nil, nil);
    }
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

static void AMEditorInstallCategoryCellCustomization(void) {
    Class cls = AMEditorCategoryCellClass();
    SEL selector = @selector(layoutSubviews);
    Method method = class_getInstanceMethod(cls, selector);
    if (!cls || !method || method_getNumberOfArguments(method) != 2) return;

    IMP original = method_getImplementation(method);
    if (original == (IMP)AMEditorCategoryCellLayout) return;
    const char *types = method_getTypeEncoding(method);
    if (!types) return;

    AMEditorOriginalCategoryCellLayout = (void *)original;
    if (!class_addMethod(cls, selector, (IMP)AMEditorCategoryCellLayout, types)) {
        method_setImplementation(method, (IMP)AMEditorCategoryCellLayout);
    }
}

static void AMEditorInstallEffectPickerMainCellCustomization(void) {
    Class cls = AMEditorEffectPickerMainCellClass();
    SEL selector = @selector(layoutSubviews);
    Method method = class_getInstanceMethod(cls, selector);
    if (!cls || !method || method_getNumberOfArguments(method) != 2) return;

    IMP original = method_getImplementation(method);
    if (original == (IMP)AMEditorEffectPickerMainCellLayout) return;
    const char *types = method_getTypeEncoding(method);
    if (!types) return;

    AMEditorOriginalEffectPickerMainCellLayout = (void *)original;
    if (!class_addMethod(cls, selector,
                         (IMP)AMEditorEffectPickerMainCellLayout, types)) {
        method_setImplementation(method,
                                 (IMP)AMEditorEffectPickerMainCellLayout);
    }
}

static void AMEditorInstallEffectGroupLoginGate(void) {
    Class cls = AMEditorEffectGroupControllerClass();
    SEL selector = @selector(tableView:didSelectRowAtIndexPath:);
    Method method = class_getInstanceMethod(cls, selector);
    if (!cls || !method || method_getNumberOfArguments(method) != 4) return;

    IMP original = method_getImplementation(method);
    if (original == (IMP)AMEditorEffectGroupSelection) return;
    const char *types = method_getTypeEncoding(method);
    if (!types) return;

    AMEditorOriginalEffectGroupSelection = (void *)original;
    if (!class_addMethod(cls, selector, (IMP)AMEditorEffectGroupSelection,
                         types)) {
        method_setImplementation(method, (IMP)AMEditorEffectGroupSelection);
    }
}

static void AMEditorInstallEffectPanelPresetLoginGate(void) {
    Class cls = AMEditorEffectPickerPanelContentClass();
    SEL selector = @selector(tableView:didSelectRowAtIndexPath:);
    Method method = class_getInstanceMethod(cls, selector);
    if (!cls || !method || method_getNumberOfArguments(method) != 4) return;

    IMP original = method_getImplementation(method);
    if (original == (IMP)AMEditorEffectPanelPresetSelection) return;
    const char *types = method_getTypeEncoding(method);
    if (!types) return;

    AMEditorOriginalEffectPanelPresetSelection = (void *)original;
    if (!class_addMethod(cls, selector,
                         (IMP)AMEditorEffectPanelPresetSelection, types)) {
        method_setImplementation(method,
                                 (IMP)AMEditorEffectPanelPresetSelection);
    }
}

static void AMEditorInstallEffectPersistLoginGate(void) {
    Class cls = AMEditorEffectPickerPersistCollectionClass();
    SEL selector = @selector(collectionView:didSelectItemAtIndexPath:);
    Method method = class_getInstanceMethod(cls, selector);
    if (!cls || !method || method_getNumberOfArguments(method) != 4) return;

    IMP original = method_getImplementation(method);
    if (original == (IMP)AMEditorEffectPersistSelection) return;
    const char *types = method_getTypeEncoding(method);
    if (!types) return;

    AMEditorOriginalEffectPersistSelection = (void *)original;
    if (!class_addMethod(cls, selector, (IMP)AMEditorEffectPersistSelection,
                         types)) {
        method_setImplementation(method, (IMP)AMEditorEffectPersistSelection);
    }
}

static void AMEditorInstallEffectCategoryLoginGate(void) {
    Class cls = AMEditorEffectPickerCategoryClass();
    SEL selector = @selector(collectionView:didSelectItemAtIndexPath:);
    Method method = class_getInstanceMethod(cls, selector);
    if (!cls || !method || method_getNumberOfArguments(method) != 4) return;

    IMP original = method_getImplementation(method);
    if (original == (IMP)AMEditorEffectCategorySelection) return;
    const char *types = method_getTypeEncoding(method);
    if (!types) return;

    AMEditorOriginalEffectCategorySelection = (void *)original;
    if (!class_addMethod(cls, selector, (IMP)AMEditorEffectCategorySelection,
                         types)) {
        method_setImplementation(method, (IMP)AMEditorEffectCategorySelection);
    }
}

static void AMEditorInstallEffectRecommendLoginGate(void) {
    Class cls = AMEditorEffectPickerRecommendCollectionClass();
    SEL selector = @selector(collectionView:didSelectItemAtIndexPath:);
    Method method = class_getInstanceMethod(cls, selector);
    if (!cls || !method || method_getNumberOfArguments(method) != 4) return;

    IMP original = method_getImplementation(method);
    if (original == (IMP)AMEditorEffectRecommendSelection) return;
    const char *types = method_getTypeEncoding(method);
    if (!types) return;

    AMEditorOriginalEffectRecommendSelection = (void *)original;
    if (!class_addMethod(cls, selector, (IMP)AMEditorEffectRecommendSelection,
                         types)) {
        method_setImplementation(method, (IMP)AMEditorEffectRecommendSelection);
    }
}

static void AMEditorInstallEffectSearchLoginGate(void) {
    Class cls = AMEditorEffectPickerSearchClass();
    SEL selector = @selector(collectionView:didSelectItemAtIndexPath:);
    Method method = class_getInstanceMethod(cls, selector);
    if (!cls || !method || method_getNumberOfArguments(method) != 4) return;

    IMP original = method_getImplementation(method);
    if (original == (IMP)AMEditorEffectSearchSelection) return;
    const char *types = method_getTypeEncoding(method);
    if (!types) return;

    AMEditorOriginalEffectSearchSelection = (void *)original;
    if (!class_addMethod(cls, selector, (IMP)AMEditorEffectSearchSelection,
                         types)) {
        method_setImplementation(method, (IMP)AMEditorEffectSearchSelection);
    }
}

void AMEditorCustomizationInstall(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        AMEditorInstallProjectEditCustomization();
        AMEditorInstallEffectBrowserCustomization();
        AMEditorInstallCategoryCellCustomization();
        AMEditorInstallEffectPickerMainCellCustomization();
        AMEditorInstallEffectGroupLoginGate();
        AMEditorInstallEffectPanelPresetLoginGate();
        AMEditorInstallEffectPersistLoginGate();
        AMEditorInstallEffectCategoryLoginGate();
        AMEditorInstallEffectRecommendLoginGate();
        AMEditorInstallEffectSearchLoginGate();
    });
}
