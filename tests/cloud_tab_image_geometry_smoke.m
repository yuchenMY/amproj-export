// 猫鹤 AM · 验证截图回读后的标签边界保持顶部坐标。
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include "AMCloudTabPolicy.h"
#include <assert.h>
#include <stdio.h>

static NSInteger classify(CGImageRef image, CGRect *tabFrame) {
// AMPROJ_PRODUCTION_IMAGE_READBACK
    return state;
}

int main(void) {
    @autoreleasepool {
        size_t width = 390, height = 280, stride = width * 4;
        uint8_t *pixels = malloc(height * stride);
        memset(pixels, 255, height * stride);
        for (size_t y = 125; y < 165; y++) {
            for (size_t x = 276; x < 340; x++) {
                uint8_t *p = pixels + y * stride + x * 4;
                p[0] = p[1] = p[2] = 35;
            }
        }
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8,
            stride, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGImageRef image = CGBitmapContextCreateImage(context);
        CGRect frame = CGRectZero;
        assert(classify(image, &frame) == 1);
        assert(CGRectGetMinY(frame) >= 115 && CGRectGetMinY(frame) <= 125);
        assert(CGRectGetMaxY(frame) >= 165 && CGRectGetMaxY(frame) <= 175);
        CGImageRelease(image);
        CGContextRelease(context);
        CGColorSpaceRelease(space);
        free(pixels);
        puts("CLOUD_IMAGE_GEOMETRY_PASS");
    }
}
