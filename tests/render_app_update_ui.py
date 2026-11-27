"""Render and check the production UIKit update view on an isolated iOS simulator."""
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "update-ui-preview"
BUNDLE = "cn.ayakameow.update-preview"


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=180).strip()


def main():
    OUTPUT.mkdir(exist_ok=True)
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
    runtime = next(item["identifier"] for item in reversed(runtimes) if item.get("isAvailable") and ".iOS-" in item["identifier"])
    types = json.loads(run("xcrun", "simctl", "list", "devicetypes", "--json"))["devicetypes"]
    device_type = next(item["identifier"] for item in types if item["name"] == "iPhone 13 Pro")
    device = run("xcrun", "simctl", "create", "AM Update UI Check", device_type, runtime)
    try:
        with tempfile.TemporaryDirectory(prefix="am-update-ui-") as temporary:
            app = Path(temporary) / "UpdatePreview.app"
            app.mkdir()
            with (app / "Info.plist").open("wb") as output:
                plistlib.dump({"CFBundleIdentifier": BUNDLE, "CFBundleExecutable": "UpdatePreview", "CFBundleName": "Update Preview", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL", "MinimumOSVersion": "14.0", "UIDeviceFamily": [1, 2], "UILaunchScreen": {}}, output)
            sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
            run("xcrun", "--sdk", "iphonesimulator", "clang", "-fobjc-arc", "-isysroot", sdk, "-mios-simulator-version-min=14.0", "-framework", "UIKit", "-framework", "Foundation", "-framework", "Security", "-framework", "WebKit", "-framework", "SafariServices", str(ROOT / "tests/app_update_ui_preview.m"), "-o", str(app / "UpdatePreview"))
            run("codesign", "--force", "--sign", "-", str(app))
            run("xcrun", "simctl", "boot", device)
            run("xcrun", "simctl", "bootstatus", device, "-b")
            run("xcrun", "simctl", "status_bar", device, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100")
            run("xcrun", "simctl", "install", device, str(app))
            reports = {}
            for name, args in [("install", []), ("preparing", ["--busy"]), ("association", ["--association"]), ("large-text", ["--association", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])]:
                if reports:
                    run("xcrun", "simctl", "terminate", device, BUNDLE)
                container = Path(run("xcrun", "simctl", "get_app_container", device, BUNDLE, "data"))
                report_file = container / "Documents/ui-report.json"
                report_file.unlink(missing_ok=True)
                run("xcrun", "simctl", "launch", device, BUNDLE, *args)
                deadline = time.monotonic() + 30
                while not report_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.25)
                report = json.loads(report_file.read_text())
                assert report["lightAppearance"] and report["messageNotClipped"] and report["buttonTextNotClipped"] and report["noHorizontalOverflow"], report
                assert report["buttonHeight"] >= 44 and report["steps"] == 3, report
                assert report["associationHidden"] == ("--association" not in args), report
                if "--association" in args:
                    assert report["associationHeight"] >= 320, report
                assert report["buttonEnabled"] != report["busy"], report
                if name == "large-text":
                    assert "AccessibilityXXXL" in report["contentSizeCategory"], report
                run("xcrun", "simctl", "io", device, "screenshot", str(OUTPUT / (name + ".png")))
                reports[name] = report
            (OUTPUT / "validation.json").write_text(json.dumps(reports, indent=2))
            print("APP_UPDATE_UI_PREVIEW_PASS")
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True, timeout=60)
        subprocess.run(["xcrun", "simctl", "delete", device], capture_output=True, timeout=60)


if __name__ == "__main__":
    main()
