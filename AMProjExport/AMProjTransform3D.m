/**
 * AMProjTransform3D.m — 见 AMProjTransform3D.h。
 *
 * 数学与 empty3d/mat3d.py 一一对应（列主序、欧拉 XYZ、顺时针为正、
 * 全部输入钳制），确保 iOS 侧（dylib）与离线模型（Python）输出一致。
 */

#import "AMProjTransform3D.h"

#import <Foundation/Foundation.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#pragma mark - 数值安全

double amproj3d_clampFinite(double v, double lo, double hi, double fallback) {
    if (isnan(v)) return fallback;
    if (isinf(v)) return v > 0 ? hi : lo;
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

bool amproj3d_isFinite(double v) {
    return !isnan(v) && !isinf(v);
}

bool amproj3d_vec3Finite(AMProj3DVec3 v) {
    return amproj3d_isFinite(v.x) && amproj3d_isFinite(v.y) && amproj3d_isFinite(v.z);
}

static double amproj3d_clampCoord(double v) {
    return amproj3d_clampFinite(v, -AMPROJ3D_MAX_COORD, AMPROJ3D_MAX_COORD, 0.0);
}

static double amproj3d_clampAngle(double v) {
    return amproj3d_clampFinite(v, -AMPROJ3D_MAX_ANGLE, AMPROJ3D_MAX_ANGLE, 0.0);
}

static double amproj3d_clampScale(double v) {
    double s = amproj3d_clampFinite(v, -AMPROJ3D_MAX_SCALE, AMPROJ3D_MAX_SCALE, 1.0);
    if (fabs(s) < AMPROJ3D_MIN_SCALE) s = s < 0 ? -AMPROJ3D_MIN_SCALE : AMPROJ3D_MIN_SCALE;
    return s;
}

int amproj3d_parseVec3(const void *value, AMProj3DVec3 *out) {
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
            // doubleValue 对非数字返回 0.0 而非报错，必须用 NSScanner 严格校验
            NSScanner *scanner = [NSScanner scannerWithString:p];
            double v = 0.0;
            if (![scanner scanDouble:&v] || ![scanner isAtEnd]) return 0;
            if (!amproj3d_isFinite(v)) return 0;
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
            if (!amproj3d_isFinite(vals[i])) return 0;
        }
        out->x = vals[0];
        out->y = a.count >= 2 ? vals[1] : vals[0];
        out->z = a.count >= 3 ? vals[2] : (a.count >= 2 ? 0.0 : vals[0]);
        return 1;
    }

    if ([obj isKindOfClass:[NSNumber class]]) {
        double v = [(NSNumber *)obj doubleValue];
        if (!amproj3d_isFinite(v)) return 0;
        out->x = out->y = out->z = v;
        return 1;
    }

    return 0;
}

char *amproj3d_formatVec3(AMProj3DVec3 v, char buf[64]) {
    if (!buf) return NULL;
    snprintf(buf, 64, "%.6f,%.6f,%.6f",
             amproj3d_clampCoord(v.x), amproj3d_clampCoord(v.y), amproj3d_clampCoord(v.z));
    return buf;
}

#pragma mark - 构造

static AMProj3DMat4 amproj3d_make(const double m[16]) {
    AMProj3DMat4 out;
    memcpy(out.m, m, sizeof(out.m));
    return out;
}

