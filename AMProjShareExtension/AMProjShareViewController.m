#import "AMProjShareViewController.h"

#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kAMProjShareErrorDomain = @"com.amproj.share-extension";
static NSString *const kAMProjTypeIdentifier = @"com.alightcreative.motion.amproj";
static NSString *const kAMProjAppGroupIdentifier = @"group.com.amayaka.meow.amprojshare";
static NSString *const kAMProjInboxDirectoryName = @"AMProjShareInbox";
static unsigned long long const kAMProjMaximumFileSize = 512ULL * 1024ULL * 1024ULL;
static NSTimeInterval const kAMProjStaleRequestAge = 24.0 * 60.0 * 60.0;

typedef NS_ENUM(NSInteger, AMProjShareErrorCode) {
    AMProjShareErrorInvalidInput = 1,
    AMProjShareErrorUnsupportedFile = 2,
    AMProjShareErrorAppGroupUnavailable = 3,
    AMProjShareErrorCreateDirectory = 4,
    AMProjShareErrorFileTooLarge = 5,
    AMProjShareErrorReadSource = 6,
    AMProjShareErrorWriteDestination = 7,
    AMProjShareErrorCommitPayload = 8,
    AMProjShareErrorWriteDescriptor = 9,
    AMProjShareErrorProviderLoad = 10,
    AMProjShareErrorCancelled = 11,
};

static NSError *AMProjShareError(AMProjShareErrorCode code,
                                 NSString *description,
                                 NSError *_Nullable underlyingError) {
    NSMutableDictionary *userInfo = [@{NSLocalizedDescriptionKey : description} mutableCopy];
    if (underlyingError) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    return [NSError errorWithDomain:kAMProjShareErrorDomain code:code userInfo:userInfo];
}

static NSString *AMProjDescribeError(NSString *step, NSError *error) {
    if (!error) {
        return [NSString stringWithFormat:@"%@：未知错误", step];
    }
    return [NSString stringWithFormat:@"%@：%@/%ld %@",
            step,
            error.domain,
            (long)error.code,
            error.localizedDescription ?: @""];
}

static BOOL AMProjTypeConformsTo(NSString *identifier, NSString *parentIdentifier) {
    if (identifier.length == 0 || parentIdentifier.length == 0) {
        return NO;
    }
    UTType *type = [UTType typeWithIdentifier:identifier];
    UTType *parentType = [UTType typeWithIdentifier:parentIdentifier];
    return type && parentType && [type conformsToType:parentType];
}

@interface AMProjShareViewController ()
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UITextView *messageView;
@property(nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property(nonatomic, strong) UIButton *actionButton;
@property(nonatomic, strong) UIButton *closeButton;
@property(nonatomic, assign) BOOL started;
@property(atomic, assign) BOOL cancelled;
@property(nonatomic, assign) BOOL processing;
@property(nonatomic, copy, nullable) NSString *stagedRequestIdentifier;
@property(nonatomic, strong, nullable) NSURL *deepLinkURL;
@end

@implementation AMProjShareViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.preferredContentSize = CGSizeMake(360.0, 320.0);

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.text = @"导入到 Alight Motion";

    self.activityIndicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;

    self.messageView = [[UITextView alloc] init];
    self.messageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.messageView.backgroundColor = UIColor.clearColor;
    self.messageView.editable = NO;
    self.messageView.selectable = YES;
    self.messageView.scrollEnabled = YES;
    self.messageView.textAlignment = NSTextAlignmentCenter;
    self.messageView.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.messageView.textContainerInset = UIEdgeInsetsMake(8.0, 4.0, 8.0, 4.0);
    self.messageView.text = @"正在检查项目包…";

    self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.actionButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.actionButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [self.actionButton setTitle:@"再次打开 Alight Motion" forState:UIControlStateNormal];
    [self.actionButton addTarget:self
                          action:@selector(actionButtonTapped:)
                forControlEvents:UIControlEventTouchUpInside];
    self.actionButton.hidden = YES;

    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.closeButton setTitle:@"取消" forState:UIControlStateNormal];
    [self.closeButton addTarget:self
                         action:@selector(closeButtonTapped:)
               forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.titleLabel,
        self.activityIndicator,
        self.messageView,
        self.actionButton,
        self.closeButton,
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 12.0;
    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20.0],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20.0],
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20.0],
        [stack.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16.0],
        [self.activityIndicator.heightAnchor constraintEqualToConstant:28.0],
        [self.messageView.heightAnchor constraintGreaterThanOrEqualToConstant:112.0],
        [self.actionButton.heightAnchor constraintEqualToConstant:44.0],
        [self.closeButton.heightAnchor constraintEqualToConstant:40.0],
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.started) {
        return;
    }
    self.started = YES;
    self.processing = YES;
    [self.activityIndicator startAnimating];
    [self beginImport];
}

