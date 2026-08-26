/**
 * AM3DTransform3D.m — 见 AM3DTransform3D.h。
 *
 * 数学与 empty3d/mat3d.py 一一对应（列主序、欧拉 XYZ、顺时针为正、
 * 全部输入钳制），确保离线模型（Python）与设备端（dylib）一致。
 * 完全独立，不依赖 AMProjExport / AmHomeUI。
 */

#import "AM3DTransform3D.h"

#import <Foundation/Foundation.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#pragma mark - 数值安全

double am3d_clampFinite(double v, double lo, double hi, double fallback) {
    if (isnan(v)) return fallback;
    if (isinf(v)) return v > 0 ? hi : lo;
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

bool am3d_isFinite(double v) {
    return !isnan(v) && !isinf(v);
}

bool am3d_vec3Finite(AM3DVec3 v) {
    return am3d_isFinite(v.x) && am3d_isFinite(v.y) && am3d_isFinite(v.z);
}

static double am3d_clampCoord(double v) {
    return am3d_clampFinite(v, -AM3D_MAX_COORD, AM3D_MAX_COORD, 0.0);
}

static double am3d_clampAngle(double v) {
    return am3d_clampFinite(v, -AM3D_MAX_ANGLE, AM3D_MAX_ANGLE, 0.0);
}

static double am3d_clampScale(double v) {
    double s = am3d_clampFinite(v, -AM3D_MAX_SCALE, AM3D_MAX_SCALE, 1.0);
    if (fabs(s) < AM3D_MIN_SCALE) s = s < 0 ? -AM3D_MIN_SCALE : AM3D_MIN_SCALE;
    return s;
}

int am3d_parseVec3(const void *value, AM3DVec3 *out) {
    if (!out) return 0;
    out->x = out->y = out->z = 0.0;
    if (!value) return 0;

    id obj = (__bridge id)value;
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)obj;
        NSArray<NSString *> *parts = [s componentsSeparatedByString:@","];
        if (parts.count < 1 || parts.count > 3) return 0;
        double vals[3] = {0.0, 0.0, 0.0};
        for (NSUInteger i = 0; i < parts.count; i++) {
            NSString *p = [parts[i] stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            /* doubleValue 对非数字返回 0 而非报错：用 NSScanner 严格校验 */
            NSScanner *scanner = [NSScanner scannerWithString:p];
            double v = 0.0;
            if (![scanner scanDouble:&v] || ![scanner isAtEnd]) return 0;
            if (!am3d_isFinite(v)) return 0;
            vals[i] = v;
        }
        out->x = vals[0];
        out->y = parts.count >= 2 ? vals[1] : vals[0];
        out->z = parts.count >= 3 ? vals[2] : (parts.count >= 2 ? 0.0 : vals[0]);
        return 1;
    }

    if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *a = (NSArray *)obj;
        if (a.count < 1 || a.count > 3) return 0;
        double vals[3] = {0.0, 0.0, 0.0};
        for (NSUInteger i = 0; i < a.count; i++) {
            NSNumber *n = a[i];
            if (![n isKindOfClass:[NSNumber class]]) return 0;
            vals[i] = n.doubleValue;
            if (!am3d_isFinite(vals[i])) return 0;
        }
        out->x = vals[0];
        out->y = a.count >= 2 ? vals[1] : vals[0];
        out->z = a.count >= 3 ? vals[2] : (a.count >= 2 ? 0.0 : vals[0]);
        return 1;
    }

    if ([obj isKindOfClass:[NSNumber class]]) {
        double v = [(NSNumber *)obj doubleValue];
        if (!am3d_isFinite(v)) return 0;
        out->x = out->y = out->z = v;
        return 1;
    }

    return 0;
}

char *am3d_formatVec3(AM3DVec3 v, char buf[64]) {
    if (!buf) return NULL;
    snprintf(buf, 64, "%.6f,%.6f,%.6f",
             am3d_clampCoord(v.x), am3d_clampCoord(v.y), am3d_clampCoord(v.z));
    return buf;
}

#pragma mark - 构造

static AM3DMat4 am3d_make(const double m[16]) {
    AM3DMat4 out;
    memcpy(out.m, m, sizeof(out.m));
    return out;
}

