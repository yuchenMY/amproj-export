@echo off
REM Build the single verified Alight Motion 6.2.55 (862) direct-Cloud IPA.
REM Usage: build_and_inject.bat ownbase.ipa [output.ipa] [AMProjExportCloud.dylib]
REM The output must be recursively signed by LCSign before installation.

setlocal

set "SOURCE_IPA=%~1"
set "OUTPUT_IPA=%~2"
set "CLOUD_DYLIB=%~3"

if not defined OUTPUT_IPA set "OUTPUT_IPA=am_v77_ownbase_directCloud_LCSign.ipa"

if not defined SOURCE_IPA (
    echo Usage: build_and_inject.bat ^<ownbase.ipa^> [output.ipa] [AMProjExportCloud.dylib]
    exit /b 1
)

if not exist "%SOURCE_IPA%" (
    echo ERROR: Verified own-base IPA not found: %SOURCE_IPA%
    exit /b 1
)

echo [*] User base: %SOURCE_IPA%
echo [*] Output: %OUTPUT_IPA%
echo [*] Replacing the LoadControl path with a required direct Cloud load...

if defined CLOUD_DYLIB (
    if not exist "%CLOUD_DYLIB%" (
        echo ERROR: v44 Cloud dylib not found: %CLOUD_DYLIB%
        exit /b 1
    )
    py "%~dp0build_862_direct_package.py" "%SOURCE_IPA%" "%OUTPUT_IPA%" --cloud "%CLOUD_DYLIB%"
) else (
    py "%~dp0build_862_direct_package.py" "%SOURCE_IPA%" "%OUTPUT_IPA%"
)

if errorlevel 1 (
    echo ERROR: Direct-Cloud package build or verification failed.
    exit /b 1
)

echo.
echo ============================================================
echo Done. The only package to import into LCSign is: %OUTPUT_IPA%
echo Identity: CFBundleDisplayName=CatCraneAM, CFBundleIdentifier=com.ayakameow.am
echo LCSign must recursively sign the app and every nested dylib/framework.
echo Do not enable LCSign icon replacement or change Info.plist after signing.
echo ============================================================
exit /b 0
