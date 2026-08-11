#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^AMCloudPluginsCommitGuard)(dispatch_block_t commit);

/** 更新当前认证代次。代次不一致时，已安装资源会立即停止对 Bundle 可见。 */
FOUNDATION_EXPORT void AMCloudPluginsSetAuthorizationGeneration(uint64_t generation);

/**
 安装主 Bundle 资源 Hook，并仅恢复与当前 token 指纹匹配的已安装版本。
 该函数应在主线程调用，重复调用不会重复安装 Hook。
 */
FOUNDATION_EXPORT void AMCloudPluginsInstallBundleHooks(NSString *authorizationKey);

/** 返回当前认证代次内可见的插件状态；无可用版本时返回 nil。 */
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable AMCloudPluginsCurrentState(void);

/**
 在专用串行队列中校验并解压插件包。最终目录移动、状态写入和内存激活
 由 commitGuard 包裹执行，调用方必须在同一认证事务内校验 token 与代次。
 该函数同步阻塞调用线程；失败时不会激活 staging 内容。
 */
FOUNDATION_EXPORT BOOL AMCloudPluginsInstallArchive(
    NSURL *archiveURL, NSString *releaseID, NSString *sha256,
    NSString *authorizationKey, uint64_t authorizationGeneration,
    AMCloudPluginsCommitGuard commitGuard,
    NSError * _Nullable * _Nullable error);

/**
 在插件串行队列中重新执行 validator，仅条件仍成立时清理全部插件。
 返回 YES 表示执行了清理。该函数同步阻塞调用线程。
 */
FOUNDATION_EXPORT BOOL AMCloudPluginsRemoveAllIf(BOOL (^ _Nullable validator)(void));

/** 无条件清理全部插件。该函数同步阻塞调用线程。 */
FOUNDATION_EXPORT void AMCloudPluginsRemoveAll(void);

NS_ASSUME_NONNULL_END