AMProj3DMat4 amproj3d_identity(void) {
    const double m[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
    return amproj3d_make(m);
}

AMProj3DMat4 amproj3d_translation(double x, double y, double z) {
    const double m[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0,
        amproj3d_clampCoord(x), amproj3d_clampCoord(y), amproj3d_clampCoord(z), 1};
    return amproj3d_make(m);
}

AMProj3DMat4 amproj3d_scale(double x, double y, double z) {
    const double m[16] = {amproj3d_clampScale(x),0,0,0,
                          0,amproj3d_clampScale(y),0,0,
                          0,0,amproj3d_clampScale(z),0,
                          0,0,0,1};
    return amproj3d_make(m);
}

static double amproj3d_deg2rad(double deg) {
    return amproj3d_clampAngle(deg) * (M_PI / 180.0);
}

AMProj3DMat4 amproj3d_rotationX(double deg) {
    double a = amproj3d_deg2rad(deg), c = cos(a), s = sin(a);
    const double m[16] = {1,0,0,0, 0,c,s,0, 0,-s,c,0, 0,0,0,1};
    return amproj3d_make(m);
}

AMProj3DMat4 amproj3d_rotationY(double deg) {
    double a = amproj3d_deg2rad(deg), c = cos(a), s = sin(a);
    const double m[16] = {c,0,-s,0, 0,1,0,0, s,0,c,0, 0,0,0,1};
    return amproj3d_make(m);
}

AMProj3DMat4 amproj3d_rotationZ(double deg) {
    double a = amproj3d_deg2rad(deg), c = cos(a), s = sin(a);
    const double m[16] = {c,s,0,0, -s,c,0,0, 0,0,1,0, 0,0,0,1};
    return amproj3d_make(m);
}

AMProj3DMat4 amproj3d_eulerXYZ(double rx, double ry, double rz) {
    /* R = Rz * Ry * Rx */
    return amproj3d_multiply(amproj3d_rotationZ(rz),
                             amproj3d_multiply(amproj3d_rotationY(ry),
                                               amproj3d_rotationX(rx)));
}

AMProj3DMat4 amproj3d_composeTRS(AMProj3DVec3 t, AMProj3DVec3 r, AMProj3DVec3 s) {
    /* M = T * R * S */
    AMProj3DMat4 m = amproj3d_scale(s.x, s.y, s.z);
    m = amproj3d_multiply(amproj3d_eulerXYZ(r.x, r.y, r.z), m);
    m = amproj3d_multiply(amproj3d_translation(t.x, t.y, t.z), m);
    return m;
}

#pragma mark - 运算

AMProj3DMat4 amproj3d_multiply(AMProj3DMat4 a, AMProj3DMat4 b) {
    AMProj3DMat4 out;
    for (int c = 0; c < 4; c++) {
        for (int r = 0; r < 4; r++) {
            double v = 0.0;
            for (int k = 0; k < 4; k++) v += a.m[k * 4 + r] * b.m[c * 4 + k];
            out.m[c * 4 + r] = amproj3d_clampFinite(v, -AMPROJ3D_MAX_ABS, AMPROJ3D_MAX_ABS, 0.0);
        }
    }
    return out;
}

AMProj3DVec3 amproj3d_transformPoint(AMProj3DMat4 m, AMProj3DVec3 v) {
    double x = amproj3d_clampCoord(v.x), y = amproj3d_clampCoord(v.y), z = amproj3d_clampCoord(v.z);
    double w = m.m[3] * x + m.m[7] * y + m.m[11] * z + m.m[15];
    if (fabs(w) < AMPROJ3D_EPS) w = AMPROJ3D_EPS;
    AMProj3DVec3 out = {
        (m.m[0] * x + m.m[4] * y + m.m[8] * z + m.m[12]) / w,
        (m.m[1] * x + m.m[5] * y + m.m[9] * z + m.m[13]) / w,
        (m.m[2] * x + m.m[6] * y + m.m[10] * z + m.m[14]) / w,
    };
    return out;
}

static double amproj3d_det3(const AMProj3DMat4 *a, int i0, int i1, int i2,
                            int j0, int j1, int j2) {
    return (a->m[i0 * 4 + j0] * (a->m[i1 * 4 + j1] * a->m[i2 * 4 + j2] - a->m[i1 * 4 + j2] * a->m[i2 * 4 + j1])
            - a->m[i1 * 4 + j0] * (a->m[i0 * 4 + j1] * a->m[i2 * 4 + j2] - a->m[i0 * 4 + j2] * a->m[i2 * 4 + j1])
            + a->m[i2 * 4 + j0] * (a->m[i0 * 4 + j1] * a->m[i1 * 4 + j2] - a->m[i0 * 4 + j2] * a->m[i1 * 4 + j1]));
}

static double amproj3d_det(const AMProj3DMat4 *a) {
    return (a->m[0] * amproj3d_det3(a, 1, 2, 3, 1, 2, 3)
            - a->m[4] * amproj3d_det3(a, 0, 2, 3, 1, 2, 3)
            + a->m[8] * amproj3d_det3(a, 0, 1, 3, 1, 2, 3)
            - a->m[12] * amproj3d_det3(a, 0, 1, 2, 1, 2, 3));
}

static double amproj3d_cofactor(const AMProj3DMat4 *a, int r, int c) {
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

bool amproj3d_inverse(AMProj3DMat4 m, AMProj3DMat4 *out) {
    if (!out) return false;
    double d = amproj3d_det(&m);
    if (!amproj3d_isFinite(d) || fabs(d) < AMPROJ3D_INV_EPS) return false;
    for (int c = 0; c < 4; c++) {
        for (int r = 0; r < 4; r++) {
            out->m[c * 4 + r] = amproj3d_clampFinite(amproj3d_cofactor(&m, r, c) / d,
                                                     -AMPROJ3D_MAX_ABS, AMPROJ3D_MAX_ABS, 0.0);
        }
    }
    return true;
}

bool amproj3d_safeInverse(AMProj3DMat4 m, AMProj3DMat4 *out) {
    if (!out) return false;
    if (!amproj3d_inverse(m, out)) {
        *out = amproj3d_identity();
    }
    return true;
}
