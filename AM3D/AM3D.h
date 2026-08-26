/**
 * AM3D.h — AM3D 独立 3D dylib 公共接口。
 *
 * AM3D 是完全独立的注入 dylib：在空对象（nullobj）上实现 3D 父级
 * 控制器渲染（真 3D 优先：透视 + XYZ 欧拉旋转；降级：2.5D 合成）。
 * 不依赖也不修改 AMProjExport / AmHomeUI 的任何代码。
 */

#ifndef AM3D_h
#define AM3D_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* 启动/停止渲染桥（+load 自动启动；可显式调用） */
FOUNDATION_EXPORT void AM3DStart(void);
FOUNDATION_EXPORT void AM3DStop(void);

/* 配置（UserDefaults 键，全部可选）：
   AM3DEnabled        BOOL  默认 YES
   AM3DLog            BOOL  默认 YES（[AM3D] 前缀日志）
   AM3DPerspective    float 默认 1100（透视焦距 px，<=0 关闭透视）
   AM3DDemoFallback   BOOL  默认 YES（映射不到真实图层时显示半透明占位演示） */

NS_ASSUME_NONNULL_END

#endif /* AM3D_h */
