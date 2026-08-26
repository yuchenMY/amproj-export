/**
 * AMProjTransform3DSmoke.m — AMProjTransform3D 数学模块的单元冒烟测试。
 *
 * 在 macOS 上编译运行（GitHub Actions）：
 *   clang -fobjc-arc -framework Foundation \
 *     -IAMProjExport AMProjExport/AMProjTransform3D.m \
 *     tests/AMProjTransform3DSmoke.m -o amproj3d-smoke && ./amproj3d-smoke
 *
 * 断言与 empty3d/tests/test_mat3d.py、test_hierarchy.py 一致：
 * 2D 退化、正交性、TRS 合成、奇异/除零/NaN 安全、序列化格式。
 */

#import <Foundation/Foundation.h>
#import <math.h>
#import <string.h>

#import "AMProjTransform3D.h"

static int g_failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { \
        g_failures++; \
        NSLog(@"FAIL: %s (%s:%d)", msg, __FILE__, __LINE__); \
    } \
} while (0)

#define CHECK_NEAR(a, b, tol, msg) do { \
    double _a = (a), _b = (b); \
    if (fabs(_a - _b) > (tol)) { \
        g_failures++; \
        NSLog(@"FAIL: %s  (%.9g != %.9g tol %.1g) (%s:%d)", msg, _a, _b, (double)(tol), __FILE__, __LINE__); \
    } \
} while (0)

static BOOL matClose(AMProj3DMat4 a, AMProj3DMat4 b, double tol) {
    for (int i = 0; i < 16; i++) {
        if (fabs(a.m[i] - b.m[i]) > tol) return NO;
    }
    return YES;
}

static void testRotationZMatches2D(void) {
    /* AM 2D rotation：顺时针为正（y 向下），Rz(45) 把 (1,0) 送到右下 */
    AMProj3DVec3 p = {1.0, 0.0, 0.0};
    AMProj3DVec3 r = amproj3d_transformPoint(amproj3d_rotationZ(45.0), p);
    CHECK_NEAR(r.x, cos(M_PI / 4.0), 1e-9, "Rz(45) x");
    CHECK_NEAR(r.y, sin(M_PI / 4.0), 1e-9, "Rz(45) y");
    CHECK_NEAR(r.z, 0.0, 1e-9, "Rz(45) z");
}

static void testEulerReducesTo2D(void) {
    AMProj3DMat4 e = amproj3d_eulerXYZ(0.0, 0.0, 47.0);
    CHECK(matClose(e, amproj3d_rotationZ(47.0), 1e-9), "euler(0,0,rz) == Rz(rz)");
    AMProj3DMat4 e2 = amproj3d_eulerXYZ(0.0, 0.0, -12.5);
    CHECK(matClose(e2, amproj3d_rotationZ(-12.5), 1e-9), "euler(0,0,-12.5) == Rz(-12.5)");
}

static void testRotationsInvertible(void) {
    AMProj3DMat4 m = amproj3d_eulerXYZ(30.0, -45.0, 120.0);
    AMProj3DMat4 inv;
    CHECK(amproj3d_inverse(m, &inv), "euler matrix invertible");
    AMProj3DMat4 prod = amproj3d_multiply(m, inv);
    CHECK(matClose(prod, amproj3d_identity(), 1e-8), "M * inv(M) == I");
    AMProj3DMat4 prod2 = amproj3d_multiply(inv, m);
    CHECK(matClose(prod2, amproj3d_identity(), 1e-8), "inv(M) * M == I");
}

static void testTRSCompose(void) {
    AMProj3DVec3 t = {100.0, -50.0, 30.0};
    AMProj3DVec3 r = {20.0, -10.0, 45.0};
    AMProj3DVec3 s = {2.0, 3.0, 4.0};
    AMProj3DMat4 m = amproj3d_composeTRS(t, r, s);
    AMProj3DVec3 origin = {0.0, 0.0, 0.0};
    AMProj3DVec3 p = amproj3d_transformPoint(m, origin);
    CHECK_NEAR(p.x, t.x, 1e-8, "TRS origin x");
    CHECK_NEAR(p.y, t.y, 1e-8, "TRS origin y");
    CHECK_NEAR(p.z, t.z, 1e-8, "TRS origin z");
    AMProj3DVec3 u = {1.0, 0.0, 0.0};
    AMProj3DVec3 q = amproj3d_transformPoint(m, u);
    CHECK(fabs(q.x - t.x) > 1.0, "TRS scale applied (x)");
}