- (void)beginImport {
    NSMutableArray<NSItemProvider *> *providers = [NSMutableArray array];
    for (id item in self.extensionContext.inputItems) {
        if (![item isKindOfClass:NSExtensionItem.class]) {
            continue;
        }
        for (id attachment in ((NSExtensionItem *)item).attachments) {
            if ([attachment isKindOfClass:NSItemProvider.class]) {
                [providers addObject:attachment];
            }
        }
    }

    if (providers.count != 1) {
        NSError *error = AMProjShareError(
            AMProjShareErrorInvalidInput,
            @"请一次只分享一个 .amproj 文件。",
            nil);
        [self showFailureWithTitle:@"无法读取分享内容" error:error attempts:nil];
        return;
    }

    NSItemProvider *provider = providers.firstObject;
    NSString *typeIdentifier = [self preferredTypeIdentifierForProvider:provider];
    if (typeIdentifier.length == 0) {
        NSError *error = AMProjShareError(
            AMProjShareErrorUnsupportedFile,
            @"分享内容不是可读取的 .amproj 文件。",
            nil);
        [self showFailureWithTitle:@"不支持此文件" error:error attempts:nil];
        return;
    }

    NSString *suggestedExtension = provider.suggestedName.pathExtension.lowercaseString;
    if (suggestedExtension.length > 0 && ![suggestedExtension isEqualToString:@"amproj"]) {
        NSError *error = AMProjShareError(
            AMProjShareErrorUnsupportedFile,
            [NSString stringWithFormat:@"“%@”不是 .amproj 文件。", provider.suggestedName.lastPathComponent],
            nil);
        [self showFailureWithTitle:@"不支持此文件" error:error attempts:nil];
        return;
    }

    [self updateStatusTitle:@"正在复制项目包"
                    message:@"请保持此窗口打开。复制完成前不要返回 QQ。"];

    BOOL hasAMProjType = [provider hasItemConformingToTypeIdentifier:kAMProjTypeIdentifier];
    NSMutableArray<NSString *> *attempts = [NSMutableArray array];
    if ([typeIdentifier isEqualToString:@"public.file-url"]) {
        [self loadItemFromProvider:provider
                   typeIdentifier:typeIdentifier
                hasDeclaredAMProj:hasAMProjType
                         attempts:attempts
                 allowFinalFailure:YES];
        return;
    }

    [self loadFileRepresentationFromProvider:provider
                              typeIdentifier:typeIdentifier
                           hasDeclaredAMProj:hasAMProjType
                                    attempts:attempts];
}

- (nullable NSString *)preferredTypeIdentifierForProvider:(NSItemProvider *)provider {
    NSArray<NSString *> *registered = provider.registeredTypeIdentifiers ?: @[];
    for (NSString *identifier in registered) {
        if ([identifier isEqualToString:kAMProjTypeIdentifier] ||
            AMProjTypeConformsTo(identifier, kAMProjTypeIdentifier)) {
            return identifier;
        }
    }

    NSArray<NSString *> *preferred = @[
        @"com.pkware.zip-archive",
        @"public.zip-archive",
        @"public.archive",
        @"public.data",
        @"public.file-url",
    ];
    for (NSString *identifier in preferred) {
        if ([provider hasItemConformingToTypeIdentifier:identifier]) {
            return identifier;
        }
    }
    for (NSString *identifier in registered) {
        if (AMProjTypeConformsTo(identifier, @"public.data")) {
            return identifier;
        }
    }
    return nil;
}

