#ifndef AM_CLOUD_TAB_POLICY_H
#define AM_CLOUD_TAB_POLICY_H

#include <stddef.h>
#include <stdint.h>

/* 只接受胶囊背景的连续实色区域，文字笔画不能充当选中状态。 */
static inline int AMCloudSelectedPillRGBA(const uint8_t *pixels, size_t width,
                                         size_t height, size_t stride) {
    if (!pixels || width < 80 || height < 20 || stride < width * 4) return -1;
    size_t bestStart = 0, bestLength = 0;
    for (size_t top = 0; top + 6 <= height; top++) {
        size_t run = 0, start = 0;
        for (size_t x = 0; x <= width; x++) {
            size_t dark = 0;
            if (x < width) {
                for (size_t y = top; y < top + 6; y++) {
                    const uint8_t *p = pixels + y * stride + x * 4;
                    if (p[3] > 220 && p[0] < 90 && p[1] < 90 && p[2] < 110) dark++;
                }
            }
            if (x < width && dark >= 5) {
                if (!run) start = x;
                run++;
            } else {
                if (run > bestLength) { bestStart = start; bestLength = run; }
                run = 0;
            }
        }
    }
    if (bestLength < 24 || bestLength > width / 2) return -1;
    double center = ((double)bestStart + (double)bestLength / 2) / (double)width;
    return center > 0.72 ? 1 : 0;
}

#endif
