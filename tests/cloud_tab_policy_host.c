#include "../AMProjExport/AMCloudTabPolicy.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static uint8_t image[390 * 60 * 4];

static void rectangle(int left, int top, int width, int height, uint8_t color) {
    for (int y = top; y < top + height; y++) {
        for (int x = left; x < left + width; x++) {
            uint8_t *p = image + (y * 390 + x) * 4;
            p[0] = p[1] = p[2] = color;
            p[3] = 255;
        }
    }
}

static int selected(void) { return AMCloudSelectedPillRGBA(image, 390, 60, 390 * 4); }

int main(int argc, char **argv) {
    if (argc == 2) {
        FILE *file = fopen(argv[1], "rb");
        assert(file && fread(image, 1, sizeof(image), file) == sizeof(image));
        fclose(file);
        printf("%d\n", selected());
        return 0;
    }
    assert(AMCloudSelectedPillRGBA(NULL, 390, 60, 1560) == -1);
    assert(AMCloudSelectedPillRGBA(image, 390, 60, 100) == -1);
    for (int tab = 0; tab < 4; tab++) {
        memset(image, 255, sizeof(image));
        rectangle(16 + tab * 88, 10, 64, 40, 35);
        /* 白字打断中部背景，仍应按完整胶囊识别。 */
        rectangle(26 + tab * 88, 22, 44, 2, 255);
        rectangle(26 + tab * 88, 28, 44, 2, 255);
        rectangle(26 + tab * 88, 34, 44, 2, 255);
        assert(selected() == (tab == 3 ? 1 : 0));
    }
    memset(image, 255, sizeof(image));
    assert(selected() == -1);
    /* 右侧未选中文字曾被当成深色胶囊，导致项目/模板误开云空间。 */
    for (int x = 285; x < 340; x += 9) {
        rectangle(x, 20, 2, 20, 25);
        rectangle(x, 24, 7, 2, 25);
    }
    assert(selected() == -1);
    memset(image, 0, sizeof(image));
    rectangle(0, 0, 390, 60, 30);
    assert(selected() == -1);
    puts("CLOUD_TAB_POLICY_PASS");
    return 0;
}
