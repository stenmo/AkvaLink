@echo off
REM ========================================================================
REM akvalink.cmd -- unified AkvaLink launcher (Windows)
REM ========================================================================
REM ONE front door for everything:
REM
REM   Firmware  (NORA-W40 / ESP32-C6)  -> built via WSL, flashed natively.
REM   App       (Flutter companion)    -> built natively with the Flutter SDK.
REM
REM You should not have to care whether a task runs in WSL or on Windows --
REM this script routes it for you.
REM
REM   akvalink.cmd [firmware args...]        Firmware (forwarded to WSL engine)
REM   akvalink.cmd --app [--windows]         Build the app for Windows (default)
REM   akvalink.cmd --app --android           Build the Android APK
REM   akvalink.cmd --app --run               Run the app on this machine
REM   akvalink.cmd --help                    Show this help
REM
REM iOS / macOS app builds require a Mac -- use ./akvalink.sh there.
REM
REM Firmware examples (see --help of the engine for the full set):
REM   akvalink.cmd --build --flash --log
REM   akvalink.cmd --rebuild --wifi
REM   akvalink.cmd --ap --flash COM62
REM ========================================================================

setlocal enabledelayedexpansion
set "SCRIPT_DIR=%~dp0"

REM --- Combined help --------------------------------------------------------
if /I "%~1"=="--help"  goto show_help
if /I "%~1"=="-h"      goto show_help
if /I "%~1"=="/?"      goto show_help

REM --- Detect --app anywhere in the argument list ---------------------------
set "APP_MODE=0"
for %%A in (%*) do (
    if /I "%%~A"=="--app" set "APP_MODE=1"
)

if "%APP_MODE%"=="1" goto app_build

REM --- Firmware: forward EVERYTHING to the WSL engine -----------------------
call "%SCRIPT_DIR%launch-akvalink-wsl.cmd" %*
exit /b %errorlevel%

REM ========================================================================
:app_build
REM Parse the app target. Default = windows (this host).
set "TARGET=windows"
set "DO_RUN=0"

:app_parse
if "%~1"=="" goto app_go
if /I "%~1"=="--app"     ( shift & goto app_parse )
if /I "%~1"=="--windows" ( set "TARGET=windows" & shift & goto app_parse )
if /I "%~1"=="--android" ( set "TARGET=apk"     & shift & goto app_parse )
if /I "%~1"=="--ios"     ( set "TARGET=ios"     & shift & goto app_parse )
if /I "%~1"=="--macos"   ( set "TARGET=macos"   & shift & goto app_parse )
if /I "%~1"=="--run"     ( set "DO_RUN=1"       & shift & goto app_parse )
echo [ERROR] Unknown --app option: %~1
echo Run: akvalink.cmd --help
exit /b 2

:app_go
if /I "%TARGET%"=="ios" (
    echo [ERROR] iOS builds require macOS. On your Mac run:  ./akvalink.sh --app --ios
    exit /b 3
)
if /I "%TARGET%"=="macos" (
    echo [ERROR] macOS builds require macOS. On your Mac run:  ./akvalink.sh --app --macos
    exit /b 3
)
where flutter >nul 2>&1 || (
    echo [ERROR] 'flutter' not found on PATH. Install the Flutter SDK first.
    exit /b 4
)

pushd "%SCRIPT_DIR%app_flutter"
echo === app: flutter pub get ===
call flutter pub get || ( popd & exit /b 1 )

if "%DO_RUN%"=="1" (
    echo === app: flutter run ^(this machine^) ===
    call flutter run
) else (
    echo === app: flutter build %TARGET% ===
    call flutter build %TARGET%
)
set "RC=%errorlevel%"
popd
exit /b %RC%

REM ========================================================================
:show_help
echo AkvaLink -- unified launcher ^(Windows^)
echo.
echo FIRMWARE ^(NORA-W40, built via WSL, flashed natively^):
echo   akvalink.cmd --build                 Build ^(Thread SED unless a variant flag^)
echo   akvalink.cmd --rebuild --wifi        Clean rebuild, Wi-Fi variant
echo   akvalink.cmd --flash [COM^<N^>]        Flash ^(autodetect port if omitted^)
echo   akvalink.cmd --log   [COM^<N^>]        Serial monitor
echo   Variant flags: --wifi --ble --ap --station --espnow --sensor --clickboard
echo   ^(Full firmware help:  akvalink.cmd --build --help  is handled by the engine^)
echo.
echo APP ^(Flutter companion, built natively^):
echo   akvalink.cmd --app                   Build for Windows ^(default^)
echo   akvalink.cmd --app --windows         Build the Windows app
echo   akvalink.cmd --app --android         Build the Android APK
echo   akvalink.cmd --app --run             Run the app on this machine
echo   akvalink.cmd --app --ios ^| --macos   ^(require a Mac -- use ./akvalink.sh^)
echo.
echo On Linux/macOS use the sibling script:  ./akvalink.sh
exit /b 0
