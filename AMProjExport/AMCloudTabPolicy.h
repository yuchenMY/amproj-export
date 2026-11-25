// 猫鹤 AM · 云端子标签选中背景识别。
#ifndef AM_CLOUD_TAB_POLICY_H
#define AM_CLOUD_TAB_POLICY_H

#include <stddef.h>
#include <stdint.h>

/* 自有弹窗遮住命中测试时，只保留同一次选页已挂载的云内容。 */
static inline int AMCloudKeepMountedForOwnedAlert(int mounted, int alertVisible,
                                                 int sameSelection) {
    return mounted && alertVisible && sameSelection;
}

/* 只接受胶囊背景的连续实色区域，文字笔画不能充当选中状态。 */
static inline int AMCloudSelectedPillGeometryRGBA(const uint8_t *pixels, size_t width,
    size_t height, size_t stride, size_t *rowTop, size_t *rowBottom,
    size_t *pillLeft, size_t *pillRight) {
    if (!pixels || width < 80 || height < 20 || stride < width * 4) return -1;
    size_t bestStart = 0, bestLength = 0, bestTop = 0, bestBottom = 0;
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
                if (run > bestLength && run >= 32 && run <= width * 2 / 5) {
                    /* 胶囊两侧留白不含文字；沿侧边确认高度，排除标题的粗笔画。 */
                    size_t first = top, last = top + 6;
                    for (int direction = -1; direction <= 1; direction += 2) {
                        size_t y = direction < 0 ? first : last;
                        while ((direction < 0 && y > 0) || (direction > 0 && y < height)) {
                            size_t sample = direction < 0 ? y - 1 : y;
                            size_t darkEdges = 0;
                            for (size_t offset = 3; offset < 8; offset++) {
                                size_t columns[2] = {start + offset, start + run - 1 - offset};
                                for (size_t side = 0; side < 2; side++) {
                                    const uint8_t *p = pixels + sample * stride + columns[side] * 4;
                                    if (p[3] > 220 && p[0] < 90 && p[1] < 90 && p[2] < 110) darkEdges++;
                                }
                            }
                            if (darkEdges < 8) break;
                            if (direction < 0) y--; else y++;
                        }
                        if (direction < 0) first = y; else last = y;
                    }
                    if (last - first >= 24 && last - first <= 80) {
                        bestStart = start; bestLength = run;
                        bestTop = first > 6 ? first - 6 : 0;
                        bestBottom = last + 6 < height ? last + 6 : height;
                    }
                }
                run = 0;
            }
        }
    }
    if (bestLength < 24 || bestLength > width / 2) return -1;
    if (rowTop) *rowTop = bestTop;
    if (rowBottom) *rowBottom = bestBottom;
    if (pillLeft) *pillLeft = bestStart;
    if (pillRight) *pillRight = bestStart + bestLength;
    double center = ((double)bestStart + (double)bestLength / 2) / (double)width;
    return center > 0.72 ? 1 : 0;
}

static inline int AMCloudSelectedPillBoundsRGBA(const uint8_t *pixels, size_t width,
    size_t height, size_t stride, size_t *rowTop, size_t *rowBottom) {
    return AMCloudSelectedPillGeometryRGBA(pixels, width, height, stride,
        rowTop, rowBottom, NULL, NULL);
}

/* 已核验原生云端按钮的本次点击直接决定转场，后台事件仍核对实际选中态。 */
static inline int AMCloudTabAllowsDisplay(int selected, int targetKnown, int targetCloud) {
    return targetKnown ? targetCloud : selected == 1;
}

/* 在已识别的四标签行内找右侧白色胶囊，不把窗口右侧点击当云端路由。 */
static inline int AMCloudUnselectedCloudPillRGBA(const uint8_t *pixels, size_t width,
    size_t height, size_t stride, size_t rowTop, size_t rowBottom,
    size_t *pillLeft, size_t *pillRight) {
    if (!pixels || width < 80 || stride < width * 4 || rowBottom > height ||
        rowBottom < rowTop + 20) return 0;
    size_t bestStart = 0, bestLength = 0;
    for (size_t y = rowTop + 6; y + 6 < rowBottom; y++) {
        size_t start = 0, run = 0;
        for (size_t x = 0; x <= width; x++) {
            size_t white = 0;
            if (x < width) for (size_t dy = 0; dy < 6; dy++) {
                const uint8_t *p = pixels + (y + dy) * stride + x * 4;
                if (p[3] > 220 && p[0] >= 248 && p[1] >= 248 && p[2] >= 248) white++;
            }
            if (x < width && white >= 5) {
                if (!run) start = x;
                run++;
            } else {
                if (run >= 32 && run <= width * 2 / 5 && run > bestLength &&
                    ((double)start + (double)run / 2) / width > 0.72) {
                    bestStart = start; bestLength = run;
                }
                run = 0;
            }
        }
    }
    if (!bestLength) return 0;
    if (pillLeft) *pillLeft = bestStart;
    if (pillRight) *pillRight = bestStart + bestLength;
    return 1;
}

static inline int AMCloudSelectedPillRGBA(const uint8_t *pixels, size_t width,
                                         size_t height, size_t stride) {
    return AMCloudSelectedPillBoundsRGBA(pixels, width, height, stride, NULL, NULL);
}

#endif
