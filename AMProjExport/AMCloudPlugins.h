#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^AMCloudPluginsCommitGuard)(dispatch_block_t commit);

/**
 The persisted catalog format. Bump this when the on-disk overlay semantics
 change so a covered IPA install cannot revive an incompatible catalog.
 */
FOUNDATION_EXPORT NSInteger const AMCloudPluginsCatalogProtocolVersion;

/** 更新当前认证代次。代次不一致时，已安装资源会立即停止对 Bundle 可见。 */
FOUNDATION_EXPORT void AMCloudPluginsSetAuthorizationGeneration(uint64_t generation);

/**
 Restores the installed release only when its persisted authorization key
 matches the current Keychain token fingerprint and authorization generation.
 */
FOUNDATION_EXPORT BOOL AMCloudPluginsRestoreInstalledReleaseForAuthorization(
    NSString *authorizationKey, uint64_t authorizationGeneration);

/**
 安装主 Bundle 资源 Hook。该步骤不会从磁盘恢复插件，必须等服务端确认权限后再激活。
 该函数应在主线程调用，重复调用不会重复安装 Hook。
 */
FOUNDATION_EXPORT void AMCloudPluginsInstallBundleHooks(void);

/**
 服务端确认权限和发布版本后，激活同 token 指纹、版本和 SHA-256 的本地插件。
 返回 YES 表示本地版本已经通过校验并对当前认证代次可见。
 */
FOUNDATION_EXPORT BOOL AMCloudPluginsActivateInstalledRelease(
    NSString *releaseID, NSString *sha256, NSString *authorizationKey,
    uint64_t authorizationGeneration);

/** 返回当前认证代次内可见的插件状态；无可用版本时返回 nil。 */
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable AMCloudPluginsCurrentState(void);

/**
 在专用串行队列中校验并解压插件包。最终目录移动、状态写入和内存激活
 由 commitGuard 包裹执行，调用方必须在同一认证事务内校验 token 与代次。
 commitGuard 必须在返回前同步决定是否调用 commit，且不得保存或逃逸 commit；
 重复、并发或在 commitGuard 返回后调用 commit 均不会重复提交。
 commitGuard 返回 YES 表示已允许并调用 commit；返回 NO 时不得调用 commit。
 该函数同步阻塞调用线程；失败时不会激活 staging 内容。
 */
FOUNDATION_EXPORT BOOL AMCloudPluginsInstallArchive(
    NSURL *archiveURL, NSString *releaseID, NSString *sha256,
    NSString *authorizationKey, uint64_t authorizationGeneration,
    AMCloudPluginsCommitGuard commitGuard,
    NSError * _Nullable * _Nullable error);

/**
 安装或替换一个云端插件版本。插件包按 pluginID/versionID 独立保存，成功后不会
 自动改变当前可见目录；调用 AMCloudPluginsActivateCatalog 才会原子切换清单。
 */
FOUNDATION_EXPORT BOOL AMCloudPluginsInstallItemArchive(
    NSURL *archiveURL, NSString *pluginID, NSString *versionID, NSString *sha256,
    NSError * _Nullable * _Nullable error);

/**
 安装带清单元数据的单项插件版本。`kind` 缺省时按 protocol 2 的
 `custom_plugin` 处理；`builtin_override` 必须同时提供官方 `effectId`
 和 `targetPath`，并在激活前与 IPA 内置 BuiltinEffects 清单逐项校验。
 */
FOUNDATION_EXPORT BOOL AMCloudPluginsInstallItemArchiveWithMetadata(
    NSURL *archiveURL, NSString *pluginID, NSString *versionID, NSString *sha256,
    NSDictionary<NSString *, id> * _Nullable metadata,
    NSError * _Nullable * _Nullable error);

/**
 按服务端启用清单重建云端覆盖目录。只会复制清单中的插件；停用插件会从覆盖层
 消失，IPA 原版 BuiltinEffects 始终保留。共享依赖文件内容不一致时拒绝激活。
 */
FOUNDATION_EXPORT BOOL AMCloudPluginsActivateCatalog(
    NSArray<NSDictionary<NSString *, id> *> *plugins, NSNumber *revision,
    NSString *authorizationKey, uint64_t authorizationGeneration,
    AMCloudPluginsCommitGuard commitGuard,
    NSError * _Nullable * _Nullable error);

/**
 在插件串行队列中重新执行 validator，仅条件仍成立时清理全部插件。
 返回 YES 仅表示插件根目录已不存在；返回 NO 表示 validator 已失效或磁盘清理失败。
 只要 validator 通过，内存状态会先失效，磁盘状态也会在删除根目录前禁止冷启动恢复。
 该函数同步阻塞调用线程。
 */
FOUNDATION_EXPORT BOOL AMCloudPluginsRemoveAllIf(BOOL (^ _Nullable validator)(void));

/** 无条件清理全部插件。该函数同步阻塞调用线程。 */
FOUNDATION_EXPORT void AMCloudPluginsRemoveAll(void);

NS_ASSUME_NONNULL_END
