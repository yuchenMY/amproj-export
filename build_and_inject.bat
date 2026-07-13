@echo off
REM ============================================================
REM  build_and_inject.bat — Windows 端 IPA 注入脚本
REM
REM  用法: build_and_inject.bat <输入.ipa> [输出.ipa]
REM  示例: build_and_inject.bat AlightMotion_v27b.ipa AMProjExport_v27b.ipa
REM
REM  前提:
REM    1. 将 AMProjExport.dylib 放在本脚本同目录
REM    2. 已安装 Python 3
REM    3. (可选) zsign.exe 放在同目录用于签名
REM       zsign: https://github.com/zhlynn/zsign
REM ============================================================

setlocal enabledelayedexpansion

set INPUT_IPA=%1
set OUTPUT_IPA=%2
if "%OUTPUT_IPA%"=="" set OUTPUT_IPA=AMProjExport_output.ipa

if "%INPUT_IPA%"=="" (
    echo Usage: build_and_inject.bat ^<input.ipa^> [output.ipa]
    exit /b 1
)

if not exist "%INPUT_IPA%" (
    echo ERROR: Input IPA not found: %INPUT_IPA%
    exit /b 1
)

if not exist "AMProjExport.dylib" (
    echo ERROR: AMProjExport.dylib not found!
    echo Please download from GitHub Actions artifact or build on macOS.
    exit /b 1
)

echo [*] Input: %INPUT_IPA%
echo [*] Output: %OUTPUT_IPA%
echo [*] Injecting AMProjExport.dylib...

REM Step 1: Inject dylib using Python script
python inject_dylib.py "%INPUT_IPA%" "AMProjExport.dylib" "%OUTPUT_IPA%"
if %ERRORLEVEL% neq 0 (
    echo ERROR: Injection failed!
    exit /b 1
)

echo.
echo ============================================================
echo Done! Output: %OUTPUT_IPA%
echo.
echo Next steps:
echo   1. Sign with your Apple ID certificate:
echo      - Use iOS App Signer ^(macOS^)
echo      - Or AltStore ^(Windows^)
echo      - Or Sideloadly ^(Windows^)
echo   2. Install via AltStore / Sideloadly / TrollStore
echo ============================================================