- (void)loadFileRepresentationFromProvider:(NSItemProvider *)provider
                             typeIdentifier:(NSString *)typeIdentifier
                          hasDeclaredAMProj:(BOOL)hasDeclaredAMProj
                                   attempts:(NSMutableArray<NSString *> *)attempts {
    __weak typeof(self) weakSelf = self;
    [provider loadFileRepresentationForTypeIdentifier:typeIdentifier
                                    completionHandler:^(NSURL *_Nullable url, NSError *_Nullable error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled) {
            return;
        }
        if (url) {
            NSError *stageError = nil;
            NSString *requestIdentifier = [self stageURL:url
                                                provider:provider
                                       hasDeclaredAMProj:hasDeclaredAMProj
                                                   error:&stageError];
            if (requestIdentifier) {
                [self didStageRequest:requestIdentifier];
                return;
            }
            [attempts addObject:AMProjDescribeError(@"loadFileRepresentation", stageError)];
        } else {
            [attempts addObject:AMProjDescribeError(@"loadFileRepresentation", error)];
        }

        [self loadInPlaceRepresentationFromProvider:provider
                                     typeIdentifier:typeIdentifier
                                  hasDeclaredAMProj:hasDeclaredAMProj
                                           attempts:attempts];
    }];
}

- (void)loadInPlaceRepresentationFromProvider:(NSItemProvider *)provider
                                typeIdentifier:(NSString *)typeIdentifier
                             hasDeclaredAMProj:(BOOL)hasDeclaredAMProj
                                      attempts:(NSMutableArray<NSString *> *)attempts {
    __weak typeof(self) weakSelf = self;
    [provider loadInPlaceFileRepresentationForTypeIdentifier:typeIdentifier
                                           completionHandler:^(NSURL *_Nullable url,
                                                               BOOL isInPlace,
                                                               NSError *_Nullable error) {
        (void)isInPlace;
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled) {
            return;
        }
        if (url) {
            NSError *stageError = nil;
            NSString *requestIdentifier = [self stageURL:url
                                                provider:provider
                                       hasDeclaredAMProj:hasDeclaredAMProj
                                                   error:&stageError];
            if (requestIdentifier) {
                [self didStageRequest:requestIdentifier];
                return;
            }
            [attempts addObject:AMProjDescribeError(@"loadInPlaceRepresentation", stageError)];
        } else {
            [attempts addObject:AMProjDescribeError(@"loadInPlaceRepresentation", error)];
        }

        [self loadItemFromProvider:provider
                   typeIdentifier:typeIdentifier
                hasDeclaredAMProj:hasDeclaredAMProj
                         attempts:attempts
                 allowFinalFailure:YES];
    }];
}

