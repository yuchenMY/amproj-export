"""源码级断言：AMProjExport dylib 的 3D 空对象支持（meow3d.* 导出）。

与 empty3d（离线 Python 模型，3D_Body_Test_20260826/empty3d）保持同一套
数据约定：图层级 <property name="meow3d.rotation" type="vec3" value="..."/>、
meow3d.scale、meow3d.enabled；默认值不写出；所有数值经 amproj3d_* 安全归一。
本测试确保这些约定在 dylib 源码中始终存在，防止回归。
"""

import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
EXPORT_SOURCE = ROOT / "AMProjExport" / "AMProjExport.m"
TRANSFORM_HEADER = ROOT / "AMProjExport" / "AMProjTransform3D.h"
TRANSFORM_SOURCE = ROOT / "AMProjExport" / "AMProjTransform3D.m"
MAKEFILE = ROOT / "AMProjExport" / "Makefile"
SMOKE = ROOT / "tests" / "AMProjTransform3DSmoke.m"
WORKFLOW = ROOT / ".github" / "workflows" / "build.yml"


class Transform3DModuleTests(unittest.TestCase):
    def test_module_files_exist_with_header_guard(self):
        header = TRANSFORM_HEADER.read_text(encoding="utf-8")
        self.assertIn("#ifndef AMProjTransform3D_h", header)
        self.assertIn("extern \"C\"", header)
        source = TRANSFORM_SOURCE.read_text(encoding="utf-8")
        for symbol in (
            "amproj3d_clampFinite",
            "amproj3d_eulerXYZ",
            "amproj3d_composeTRS",
            "amproj3d_multiply",
            "amproj3d_transformPoint",
            "amproj3d_inverse",
            "amproj3d_safeInverse",
            "amproj3d_parseVec3",
            "amproj3d_formatVec3",
        ):
            self.assertIn(symbol, header)
            self.assertIn(symbol, source)

    def test_crash_safety_invariants(self):
        source = TRANSFORM_SOURCE.read_text(encoding="utf-8")
        for required in (
            "isnan(v)",
            "isinf(v)",
            "AMPROJ3D_INV_EPS",
            "AMPROJ3D_MIN_SCALE",
            "fabs(w) < AMPROJ3D_EPS",
            "return false;",
        ):
            self.assertIn(required, source)

    def test_makefile_builds_module_in_all_three_targets(self):
        makefile = MAKEFILE.read_text(encoding="utf-8")
        # 三个目标（release/cloud/debug）的依赖行 + 编译行都包含 3D 模块
        # （≥6 = 3 依赖行 + 3 编译行；注释里也可能出现说明文字）
        self.assertGreaterEqual(makefile.count("AMProjTransform3D.m"), 6)
        self.assertGreaterEqual(makefile.count("AMProjTransform3D.h"), 3)


class Export3DPropertiesTests(unittest.TestCase):
    def test_serializer_invoked_in_layer_writer(self):
        source = EXPORT_SOURCE.read_text(encoding="utf-8")
        self.assertIn("amproj_serializeLayer3DProperties(layer, xf, l)", source)
        self.assertIn("static void amproj_serializeLayer3DProperties(", source)

    def test_meow3d_property_names_and_types(self):
        source = EXPORT_SOURCE.read_text(encoding="utf-8")
        self.assertIn('name=\\"meow3d.rotation\\" type=\\"vec3\\"', source)
        self.assertIn('name=\\"meow3d.scale\\" type=\\"vec3\\"', source)
        self.assertIn('name=\\"meow3d.enabled\\" type=\\"bool\\"', source)

    def test_default_values_are_not_written(self):
        """无 3D 数据时（默认值）不写出任何属性 —— 旧项目导出逐字节不变。"""
        source = EXPORT_SOURCE.read_text(encoding="utf-8")
        self.assertIn("fabs(r.x) > 1e-9 || fabs(r.y) > 1e-9 || fabs(r.z) > 1e-9", source)
        self.assertIn("fabs(s.x - 1.0) > 1e-9", source)
        # 取值失败/缺字段时函数整体无输出
        self.assertIn("if (rot3 && amproj3d_parseVec3", source)
        self.assertIn("if (scl3 && amproj3d_parseVec3", source)

    def test_kvc_field_names_compatible(self):
        source = EXPORT_SOURCE.read_text(encoding="utf-8")
        self.assertIn('am_get(xf, @"rotation3d")', source)
        self.assertIn('am_get(xf, @"rotation3dValue")', source)
        self.assertIn('am_get(xf, @"scale3d")', source)
        self.assertIn('am_get(layer, @"meow3dEnabled")', source)

    def test_serialize_errors_never_crash(self):
        source = EXPORT_SOURCE.read_text(encoding="utf-8")
        self.assertIn("@try {", source)
        self.assertIn("@catch (NSException *e)", source)


class WorkflowTests(unittest.TestCase):
    def test_ci_runs_3d_smoke(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("Test 3D transform module", workflow)
        self.assertIn("AMProjTransform3DSmoke.m", workflow)
        self.assertIn("amproj-3d-smoke", workflow)

    def test_smoke_covers_2d_equivalence_and_safety(self):
        smoke = SMOKE.read_text(encoding="utf-8")
        for required in (
            "testRotationZMatches2D",
            "testEulerReducesTo2D",
            "testRotationsInvertible",
            "testTRSCompose",
            "testSafety",
            "testParseVec3",
            "testFormatVec3",
        ):
            self.assertIn(required, smoke)


if __name__ == "__main__":
    unittest.main()
