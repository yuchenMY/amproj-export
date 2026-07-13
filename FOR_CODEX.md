# For Codex — AMProjExport: Continue & Fix

## What this project does
Adds `.amproj` file export to an iOS app (AlightMotion v27b). The app's existing "Project Package Export" button outputs a PNG. Our dylib intercepts the share flow and replaces the PNG with a proper `.amproj` ZIP file.

## Repo & Build
- **GitHub**: `https://github.com/yuchenMY/amproj-export`
- **CI**: Push to master → GitHub Actions (macOS) auto-compiles `AMProjExport.dylib`
- **Dylib**: `AMProjExport/AMProjExport.m` — pure ObjC, 2 integration points, zero external deps

## How it works (2 integration points)

**Hook 1** — `UIViewController.presentViewController:animated:completion:`:
```
When any VC presents a UIActivityViewController, check if the presenter's class name contains "Package".
If yes → set flag `amproj_isPackageExport = YES`.
```

**Hook 2** — `UIActivityViewController.initWithActivityItems:applicationActivities:`:
```
If flag is set AND items contain UIImage → replace items array with a single NSURL pointing to a
newly-created .amproj file.
```

**Export logic** (when triggered):
1. Walk AppDelegate + responder chain with ObjC runtime (`class_copyPropertyList`, `class_copyIvarList`, `valueForKey:`) to find the scene object
2. Build XML following the schema in `format_spec.md`
3. Create PKZIP archive (hand-rolled, no libzip needed)
4. Write to temp file, return as NSURL for share sheet

## Files you need to know

| File | Purpose |
|------|---------|
| `AMProjExport/AMProjExport.m` | All dylib logic (ZIP, XML, hooks, export) |
| `format_spec.md` | .amproj XML schema (scene → layers → transform/effects/keyframes) |
| `inject_dylib.py` | Windows IPA patcher (insert LC_LOAD_DYLIB + Info.plist UTI registration) |

## What needs fixing / verifying

### Priority 1: Device testing
Sideload `AM_v27b_amproj.ipa` → tap "Project Package Export" → check if share sheet shows `.amproj` or still PNG.

### Priority 2: Debug if still PNG
Console log filter: `[AMProjExport]`. The detection depends on ViewController class name containing "Package". If the actual VC is named differently, adjust the `containsString:@"Package"` check in `hooked_presentVC`.

### Priority 3: Debug if amproj is empty/minimal
The `amproj_buildXML()` function at line ~170 uses ObjC KVC to access scene properties (`@"title"`, `@"width"`, `@"layers"`, etc.). If Swift internal types don't expose these to KVC, the fallback placeholder XML is used. Console logs from `am_dump()` (if uncommented) will show actual available property names.

### Priority 4: Known compilation warnings
- `keyWindow` deprecated in iOS 13+ (line ~394) — harmless, uses UIScene API first, keyWindow only as fallback.

## .amproj format (terse)
- Container: standard PKZIP
- Required: exactly one `.xml` file (any name) containing `<scene>...</scene>`
- Optional: `.png`/`.jpg`/`.webp` images, `.ttf`/`.otf` fonts
- XML schema: `<scene title width height fps totalTime bgcolor>` → `<shape|text|image|...>` children → `<transform>` + `<effect>` + `<fillColor>` etc.
- Full spec: `format_spec.md` (497 lines)

## Injection script usage (Windows)
```bat
python inject_dylib.py input.ipa AMProjExport.dylib output.ipa
```
Automatically: unzips IPA, copies dylib to Frameworks, inserts LC_LOAD_DYLIB in Mach-O, adds `.amproj` UTI to Info.plist, removes old signature, repacks.

After injection: sign with AltStore or Sideloadly (Windows, free Apple ID).