- (void)loadItemFromProvider:(NSItemProvider *)provider
              typeIdentifier:(NSString *)typeIdentifier
           hasDeclaredAMProj:(BOOL)hasDeclaredAMProj
                    attempts:(NSMutableArray<NSString *> *)attempts
            allowFinalFailure:(BOOL)allowFinalFailure {
    __weak typeof(self) weakSelf = self;
    [provider loadItemForTypeIdentifier:typeIdentifier
                                options:nil
                      completionHandler:^(id<NSSecureCoding> _Nullable item, NSError *_Nullable error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled) {
            return;
        }

        NSError *stageError = nil;
        NSString *requestIdentifier = nil;
        if ([(id)item isKindOfClass:NSURL.class]) {
            requestIdentifier = [self stageURL:(NSURL *)item
                                      provider:provider
                             hasDeclaredAMProj:hasDeclaredAMProj
                                         error:&stageError];
        } else if ([(id)item isKindOfClass:NSData.class]) {
            requestIdentifier = [self stageData:(NSData *)item
                                       provider:provider
                              hasDeclaredAMProj:hasDeclaredAMProj
                                          error:&stageError];
        } else if (item) {
            stageError = AMProjShareError(
                AMProjShareErrorProviderLoad,
                [NSString stringWithFormat:@"文件提供器返回了不支持的类型：%@。",
                 NSStringFromClass([(id)item class])],
                nil);
        } else {
            stageError = error ?: AMProjShareError(
                AMProjShareErrorProviderLoad,
                @"文件提供器没有返回任何内容。",
                nil);
        }

        if (requestIdentifier) {
            [self didStageRequest:requestIdentifier];
            return;
        }
        [attempts addObject:AMProjDescribeError(@"loadItem", stageError ?: error)];

        if (allowFinalFailure) {
            NSError *finalError = AMProjShareError(
                AMProjShareErrorProviderLoad,
                @"无法从 QQ 或文件 App 取得项目包。请将文件保存到“文件”后重试。",
                stageError ?: error);
            [self showFailureWithTitle:@"无法复制 .amproj"
                                  error:finalError
                               attempts:attempts];
        }
    }];
}

- (nullable NSString *)stageURL:(NSURL *)sourceURL
                        provider:(NSItemProvider *)provider
               hasDeclaredAMProj:(BOOL)hasDeclaredAMProj
                           error:(NSError **)error {
    NSString *originalName = [self validatedOriginalNameForProvider:provider
                                                           sourceURL:sourceURL
                                                  hasDeclaredAMProj:hasDeclaredAMProj
                                                              error:error];
    if (!originalName) {
        return nil;
    }

    NSNumber *sourceSize = nil;
    [sourceURL getResourceValue:&sourceSize forKey:NSURLFileSizeKey error:nil];
    if (sourceSize.unsignedLongLongValue > kAMProjMaximumFileSize) {
        if (error) {
            *error = AMProjShareError(
                AMProjShareErrorFileTooLarge,
                @"项目包超过 512 MiB 限制。",
                nil);
        }
        return nil;
    }

    NSString *requestIdentifier = NSUUID.UUID.UUIDString.lowercaseString;
    NSURL *requestDirectory = [self createRequestDirectoryForIdentifier:requestIdentifier error:error];
    if (!requestDirectory) {
        return nil;
    }

    NSURL *partialURL = [requestDirectory URLByAppendingPathComponent:@"payload.amproj.partial"
                                                          isDirectory:NO];
    unsigned long long copiedSize = 0;
    BOOL scoped = [sourceURL startAccessingSecurityScopedResource];
    BOOL copied = [self streamCopyURL:sourceURL
                                toURL:partialURL
                           copiedSize:&copiedSize
                                error:error];
    if (scoped) {
        [sourceURL stopAccessingSecurityScopedResource];
    }

    if (!copied || ![self commitPartialPayload:partialURL
                                  requestDirectory:requestDirectory
                                  requestIdentifier:requestIdentifier
                                        originalName:originalName
                                                size:copiedSize
                                               error:error]) {
        [[NSFileManager defaultManager] removeItemAtURL:requestDirectory error:nil];
        return nil;
    }
    return requestIdentifier;
}

