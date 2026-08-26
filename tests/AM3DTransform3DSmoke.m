/**
 * AM3DTransform3DSmoke.m — AM3D 数学模块单元冒烟测试（macOS 可编译运行）。
 *
 *   clang -fobjc-arc -framework Foundation \
 *     -IAM3D AM3D/AM3DTransform3D.m tests/AM3DTransform3DSmoke.m \
 *     -o am3d-smoke && ./am3d-smoke
 *
 * 断言与 empty3d/tests/test_mat3d.py 一致：2D 退化、正交性、TRS 合成、
 * 奇异/除零/NaN 安全、parseVec3 严格校验、格式化。
 */

#import <Foundation/Foundation.h>
#import <math.h>
#import <string.h>

#import "AM3DTransform3D.h"

static int g_failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { g_failures++; NSLog(@"FAIL: %s (%s:%d)", msg, __FILE__, __LINE__); } \
} while (0)

#define CHECK_NEAR(a, b, tol, msg) do { \
    double _a = (a), _b = (b); \
    if (fabs(_a - _b) > (tol)) { \
        g_failures++; \
        NSLog(@"FAIL: %s (%.9g != %.9g)", msg, _a, _b); \
    } \
} while (0)

static BOOL matClose(AM3DMat4 a, AM3DMat4 b, double tol) {
    for (int i = 0; i < 16; i++) {
        if (fabs(a.m[i] - b.m[i]) > tol) return NO;
    }
    return YES;
}

static void testRotationZMatches2D(void) {
    AM3DVec3 p = {1.0, 0.0, 0.0};
    AM3DVec3 r = am3d_transformPoint(am3d_rotationZ(45.0), p);
    CHECK_NEAR(r.x, cos(M_PI / 4.0), 1e-9, "Rz(45) x");
    CHECK_NEAR(r.y, sin(M_PI / 4.0), 1e-9, "Rz(45) y");
    CHECK_NEAR(r.z, 0.0, 1e-9, "Rz(45) z");
}

static void testEulerReducesTo2D(void) {
    CHECK(matClose(am3d_eulerXYZ(0, 0, 47.0), am3d_rotationZ(47.0), 1e-9),
          "euler(0,0,rz) == Rz(rz)");
    CHECK(matClose(am3d_eulerXYZ(0, 0, -12.5), am3d_rotationZ(-12.5), 1e-9),
          "euler(0,0,-12.5) == Rz(-12.5)");
}

static void testInvertible(void) {
    AM3DMat4 m = am3d_eulerXYZ(30.0, -45.0, 120.0);
    AM3DMat4 inv;
    CHECK(am3d_inverse(m, &inv), "euler invertible");
    CHECK(matClose(am3d_multiply(m, inv), am3d_identity(), 1e-8), "M*inv==I");
    CHECK(matClose(am3d_multiply(inv, m), am3d_identity(), 1e-8), "inv*M==I");
}

static void testTRSCompose(void) {
    AM3DVec3 t = {100, -50, 30}, r = {20, -10, 45}, s = {2, 3, 4};
    AM3DMat4 m = am3d_composeTRS(t, r, s);
    AM3DVec3 o = am3d_transformPoint(m, (AM3DVec3){0, 0, 0});
    CHECK_NEAR(o.x, t.x, 1e-8, "TRS origin x");
    CHECK_NEAR(o.y, t.y, 1e-8, "TRS origin y");
    CHECK_NEAR(o.z, t.z, 1e-8, "TRS origin z");
}

static void testSafety(void) {
    AM3DMat4 singular = {{1,0,0,0, 0,1,0,0, 0,0,0,0, 0,0,0,0}};
    AM3DMat4 inv;
    CHECK(!am3d_inverse(singular, &inv), "singular rejected");
    CHECK(am3d_safeInverse(singular, &inv), "safeInverse ok");
    CHECK(matClose(inv, am3d_identity(), 1e-12), "safeInverse identity");
    AM3DMat4 zs = am3d_scale(0, 0, 0);
    CHECK(am3d_inverse(zs, &inv), "zero scale clamped invertible");
    AM3DMat4 bad = am3d_translation(NAN, INFINITY, -INFINITY);
    for (int i = 0; i < 16; i++) CHECK(am3d_isFinite(bad.m[i]), "bad translation finite");
    AM3DMat4 w0 = {{1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,0}};
    AM3DVec3 o = am3d_transformPoint(w0, (AM3DVec3){5, 6, 7});
    CHECK(am3d_vec3Finite(o), "zero-w finite");
}

static void testParseVec3(void) {
    AM3DVec3 v;
    CHECK(am3d_parseVec3((__bridge void *)@"1,2,3", &v), "parse '1,2,3'");
    CHECK_NEAR(v.x, 1.0, 1e-12, "x"); CHECK_NEAR(v.y, 2.0, 1e-12, "y");
    CHECK_NEAR(v.z, 3.0, 1e-12, "z");
    CHECK(am3d_parseVec3((__bridge void *)@"5", &v), "single -> [v,v,v]");
    CHECK_NEAR(v.z, 5.0, 1e-12, "single z");
    CHECK(am3d_parseVec3((__bridge void *)@[ @1, @2 ], &v), "array [1,2]");
    CHECK_NEAR(v.z, 0.0, 1e-12, "array z default");
    CHECK(!am3d_parseVec3((__bridge void *)@"a,b,c", &v), "garbage rejected");
    CHECK(!am3d_parseVec3((__bridge void *)@"1,2,3,4", &v), "4 parts rejected");
    CHECK(!am3d_parseVec3(NULL, &v), "NULL rejected");
    CHECK(!am3d_parseVec3((__bridge void *)@(NAN), &v), "NaN rejected");
    CHECK(!am3d_parseVec3((__bridge void *)@"1.5x", &v), "trailing junk rejected");
}

static void testFormatAndFloat16(void) {
    char buf[64];
    am3d_formatVec3((AM3DVec3){15, -30, 45}, buf);
    CHECK(strcmp(buf, "15.000000,-30.000000,45.000000") == 0, "format 6 decimals");
    float f[16];
    am3d_mat4ToFloat16(am3d_identity(), f);
    CHECK_NEAR(f[0], 1.0f, 1e-6, "float16 identity m00");
    CHECK_NEAR(f[15], 1.0f, 1e-6, "float16 identity m33");
}

int main(void) {
    @autoreleasepool {
        testRotationZMatches2D();
        testEulerReducesTo2D();
        testInvertible();
        testTRSCompose();
        testSafety();
        testParseVec3();
        testFormatAndFloat16();
        if (g_failures) {
            NSLog(@"AM3DTransform3DSmoke: %d FAILURES", g_failures);
            return 1;
        }
        NSLog(@"AM3DTransform3DSmoke: all passed");
        return 0;
    }
}
