"""源码级断言：AM3D 独立 3D dylib（不依赖 AMProjExport / AmHomeUI）。

保证：
1. AM3D 模块自包含（不 import 任何 AMProjExport/AmHomeUI 代码）；
2. 3D 数学/渲染桥关键符号存在；
3. 构建（Makefile）与 CI（workflow）覆盖 AM3D；
4. 数学 smoke 覆盖 2D 退化与安全。
"""

import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
AM3D_DIR = ROOT / "AM3D"
MAIN_SOURCE = AM3D_DIR / "AM3D.m"
MAIN_HEADER = AM3D_DIR / "AM3D.h"
MATH_SOURCE = AM3D_DIR / "AM3DTransform3D.m"
MATH_HEADER = AM3D_DIR / "AM3DTransform3D.h"
MAKEFILE = AM3D_DIR / "Makefile"
SMOKE = ROOT / "tests" / "AM3DTransform3DSmoke.m"
WORKFLOW = ROOT / ".github" / "workflows" / "build.yml"


class AM3DIndependenceTests(unittest.TestCase):
    def test_no_dependency_on_other_modules(self):
        """真正的依赖检查：不允许 #import/#include 其他 mod 模块
        （注释里提及不算依赖）。"""
        for p in (MAIN_SOURCE, MAIN_HEADER, MATH_SOURCE, MATH_HEADER):
            text = p.read_text(encoding="utf-8")
            for line in text.splitlines():
                stripped = line.strip()
                if not (stripped.startswith("#import") or stripped.startswith("#include")):
                    continue
                for forbidden in ("AMProjExport", "AmHomeUI", "AmEnhancer",
                                  "AMDebugTransport", "AMProjArchiveWriter",
                                  "AMProjImportArchive", "AMProjNativeImportBridge"):
                    self.assertNotIn(forbidden, line,
                                     "%s import must not reference %s" % (p.name, forbidden))

    def test_renderer_entry_and_math_symbols(self):
        main = MAIN_SOURCE.read_text(encoding="utf-8")
        header = MAIN_HEADER.read_text(encoding="utf-8")
        self.assertIn("+ (void)load", main)
        self.assertIn("CADisplayLink", main)
        self.assertIn("AM3DStart", header)
        self.assertIn("AM3DStop", header)
        math_src = MATH_SOURCE.read_text(encoding="utf-8")
        math_hdr = MATH_HEADER.read_text(encoding="utf-8")
        for sym in ("am3d_eulerXYZ", "am3d_composeTRS", "am3d_multiply",
                    "am3d_inverse", "am3d_safeInverse", "am3d_parseVec3",
                    "am3d_mat4ToFloat16", "am3d_clampFinite"):
            self.assertIn(sym, math_hdr)
            self.assertIn(sym, math_src)

    def test_crash_safety_invariants(self):
        math_src = MATH_SOURCE.read_text(encoding="utf-8")
        for required in ("isnan(v)", "AM3D_INV_EPS", "AM3D_MIN_SCALE",
                         "fabs(w) < AM3D_EPS", "scanDouble"):
            self.assertIn(required, math_src)
        main = MAIN_SOURCE.read_text(encoding="utf-8")
        self.assertIn("@try {", main)
        self.assertIn("@catch (NSException *e)", main)
        self.assertIn("seen.count > 64", main)  # 父链深度保护

    def test_true_3d_first_and_2d5_fallback_paths(self):
        """真 3D（透视 m34 + 欧拉 XYZ）优先，映射失败时降级占位演示。"""
        main = MAIN_SOURCE.read_text(encoding="utf-8")
        self.assertIn("m34", main)
        self.assertIn("sublayerTransform", main)
        self.assertIn("am3d_composeTRS", main)      # world 矩阵 = 父链 TRS 连乘
        self.assertIn("am3d_multiply", main)
        self.assertIn("ensureDemoOverlay", main)     # 降级占位
        self.assertIn("AM3DDemoFallback", main)

    def test_makefile_builds_am3d(self):
        makefile = MAKEFILE.read_text(encoding="utf-8")
        self.assertIn("AM3D.dylib", makefile)
        self.assertIn("AM3D.m AM3DTransform3D.m", makefile)
        self.assertIn("QuartzCore", makefile)

    def test_smoke_covers_math(self):
        smoke = SMOKE.read_text(encoding="utf-8")
        for required in ("testRotationZMatches2D", "testEulerReducesTo2D",
                         "testInvertible", "testTRSCompose", "testSafety",
                         "testParseVec3", "testFormatAndFloat16"):
            self.assertIn(required, smoke)

    def test_ci_builds_and_publishes_am3d(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("Build AM3D dylib", workflow)
        self.assertIn("AM3DTransform3DSmoke.m", workflow)
        self.assertIn("am3d", workflow.lower())


if __name__ == "__main__":
    unittest.main()