- (nullable NSString *)stageData:(NSData *)data
                         provider:(NSItemProvider *)provider
                hasDeclaredAMProj:(BOOL)hasDeclaredAMProj
                            error:(NSError **)error {
    NSString *originalName = [self validatedOriginalNameForProvider:provider
                                                           sourceURL:nil
                                                  hasDeclaredAMProj:hasDeclaredAMProj
                                                              error:error];
    if (!originalName) {
        return nil;
    }
    if ((unsigned long long)data.length > kAMProjMaximumFileSize) {
        if (error) {
            *error = AMProjShareError(
                AMProjShareErrorFileTooLarge,
                @"项目包超过 512 MiB 限制。",
                nil);
        }
        return nil;
    }

    NSString *requestIdentifier = NSUUID.UUID.UUIDString.lowercaseString;
    NSURL *requestDirectory = [self createRequestDirectoryForIdentifier:requestIdentifier error:error];
    if (!requestDirectory) {
        return nil;
    }

    NSURL *partialURL = [requestDirectory URLByAppendingPathComponent:@"payload.amproj.partial"
                                                          isDirectory:NO];
    NSError *writeError = nil;
    BOOL wrote = [data writeToURL:partialURL options:0 error:&writeError];
    if (!wrote) {
        if (error) {
            *error = AMProjShareError(
                AMProjShareErrorWriteDestination,
                @"无法把项目包写入共享收件箱。",
                writeError);
        }
        [[NSFileManager defaultManager] removeItemAtURL:requestDirectory error:nil];
        return nil;
    }

    if (![self commitPartialPayload:partialURL
                    requestDirectory:requestDirectory
                    requestIdentifier:requestIdentifier
                          originalName:originalName
                                  size:(unsigned long long)data.length
                                 error:error]) {
        [[NSFileManager defaultManager] removeItemAtURL:requestDirectory error:nil];
        return nil;
    }
    return requestIdentifier;
}

- (nullable NSString *)validatedOriginalNameForProvider:(NSItemProvider *)provider
                                               sourceURL:(nullable NSURL *)sourceURL
                                      hasDeclaredAMProj:(BOOL)hasDeclaredAMProj
                                                  error:(NSError **)error {
    NSString *name = provider.suggestedName.lastPathComponent;
    if (name.length == 0) {
        name = sourceURL.lastPathComponent;
    }
    NSString *extension = name.pathExtension.lowercaseString;
    if (extension.length > 0 && ![extension isEqualToString:@"amproj"]) {
        if (error) {
            *error = AMProjShareError(
                AMProjShareErrorUnsupportedFile,
                @"只能导入扩展名为 .amproj 的文件。",
                nil);
        }
        return nil;
    }
    if (extension.length == 0) {
        if (!hasDeclaredAMProj) {
            if (error) {
                *error = AMProjShareError(
                    AMProjShareErrorUnsupportedFile,
                    @"文件提供器没有提供 .amproj 文件名或类型信息。",
                    nil);
            }
            return nil;
        }
        name = name.length > 0 ? [name stringByAppendingPathExtension:@"amproj"] : @"project.amproj";
    }
    return name.lastPathComponent;
}

- (nullable NSURL *)createRequestDirectoryForIdentifier:(NSString *)requestIdentifier
                                                   error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *containerURL = [fileManager
        containerURLForSecurityApplicationGroupIdentifier:kAMProjAppGroupIdentifier];
    if (!containerURL) {
        if (error) {
            *error = AMProjShareError(
                AMProjShareErrorAppGroupUnavailable,
                @"App Group 不可用。请确认主 App 与分享扩展使用相同的签名权限。",
                nil);
        }
        return nil;
    }

    NSURL *inboxURL = [containerURL URLByAppendingPathComponent:kAMProjInboxDirectoryName
                                                    isDirectory:YES];
    NSError *createError = nil;
    if (![fileManager createDirectoryAtURL:inboxURL
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&createError]) {
        if (error) {
            *error = AMProjShareError(
                AMProjShareErrorCreateDirectory,
                @"无法创建共享收件箱。",
                createError);
        }
        return nil;
    }
    [self removeStaleRequestsFromInbox:inboxURL];

    NSURL *requestDirectory = [inboxURL URLByAppendingPathComponent:requestIdentifier
                                                        isDirectory:YES];
    createError = nil;
    if (![fileManager createDirectoryAtURL:requestDirectory
                withIntermediateDirectories:NO
                                 attributes:nil
                                      error:&createError]) {
        if (error) {
            *error = AMProjShareError(
                AMProjShareErrorCreateDirectory,
                @"无法创建本次导入目录。",
                createError);
        }
        return nil;
    }
    return requestDirectory;
}