static void testSafety(void) {
    /* 奇异矩阵：inverse 返回 false，safeInverse 退化为单位阵 */
    AMProj3DMat4 singular = {{1,0,0,0, 0,1,0,0, 0,0,0,0, 0,0,0,0}};
    AMProj3DMat4 inv;
    CHECK(!amproj3d_inverse(singular, &inv), "singular inverse rejected");
    CHECK(amproj3d_safeInverse(singular, &inv), "safeInverse returns true");
    CHECK(matClose(inv, amproj3d_identity(), 1e-12), "safeInverse identity fallback");

    /* 0 缩放被钳制：可逆且不崩溃 */
    AMProj3DMat4 zs = amproj3d_scale(0.0, 0.0, 0.0);
    CHECK(amproj3d_inverse(zs, &inv), "zero scale clamped -> invertible");

    /* NaN/Inf 输入安全归一 */
    AMProj3DMat4 bad = amproj3d_translation(NAN, INFINITY, -INFINITY);
    BOOL finite = YES;
    for (int i = 0; i < 16; i++) {
        if (!amproj3d_isFinite(bad.m[i])) finite = NO;
    }
    CHECK(finite, "NaN/Inf translation clamped finite");

    /* w 除零保护 */
    AMProj3DMat4 w0 = {{1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,0}};
    AMProj3DVec3 v = {5.0, 6.0, 7.0};
    AMProj3DVec3 o = amproj3d_transformPoint(w0, v);
    CHECK(amproj3d_vec3Finite(o), "zero-w transform point finite");
}

static void testParseVec3(void) {
    AMProj3DVec3 v;
    CHECK(amproj3d_parseVec3((__bridge void *)@"1,2,3", &v), "parse '1,2,3'");
    CHECK_NEAR(v.x, 1.0, 1e-12, "parse x"); CHECK_NEAR(v.y, 2.0, 1e-12, "parse y");
    CHECK_NEAR(v.z, 3.0, 1e-12, "parse z");
    CHECK(amproj3d_parseVec3((__bridge void *)@"5", &v), "parse single -> [v,v,v]");
    CHECK_NEAR(v.x, 5.0, 1e-12, "single x"); CHECK_NEAR(v.y, 5.0, 1e-12, "single y");
    CHECK_NEAR(v.z, 5.0, 1e-12, "single z");
    CHECK(amproj3d_parseVec3((__bridge void *)@[ @1, @2 ], &v), "parse array [1,2]");
    CHECK_NEAR(v.z, 0.0, 1e-12, "array z default");
    CHECK(!amproj3d_parseVec3((__bridge void *)@"a,b,c", &v), "parse garbage rejected");
    CHECK(!amproj3d_parseVec3((__bridge void *)@"1,2,3,4", &v), "parse 4 parts rejected");
    CHECK(!amproj3d_parseVec3(NULL, &v), "parse NULL rejected");
    CHECK(!amproj3d_parseVec3((__bridge void *)@(NAN), &v), "parse NaN rejected");
}

static void testFormatVec3(void) {
    char buf[64];
    AMProj3DVec3 v = {15.0, -30.0, 45.0};
    amproj3d_formatVec3(v, buf);
    CHECK(strcmp(buf, "15.000000,-30.000000,45.000000") == 0, "format 6 decimals");
    AMProj3DVec3 bad = {NAN, INFINITY, 1.0};
    amproj3d_formatVec3(bad, buf);
    CHECK(strstr(buf, "nan") == NULL && strstr(buf, "inf") == NULL, "format clamps bad values");
}

int main(void) {
    @autoreleasepool {
        testRotationZMatches2D();
        testEulerReducesTo2D();
        testRotationsInvertible();
        testTRSCompose();
        testSafety();
        testParseVec3();
        testFormatVec3();
        if (g_failures) {
            NSLog(@"AMProjTransform3DSmoke: %d FAILURES", g_failures);
            return 1;
        }
        NSLog(@"AMProjTransform3DSmoke: all passed");
        return 0;
    }
}
