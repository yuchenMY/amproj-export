/**
 * AM3DTransform3D.h — AM3D 独立 3D 数学模块（崩溃安全）。
 *
 * 与 empty3d/mat3d.py 语义一致：
 *   - 屏幕坐标：原点左上，X 右、Y 下，Z 向观众为正
 *   - 矩阵：4x4 column-major（v' = M * v）
 *   - 角度：度；正角 = 从轴正端看向原点为顺时针（与 AM 2D rotation 一致）
 *   - 欧拉顺序 XYZ（R = Rz * Ry * Rx）
 *   - 安全：NaN/Inf 钳制；缩放 0 钳到 ±1e-4；奇异逆返回 false
 *
 * 本模块完全独立，不依赖 AMProjExport / AmHomeUI 的任何代码。
 */

#ifndef AM3DTransform3D_h
#define AM3DTransform3D_h

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AM3D_EPS        1e-9
#define AM3D_MAX_ABS    1e9
#define AM3D_MAX_COORD  1e7
#define AM3D_MAX_SCALE  1e5
#define AM3D_MIN_SCALE  1e-4
#define AM3D_MAX_ANGLE  1e7
#define AM3D_INV_EPS    1e-15

typedef struct {
    double x, y, z;
} AM3DVec3;

/* column-major 4x4 */
typedef struct {
    double m[16];
} AM3DMat4;

/* ---------- 数值安全 ---------- */
double am3d_clampFinite(double v, double lo, double hi, double fallback);
bool   am3d_isFinite(double v);
bool   am3d_vec3Finite(AM3DVec3 v);
int    am3d_parseVec3(const void *value, AM3DVec3 *out);   /* 字符串/数组/数值 */
char  *am3d_formatVec3(AM3DVec3 v, char buf[64]);

/* ---------- 构造 ---------- */
AM3DMat4 am3d_identity(void);
AM3DMat4 am3d_translation(double x, double y, double z);
AM3DMat4 am3d_scale(double x, double y, double z);
AM3DMat4 am3d_rotationX(double deg);
AM3DMat4 am3d_rotationY(double deg);
AM3DMat4 am3d_rotationZ(double deg);
AM3DMat4 am3d_eulerXYZ(double rx, double ry, double rz);
AM3DMat4 am3d_composeTRS(AM3DVec3 t, AM3DVec3 r, AM3DVec3 s);

/* ---------- 运算 ---------- */
AM3DMat4 am3d_multiply(AM3DMat4 a, AM3DMat4 b);
AM3DVec3 am3d_transformPoint(AM3DMat4 m, AM3DVec3 v);
bool     am3d_inverse(AM3DMat4 m, AM3DMat4 *out);   /* 奇异返回 false */
bool     am3d_safeInverse(AM3DMat4 m, AM3DMat4 *out);

/* ---------- CoreAnimation 桥接 ---------- */
/* 把 AM3DMat4 转成 CATransform3D（column-major 一一对应）。
   需要 QuartzCore；不链接 QuartzCore 的纯测试目标可用
   am3d_mat4ToFloat16 替代。 */
void am3d_mat4ToFloat16(AM3DMat4 m, float out[16]);

#ifdef __cplusplus
}
#endif

#endif /* AM3DTransform3D_h */