- (void)removeStaleRequestsFromInbox:(NSURL *)inboxURL {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray<NSURL *> *children = [fileManager contentsOfDirectoryAtURL:inboxURL
                                            includingPropertiesForKeys:@[
                                                NSURLIsDirectoryKey,
                                                NSURLContentModificationDateKey,
                                            ]
                                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                 error:nil];
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-kAMProjStaleRequestAge];
    for (NSURL *child in children) {
        NSNumber *isDirectory = nil;
        NSDate *modified = nil;
        [child getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        [child getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
        if (isDirectory.boolValue && modified && [modified compare:cutoff] == NSOrderedAscending) {
            [fileManager removeItemAtURL:child error:nil];
        }
    }
}

- (BOOL)streamCopyURL:(NSURL *)sourceURL
                 toURL:(NSURL *)destinationURL
            copiedSize:(unsigned long long *)copiedSize
                 error:(NSError **)error {
    NSInputStream *input = [NSInputStream inputStreamWithURL:sourceURL];
    NSOutputStream *output = [NSOutputStream outputStreamToFileAtPath:destinationURL.path append:NO];
    if (!input || !output) {
        if (error) {
            *error = AMProjShareError(
                AMProjShareErrorReadSource,
                @"无法创建文件读写流。",
                nil);
        }
        return NO;
    }

    const NSUInteger bufferSize = 256 * 1024;
    uint8_t *buffer = malloc(bufferSize);
    if (!buffer) {
        if (error) {
            *error = AMProjShareError(
                AMProjShareErrorWriteDestination,
                @"内存不足，无法复制项目包。",
                nil);
        }
        return NO;
    }

    [input open];
    [output open];
    unsigned long long total = 0;
    NSError *failure = nil;
    while (!failure) {
        if (self.cancelled) {
            failure = AMProjShareError(AMProjShareErrorCancelled, @"用户取消了导入。", nil);
            break;
        }
        NSInteger count = [input read:buffer maxLength:bufferSize];
        if (count == 0) {
            break;
        }
        if (count < 0) {
            failure = AMProjShareError(
                AMProjShareErrorReadSource,
                @"读取 QQ 或文件 App 提供的项目包失败。",
                input.streamError);
            break;
        }
        if (total + (unsigned long long)count > kAMProjMaximumFileSize) {
            failure = AMProjShareError(
                AMProjShareErrorFileTooLarge,
                @"项目包超过 512 MiB 限制。",
                nil);
            break;
        }

        NSInteger offset = 0;
        while (offset < count) {
            NSInteger written = [output write:buffer + offset maxLength:(NSUInteger)(count - offset)];
            if (written <= 0) {
                failure = AMProjShareError(
                    AMProjShareErrorWriteDestination,
                    @"写入共享收件箱失败。",
                    output.streamError);
                break;
            }
            offset += written;
        }
        total += (unsigned long long)count;
    }

    [input close];
    [output close];
    free(buffer);

    if (!failure && total == 0) {
        failure = AMProjShareError(
            AMProjShareErrorReadSource,
            @"项目包为空文件。",
            nil);
    }
    if (failure) {
        if (error) {
            *error = failure;
        }
        return NO;
    }
    if (copiedSize) {
        *copiedSize = total;
    }
    return YES;
}

- (BOOL)commitPartialPayload:(NSURL *)partialURL
             requestDirectory:(NSURL *)requestDirectory
             requestIdentifier:(NSString *)requestIdentifier
                   originalName:(NSString *)originalName
                           size:(unsigned long long)size
                          error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *payloadURL = [requestDirectory URLByAppendingPathComponent:@"payload.amproj"
                                                          isDirectory:NO];
    NSError *moveError = nil;
    if (![fileManager moveItemAtURL:partialURL toURL:payloadURL error:&moveError]) {
        if (error) {
            *error = AMProjShareError(
                AMProjShareErrorCommitPayload,
                @"无法原子提交项目包。",
                moveError);
        }
        return NO;
    }

    NSDictionary *descriptor = @{
        @"protocol_version" : @1,
        @"request_id" : requestIdentifier,
        @"original_name" : originalName,
        @"created_at" : [NSDate date],
        @"size" : @(size),
    };
    NSError *plistError = nil;
    NSData *plistData = [NSPropertyListSerialization
        dataWithPropertyList:descriptor
                      format:NSPropertyListXMLFormat_v1_0
                     options:0
                       error:&plistError];
    NSURL *descriptorURL = [requestDirectory URLByAppendingPathComponent:@"request.plist"
                                                              isDirectory:NO];
    if (!plistData ||
        ![plistData writeToURL:descriptorURL options:NSDataWritingAtomic error:&plistError]) {
        if (error) {
            *error = AMProjShareError(
                AMProjShareErrorWriteDescriptor,
                @"项目包已复制，但无法写入导入请求。",
                plistError);
        }
        return NO;
    }
    return YES;
}

