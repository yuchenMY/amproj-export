# Session Summary — AMProjExport

## Goal
Add `.amproj` project file export to AlightMotion iOS (v27b), replacing the existing "Project Package Export" feature that currently outputs a PNG image. Also register `.amproj` as a recognized file type so the app can open `.amproj` files from other apps (QQ, WeChat, etc.).

## What was built

### `AMProjExport/AMProjExport.m` — iOS dylib source
- **Strategy**: Intercept `UIActivityViewController` initialization to detect when the app's project package sharing flow is triggered. When detected, replace the PNG image items with a proper `.amproj` ZIP file.
- **Detection**: Two integration points on `UIViewController` and `UIActivityViewController` track when a package-related view controller triggers the share sheet.
- **ZIP creation**: Pure C/ObjC implementation, no external dependencies. Creates standard PKZIP with `scene.xml` inside.
- **XML builder**: Generates `.amproj` XML following the documented schema (see `format_spec.md`). Includes recursive object walker that discovers scene/layer/effect data via ObjC runtime reflection.
- **Safe fallback**: If scene data is inaccessible, outputs a minimal valid XML placeholder instead of crashing.

### GitHub Actions — CI build
- `.github/workflows/build.yml`: macOS runner compiles the dylib on push.
- Repo: `https://github.com/yuchenMY/amproj-export`

### Windows injection tooling
- `inject_dylib.py`: Unzips IPA, copies dylib into Frameworks, patches Mach-O binary (adds LC_LOAD_DYLIB), patches Info.plist (adds `.amproj` UTI + document type registration), repacks IPA.
- `build_and_inject.bat`: Windows batch wrapper.

### Documentation
- `format_spec.md` (497 lines): Complete `.amproj` file format specification (ZIP container + XML schema + coordinate system + color format + easing functions).
- `xml_schema.md`: Quick-reference XML templates.
- `easing_reference.md`: 8 easing function algorithms and their XML representation.
- `effects_list.md`: 34+ known effect IDs for both Android and iOS.

## Current status

### Working
- dylib compiles successfully on GitHub Actions (macOS, Xcode 16.4, iPhoneOS 18.5 SDK, arm64)
- IPA injection script works (patches Mach-O, patches Info.plist, repacks)
- GitHub Actions CI: push → build → artifact

### Not yet verified (needs device testing)
- Whether the dylib correctly detects the project package export flow (depends on actual ViewController class names at runtime)
- Whether the ObjC runtime reflection successfully discovers scene/layer/effect data from Swift internal types
- Whether the `.amproj` file produced is valid and importable

### Known limitations
- The scene data extraction uses ObjC KVC + ivar scanning; Swift internal types may not be fully accessible via these methods. If the XML output is minimal (placeholder), the runtime scan logs need analysis to determine the correct property names.
- The `keyWindow` deprecation warning (iOS 13+) is harmless but could be cleaned up.

## Architecture

```
User taps "Project Package Export" in AM
  → AM prepares UIActivityViewController with PNG items
  → Dylib detects presenting VC name contains "Package"
  → Dylib replaces PNG items with .amproj file URL
  → User sees share sheet with .amproj file
```

## File manifest

```
D:\Tools\AM_Mods\amproj\
├── .github/workflows/build.yml     # CI: macOS build
├── .gitignore
├── AMProjExport/
│   ├── AMProjExport.m              # Dylib source (main)
│   └── Makefile                    # macOS build config
├── inject_dylib.py                 # Windows: IPA injection + signing prep
├── build_and_inject.bat            # Windows batch wrapper
├── format_spec.md                  # .amproj file format spec
├── xml_schema.md                   # XML quick reference
├── easing_reference.md             # Easing functions reference
├── effects_list.md                 # Known effect IDs
├── frida_find_export.js            # Runtime discovery script
├── example_annotated.xml           # Sample project XML
├── README.md
├── SUMMARY.md
└── SESSION_SUMMARY.md              # This file

Output:
├── AMProjExport.dylib              # Built dylib (86KB, from Actions)
├── AM_v27b.ipa                     # Input IPA (140MB, copy)
└── AM_v27b_amproj.ipa              # Output IPA (140MB, patched)
```

## Next steps for Codex

1. **Test on device**: Sideload `AM_v27b_amproj.ipa` via AltStore/Sideloadly. Open AM, use "Project Package Export".
2. **Check logs**: If still PNG instead of .amproj, check console for `[AMProjExport]` messages. The detection logic (ViewController class name matching) may need adjustment.
3. **Improve scene data extraction**: If `.amproj` is produced but contains only placeholder XML, the runtime property names used in `amproj_buildXML()` don't match the actual Swift types. Add more property name variants or analyze the console dump output.
4. **Clean up**: Remove `keyWindow` deprecation warning if desired (not blocking).
5. **Code signing**: IPA must be signed before install. Use AltStore (free Apple ID) or Sideloadly on Windows.