AM3DMat4 am3d_identity(void) {
    const double m[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
    return am3d_make(m);
}

AM3DMat4 am3d_translation(double x, double y, double z) {
    const double m[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0,
        am3d_clampCoord(x), am3d_clampCoord(y), am3d_clampCoord(z), 1};
    return am3d_make(m);
}

AM3DMat4 am3d_scale(double x, double y, double z) {
    const double m[16] = {am3d_clampScale(x),0,0,0,
                          0,am3d_clampScale(y),0,0,
                          0,0,am3d_clampScale(z),0,
                          0,0,0,1};
    return am3d_make(m);
}

static double am3d_deg2rad(double deg) {
    return am3d_clampAngle(deg) * (M_PI / 180.0);
}

AM3DMat4 am3d_rotationX(double deg) {
    double a = am3d_deg2rad(deg), c = cos(a), s = sin(a);
    const double m[16] = {1,0,0,0, 0,c,s,0, 0,-s,c,0, 0,0,0,1};
    return am3d_make(m);
}

AM3DMat4 am3d_rotationY(double deg) {
    double a = am3d_deg2rad(deg), c = cos(a), s = sin(a);
    const double m[16] = {c,0,-s,0, 0,1,0,0, s,0,c,0, 0,0,0,1};
    return am3d_make(m);
}

AM3DMat4 am3d_rotationZ(double deg) {
    double a = am3d_deg2rad(deg), c = cos(a), s = sin(a);
    const double m[16] = {c,s,0,0, -s,c,0,0, 0,0,1,0, 0,0,0,1};
    return am3d_make(m);
}

AM3DMat4 am3d_eulerXYZ(double rx, double ry, double rz) {
    /* R = Rz * Ry * Rx */
    return am3d_multiply(am3d_rotationZ(rz),
                         am3d_multiply(am3d_rotationY(ry), am3d_rotationX(rx)));
}

AM3DMat4 am3d_composeTRS(AM3DVec3 t, AM3DVec3 r, AM3DVec3 s) {
    AM3DMat4 m = am3d_scale(s.x, s.y, s.z);
    m = am3d_multiply(am3d_eulerXYZ(r.x, r.y, r.z), m);
    m = am3d_multiply(am3d_translation(t.x, t.y, t.z), m);
    return m;
}

#pragma mark - 运算

AM3DMat4 am3d_multiply(AM3DMat4 a, AM3DMat4 b) {
    AM3DMat4 out;
    for (int c = 0; c < 4; c++) {
        for (int r = 0; r < 4; r++) {
            double v = 0.0;
            for (int k = 0; k < 4; k++) v += a.m[k * 4 + r] * b.m[c * 4 + k];
            out.m[c * 4 + r] = am3d_clampFinite(v, -AM3D_MAX_ABS, AM3D_MAX_ABS, 0.0);
        }
    }
    return out;
}

AM3DVec3 am3d_transformPoint(AM3DMat4 m, AM3DVec3 v) {
    double x = am3d_clampCoord(v.x), y = am3d_clampCoord(v.y), z = am3d_clampCoord(v.z);
    double w = m.m[3] * x + m.m[7] * y + m.m[11] * z + m.m[15];
    if (fabs(w) < AM3D_EPS) w = AM3D_EPS;
    AM3DVec3 out = {
        (m.m[0] * x + m.m[4] * y + m.m[8] * z + m.m[12]) / w,
        (m.m[1] * x + m.m[5] * y + m.m[9] * z + m.m[13]) / w,
        (m.m[2] * x + m.m[6] * y + m.m[10] * z + m.m[14]) / w,
    };
    return out;
}

static double am3d_det3(const AM3DMat4 *a, int i0, int i1, int i2,
                        int j0, int j1, int j2) {
    return (a->m[i0 * 4 + j0] * (a->m[i1 * 4 + j1] * a->m[i2 * 4 + j2] - a->m[i1 * 4 + j2] * a->m[i2 * 4 + j1])
            - a->m[i1 * 4 + j0] * (a->m[i0 * 4 + j1] * a->m[i2 * 4 + j2] - a->m[i0 * 4 + j2] * a->m[i2 * 4 + j1])
            + a->m[i2 * 4 + j0] * (a->m[i0 * 4 + j1] * a->m[i1 * 4 + j2] - a->m[i0 * 4 + j2] * a->m[i1 * 4 + j1]));
}

static double am3d_det(const AM3DMat4 *a) {
    return (a->m[0] * am3d_det3(a, 1, 2, 3, 1, 2, 3)
            - a->m[4] * am3d_det3(a, 0, 2, 3, 1, 2, 3)
            + a->m[8] * am3d_det3(a, 0, 1, 3, 1, 2, 3)
            - a->m[12] * am3d_det3(a, 0, 1, 2, 1, 2, 3));
}

static double am3d_cofactor(const AM3DMat4 *a, int r, int c) {
    int rows[3], cols[3], ri = 0, ci = 0;
    for (int i = 0; i < 4; i++) {
        if (i != r) rows[ri++] = i;
        if (i != c) cols[ci++] = i;
    }
    double p = a->m[rows[0] * 4 + cols[0]] * (a->m[rows[1] * 4 + cols[1]] * a->m[rows[2] * 4 + cols[2]] - a->m[rows[1] * 4 + cols[2]] * a->m[rows[2] * 4 + cols[1]])
             - a->m[rows[1] * 4 + cols[0]] * (a->m[rows[0] * 4 + cols[1]] * a->m[rows[2] * 4 + cols[2]] - a->m[rows[0] * 4 + cols[2]] * a->m[rows[2] * 4 + cols[1]])
             + a->m[rows[2] * 4 + cols[0]] * (a->m[rows[0] * 4 + cols[1]] * a->m[rows[1] * 4 + cols[2]] - a->m[rows[0] * 4 + cols[2]] * a->m[rows[1] * 4 + cols[1]]);
    return ((r + c) % 2) ? -p : p;
}

bool am3d_inverse(AM3DMat4 m, AM3DMat4 *out) {
    if (!out) return false;
    double d = am3d_det(&m);
    if (!am3d_isFinite(d) || fabs(d) < AM3D_INV_EPS) return false;
    for (int c = 0; c < 4; c++) {
        for (int r = 0; r < 4; r++) {
            out->m[c * 4 + r] = am3d_clampFinite(am3d_cofactor(&m, r, c) / d,
                                                 -AM3D_MAX_ABS, AM3D_MAX_ABS, 0.0);
        }
    }
    return true;
}

bool am3d_safeInverse(AM3DMat4 m, AM3DMat4 *out) {
    if (!out) return false;
    if (!am3d_inverse(m, out)) {
        *out = am3d_identity();
    }
    return true;
}

#pragma mark - CoreAnimation 桥接

void am3d_mat4ToFloat16(AM3DMat4 m, float out[16]) {
    if (!out) return;
    for (int i = 0; i < 16; i++) {
        double v = am3d_clampFinite(m.m[i], -AM3D_MAX_ABS, AM3D_MAX_ABS, 0.0);
        out[i] = (float)v;
    }
}