- (void)didStageRequest:(NSString *)requestIdentifier {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.cancelled) {
            return;
        }
        self.stagedRequestIdentifier = requestIdentifier;
        NSString *urlString = [NSString stringWithFormat:
            @"alightmotion://amproj-import?request=%@", requestIdentifier];
        self.deepLinkURL = [NSURL URLWithString:urlString];
        self.titleLabel.text = @"项目包已复制";
        self.messageView.text = @"正在打开 Alight Motion…";
        [self openContainingApplication];
    });
}

- (void)openContainingApplication {
    NSURL *url = self.deepLinkURL;
    if (!url || self.cancelled) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    [self.extensionContext openURL:url
                completionHandler:^(BOOL success) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                self.processing = NO;
                [self.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
                return;
            }
            self.processing = NO;
            [self.activityIndicator stopAnimating];
            self.titleLabel.text = @"项目包已保存";
            self.messageView.text =
                @"iOS 没有允许分享扩展自动打开 Alight Motion。\n\n"
                @"请点下方按钮重试；如果仍无反应，请关闭此窗口后手动打开 Alight Motion，"
                @"主 App 会从共享收件箱继续导入。";
            self.actionButton.hidden = NO;
            [self.closeButton setTitle:@"完成" forState:UIControlStateNormal];
        });
    }];
}

- (void)showFailureWithTitle:(NSString *)title
                        error:(NSError *)error
                     attempts:(nullable NSArray<NSString *> *)attempts {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.processing = NO;
        [self.activityIndicator stopAnimating];
        self.titleLabel.text = title;
        NSMutableString *message = [NSMutableString stringWithString:error.localizedDescription ?: @"未知错误"];
        if (attempts.count > 0) {
            [message appendString:@"\n\n诊断：\n"];
            [message appendString:[attempts componentsJoinedByString:@"\n"]];
        } else {
            [message appendFormat:@"\n\n诊断：%@/%ld", error.domain, (long)error.code];
        }
        self.messageView.text = message;
        self.actionButton.hidden = YES;
        [self.closeButton setTitle:@"关闭" forState:UIControlStateNormal];
    });
}

- (void)updateStatusTitle:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.titleLabel.text = title;
        self.messageView.text = message;
        if (self.processing) {
            [self.activityIndicator startAnimating];
        }
    });
}

- (void)actionButtonTapped:(UIButton *)sender {
    (void)sender;
    if (!self.deepLinkURL) {
        return;
    }
    self.processing = YES;
    self.actionButton.hidden = YES;
    [self.closeButton setTitle:@"取消" forState:UIControlStateNormal];
    [self updateStatusTitle:@"正在打开 Alight Motion" message:@"请稍候…"];
    [self openContainingApplication];
}

- (void)closeButtonTapped:(UIButton *)sender {
    (void)sender;
    self.cancelled = YES;
    if (self.processing && !self.stagedRequestIdentifier) {
        NSError *error = AMProjShareError(
            AMProjShareErrorCancelled,
            @"用户取消了导入。",
            nil);
        [self.extensionContext cancelRequestWithError:error];
    } else {
        [self.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
    }
}

@end
