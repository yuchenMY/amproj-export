/**
 * AMProjTransform3D.h — 崩溃安全的 3D 变换数学（空对象 3D 父级控制器）
 *
 * 与 empty3d/mat3d.py 的语义保持一致（需求 6：矩阵计算、坐标转换、
 * 父子层级绝不因空指针、除零、越界、NaN/Inf 崩溃）：
 *
 *   - 屏幕坐标：原点左上，X 右、Y 下，Z 向观众为正（AM 2.5D 堆叠语义）
 *   - 矩阵：4x4 column-major，向量为列向量（v' = M * v）
 *   - 角度：度；正角 = 从轴正端看向原点为顺时针（与 AM 现有 2D rotation 一致）
 *   - 欧拉顺序：XYZ（R = Rz * Ry * Rx）；仅 rz 非零时退化为 2D 旋转矩阵
 *   - 安全：NaN/Inf 输入钳制；缩放 0 钳制到 ±1e-4；奇异矩阵求逆返回 0
 *
 * 纯 C 实现，无 UIKit 依赖，可在 macOS 上编译并由
 * tests/AMProjTransform3DSmoke.m 直接单元验证（GitHub Actions）。
 */

#ifndef AMProjTransform3D_h
#define AMProjTransform3D_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 数值安全常量（与 empty3d/mat3d.py 一致） */
#define AMPROJ3D_EPS          1e-9
#define AMPROJ3D_MAX_ABS      1e9
#define AMPROJ3D_MAX_COORD    1e7
#define AMPROJ3D_MAX_SCALE    1e5
#define AMPROJ3D_MIN_SCALE    1e-4
#define AMPROJ3D_MAX_ANGLE    1e7
#define AMPROJ3D_INV_EPS      1e-15

typedef struct {
    double x, y, z;
} AMProj3DVec3;

/* column-major 4x4：m[col*4 + row] */
typedef struct {
    double m[16];
} AMProj3DMat4;

/* ---------- 数值安全 ---------- */

/* 把任意输入归一为 [lo, hi]：NaN -> fallback，±Inf -> ±边界，越界钳制 */
double amproj3d_clampFinite(double v, double lo, double hi, double fallback);

/* 是否有限 */
bool amproj3d_isFinite(double v);
bool amproj3d_vec3Finite(AMProj3DVec3 v);

/* 从任意来源解析三元组（字符串 "x,y,z" / 数组 / 数值），失败返回 0 */
int amproj3d_parseVec3(const void *value, AMProj3DVec3 *out);

/* 格式化 "%.6f,%.6f,%.6f" 到 buf（与 empty3d 序列化格式一致），返回 buf */
char *amproj3d_formatVec3(AMProj3DVec3 v, char buf[64]);

/* ---------- 构造 ---------- */

AMProj3DMat4 amproj3d_identity(void);
AMProj3DMat4 amproj3d_translation(double x, double y, double z);
AMProj3DMat4 amproj3d_scale(double x, double y, double z);
AMProj3DMat4 amproj3d_rotationX(double deg);
AMProj3DMat4 amproj3d_rotationY(double deg);
AMProj3DMat4 amproj3d_rotationZ(double deg);
AMProj3DMat4 amproj3d_eulerXYZ(double rx, double ry, double rz);
AMProj3DMat4 amproj3d_composeTRS(AMProj3DVec3 t, AMProj3DVec3 r, AMProj3DVec3 s);

/* ---------- 运算 ---------- */

/* C = A * B（先应用 B 再应用 A） */
AMProj3DMat4 amproj3d_multiply(AMProj3DMat4 a, AMProj3DMat4 b);

/* 变换点（w=1，含平移）；透视除零用 EPS 保护 */
AMProj3DVec3 amproj3d_transformPoint(AMProj3DMat4 m, AMProj3DVec3 v);

/* 求逆：|det| < AMPROJ3D_INV_EPS 返回 false（调用方退化为单位阵），不崩溃 */
bool amproj3d_inverse(AMProj3DMat4 m, AMProj3DMat4 *out);

/* 安全求逆：失败时输出单位阵，恒返回 true */
bool amproj3d_safeInverse(AMProj3DMat4 m, AMProj3DMat4 *out);

#ifdef __cplusplus
}
#endif

#endif /* AMProjTransform3D_h */
