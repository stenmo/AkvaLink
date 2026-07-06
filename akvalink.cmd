@echo off
REM ========================================================================
REM akvalink.cmd -- unified AkvaLink launcher (Windows)
REM ========================================================================
REM ONE front door for everything: firmware (via WSL) and app (natively).
REM
REM   Firmware (NORA-W40 / ESP32-C6):
REM   --build              Build firmware (Thread SED unless a variant flag)
REM   --clean              Wipe build/ + sdkconfig
REM   --rebuild            --clean then --build
REM   --erase    [COM<N>]  Erase NVS via esptool (autodetect if no port)
REM   --flash    [COM<N>]  Flash 4 partitions via esptool (autodetect if no port)
REM   --log      [COM<N>]  Serial monitor (autodetect if no port)
REM   Variant flags: --wifi --ble --ap --station --espnow --sensor --clickboard
REM
REM   App (Flutter companion):
REM   --app [--windows]    Build the Windows app (default)
REM   --app --android      Build the Android APK
REM   --app --run          Run the app on this machine
REM
REM   --help               Show this help
REM ========================================================================

setlocal enabledelayedexpansion

REM SCRIPT_DIR = repo root (this file sits at the root).
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "DEV_DIR=%SCRIPT_DIR%"
set "LOGS_DIR=%SCRIPT_DIR%\logs"

REM Derive the WSL mount path (E:\other\AkvaLink -> /mnt/e/other/AkvaLink).
set "SCRIPT_DIR_FWD=%SCRIPT_DIR:\=/%"
for /f "usebackq delims=" %%P in (`wsl -- wslpath -a "%SCRIPT_DIR_FWD%"`) do set "DEV_DIR_WSL=%%P"

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

REM ========================================================================
REM FIRMWARE path — all logic is inline, no external launcher needed.
REM ========================================================================

REM Prefer the cross-platform Python helpers when pyserial is available.
set "PYEXE="
where py >nul 2>&1 && set "PYEXE=py -3"
if not defined PYEXE ( where python >nul 2>&1 && set "PYEXE=python" )
if defined PYEXE ( %PYEXE% -c "import serial.tools.list_ports" >nul 2>&1 || set "PYEXE=" )

call "%SCRIPT_DIR%\scripts\common\header.cmd" 2>nul
echo   Platform: u-blox NORA-W40 (Espressif ESP32-C6) -- WSL2 build
echo   Role:     Single-SoC Matter end-node -- Thermometer (DS18B20)
echo   Network:  Matter-over-Thread (SED)  ^|  --wifi for Wi-Fi variant
echo   Sensor:   1-Wire DS18B20 on GPIO15 (EVK J15.4), 4.7 kOhm to +3V3
echo ========================================
echo.

REM --- Parse firmware args --------------------------------------------------
set "DO_BUILD=0"
set "DO_CLEAN=0"
set "DO_ERASE=0"
set "DO_FLASH=0"
set "DO_LOG=0"
set "DO_WIFI=0"
set "DO_BLE=0"
set "DO_SENSOR=0"
set "DO_AP=0"
set "DO_STATION=0"
set "DO_ESPNOW=0"
set "DO_CLICKBOARD=0"
set "DO_SETUP=0"
set "DO_MENUCONFIG=0"
set "PORT_ERASE="
set "PORT_FLASH="
set "PORT_LOG="
set "ANY_FLAG=0"

:parse_args
if "%~1"=="" goto parse_done
set "A=%~1"
set "N=%~2"

if /I "%A%"=="--help"       goto :show_help
if /I "%A%"=="-h"           goto :show_help
if /I "%A%"=="help"         goto :show_help
if /I "%A%"=="--build"      ( set "DO_BUILD=1"      & set "ANY_FLAG=1" & shift & goto parse_args )
if /I "%A%"=="build"        ( set "DO_BUILD=1"      & set "ANY_FLAG=1" & shift & goto parse_args )
if /I "%A%"=="--clean"      ( set "DO_CLEAN=1"      & set "ANY_FLAG=1" & shift & goto parse_args )
if /I "%A%"=="clean"        ( set "DO_CLEAN=1"      & set "ANY_FLAG=1" & shift & goto parse_args )
if /I "%A%"=="--rebuild"    ( set "DO_CLEAN=1" & set "DO_BUILD=1" & set "ANY_FLAG=1" & shift & goto parse_args )
if /I "%A%"=="--wifi"       ( set "DO_WIFI=1"       & set "ANY_FLAG=1" & shift & goto parse_args )
if /I "%A%"=="--ble"        ( set "DO_BLE=1"        & set "ANY_FLAG=1" & shift & goto parse_args )
if /I "%A%"=="--sensor"     ( set "DO_SENSOR=1"     & set "ANY_FLAG=1" & shift & goto parse_args )
if /I "%A%"=="--ap"         ( set "DO_AP=1"         & set "ANY_FLAG=1" & shift & goto parse_args )
if /I "%A%"=="--station"    ( set "DO_STATION=1"    & set "ANY_FLAG=1" & shift & goto parse_args )
if /I "%A%"=="--espnow"     ( set "DO_ESPNOW=1"     & set "ANY_FLAG=1" & shift & goto parse_args )
if /I "%A%"=="--clickboard" ( set "DO_CLICKBOARD=1" & set "ANY_FLAG=1" & shift & goto parse_args )
if /I "%A%"=="setup"        ( set "DO_SETUP=1"      & set "ANY_FLAG=1" & shift & goto parse_args )
if /I "%A%"=="menuconfig"   ( set "DO_MENUCONFIG=1" & set "ANY_FLAG=1" & shift & goto parse_args )

if /I "%A%"=="--erase" (
    set "DO_ERASE=1" & set "ANY_FLAG=1"
    if defined N if /I "!N:~0,3!"=="COM" ( set "PORT_ERASE=!N!" & shift & shift & goto parse_args )
    shift & goto parse_args
)
if /I "%A%"=="--flash" (
    set "DO_FLASH=1" & set "ANY_FLAG=1"
    if defined N if /I "!N:~0,3!"=="COM" ( set "PORT_FLASH=!N!" & shift & shift & goto parse_args )
    shift & goto parse_args
)
if /I "%A%"=="--log" (
    set "DO_LOG=1" & set "ANY_FLAG=1"
    if defined N if /I "!N:~0,3!"=="COM" ( set "PORT_LOG=!N!" & shift & shift & goto parse_args )
    shift & goto parse_args
)
if /I "%A%"=="flash" (
    set "DO_FLASH=1" & set "ANY_FLAG=1"
    if defined N if /I "!N:~0,3!"=="COM" ( set "PORT_FLASH=!N!" & shift & shift & goto parse_args )
    shift & goto parse_args
)
if /I "%A%"=="monitor" (
    set "DO_LOG=1" & set "ANY_FLAG=1"
    if defined N if /I "!N:~0,3!"=="COM" ( set "PORT_LOG=!N!" & shift & shift & goto parse_args )
    shift & goto parse_args
)

echo [ERROR] Unknown argument: %A%
echo Run with --help for usage.
exit /b 2

:parse_done

if "%ANY_FLAG%"=="0" goto :show_help

REM A bare variant flag with no explicit action defaults to --build.
if not "%DO_BUILD%"=="1" if not "%DO_CLEAN%"=="1" if not "%DO_FLASH%"=="1" if not "%DO_ERASE%"=="1" if not "%DO_LOG%"=="1" if not "%DO_SETUP%"=="1" if not "%DO_MENUCONFIG%"=="1" set "DO_BUILD=1"

REM --- Setup / menuconfig ---------------------------------------------------
if "%DO_SETUP%"=="1" (
    echo === setup: ESP-IDF v5.4.1 + esp-matter v1.5 ===
    wsl -- bash -lc "cd '%DEV_DIR_WSL%' && ./scripts/build.sh setup"
    exit /b !errorlevel!
)
if "%DO_MENUCONFIG%"=="1" (
    echo === menuconfig ===
    wsl -- bash -lc "cd '%DEV_DIR_WSL%' && ./scripts/build.sh menuconfig"
    exit /b !errorlevel!
)

REM --- Step 1: clean --------------------------------------------------------
if "%DO_CLEAN%"=="1" (
    echo === --clean: wiping build/ + sdkconfig ===
    wsl -- bash -lc "cd '%DEV_DIR_WSL%' && ./scripts/build.sh clean"
    if errorlevel 1 exit /b !errorlevel!
    echo.
)

REM --- Step 2: build --------------------------------------------------------
if "%DO_BUILD%"=="1" (
    set "BUILD_ARGS="
    if "%DO_WIFI%"=="1"       set "BUILD_ARGS=!BUILD_ARGS! --wifi"
    if "%DO_BLE%"=="1"        set "BUILD_ARGS=!BUILD_ARGS! --ble"
    if "%DO_SENSOR%"=="1"     set "BUILD_ARGS=!BUILD_ARGS! --sensor"
    if "%DO_AP%"=="1"         set "BUILD_ARGS=!BUILD_ARGS! --ap"
    if "%DO_STATION%"=="1"    set "BUILD_ARGS=!BUILD_ARGS! --station"
    if "%DO_ESPNOW%"=="1"     set "BUILD_ARGS=!BUILD_ARGS! --espnow"
    if "%DO_CLICKBOARD%"=="1" set "BUILD_ARGS=!BUILD_ARGS! --clickboard"
    if "%DO_CLICKBOARD%"=="1" (
        echo === --build --clickboard: DS2482 Click board ^(I2C-to-1-Wire, MikroBUS 1^) ===
    ) else if "%DO_SENSOR%"=="1" (
        echo === --build --sensor: DS18B20 read test ^(no Matter/BLE^) ===
    ) else if "%DO_AP%"=="1" (
        echo === --build --ap: Wi-Fi SoftAP + web page ^(needs external power^) ===
    ) else if "%DO_STATION%"=="1" (
        echo === --build --station: Wi-Fi client + BLE provisioning + akvalink.local ===
    ) else if "%DO_ESPNOW%"=="1" (
        echo === --build --espnow: ESP-NOW broadcast ^(deep sleep, no hub^) ===
    ) else if "%DO_BLE%"=="1" (
        echo === --build --ble: standalone BLE GATT variant ^(no Matter^) ===
    ) else if "%DO_WIFI%"=="1" (
        echo === --build --wifi: Matter-over-Wi-Fi variant ===
    ) else (
        echo === --build: Matter-over-Thread ^(SED^) ===
    )
    wsl -- bash -lc "cd '%DEV_DIR_WSL%' && ./scripts/build.sh build!BUILD_ARGS!"
    if errorlevel 1 (
        echo [ERROR] Build failed. Aborting.
        exit /b !errorlevel!
    )
    echo.
)

REM --- Resolve default COM port for erase/flash/log -------------------------
set "PORT_AUTO="
set "NEED_AUTO=0"
if "%DO_ERASE%"=="1" if not defined PORT_ERASE set "NEED_AUTO=1"
if "%DO_FLASH%"=="1" if not defined PORT_FLASH set "NEED_AUTO=1"
if "%DO_LOG%"=="1"   if not defined PORT_LOG   set "NEED_AUTO=1"
if "%NEED_AUTO%"=="1" call :detect_port PORT_AUTO

if not defined PORT_ERASE set "PORT_ERASE=%PORT_AUTO%"
if not defined PORT_FLASH set "PORT_FLASH=%PORT_AUTO%"
if not defined PORT_LOG   set "PORT_LOG=%PORT_AUTO%"

REM --- Step 3: erase NVS ----------------------------------------------------
if "%DO_ERASE%"=="1" (
    if not defined PORT_ERASE (
        echo [ERROR] --erase: no NORA-W40 EVK detected ^(VID_303A^&PID_1001^).
        echo         Pass an explicit port: --erase COM62
        exit /b 3
    )
    echo === --erase: NVS region 0x9000..0xefff on !PORT_ERASE! ===
    py -m esptool --chip esp32c6 -p !PORT_ERASE! -b 460800 erase-region 0x9000 0x6000
    if errorlevel 1 ( echo [ERROR] erase-region failed. & exit /b !errorlevel! )
    echo.
)

REM --- Step 4: flash --------------------------------------------------------
if "%DO_FLASH%"=="1" (
    if not defined PORT_FLASH (
        echo [ERROR] --flash: no NORA-W40 EVK detected ^(VID_303A^&PID_1001^).
        echo         Pass an explicit port: --flash COM62
        exit /b 3
    )
    set "VSLUG=thread"
    if "!DO_WIFI!"=="1"    set "VSLUG=wifi"
    if "!DO_BLE!"=="1"     set "VSLUG=ble"
    if "!DO_SENSOR!"=="1"  set "VSLUG=sensor"
    if "!DO_AP!"=="1"      set "VSLUG=ap"
    if "!DO_STATION!"=="1" set "VSLUG=station"
    if "!DO_ESPNOW!"=="1"  set "VSLUG=espnow"
    if "!DO_CLICKBOARD!"=="1" set "VSLUG=!VSLUG!-ds2482"
    set "BLD=%DEV_DIR%\build\!VSLUG!"
    if not exist "!BLD!\akvalink.bin" (
        echo [ERROR] No firmware to flash. Run with --build first.
        echo         Looked at: !BLD!\akvalink.bin
        exit /b 4
    )
    echo === --flash: 4 partitions ^(!VSLUG!^) to !PORT_FLASH! ===
    pushd "!BLD!" >nul
    py -m esptool --chip esp32c6 -p !PORT_FLASH! -b 460800 ^
        --before default-reset --after hard-reset ^
        write-flash --flash-mode dio --flash-size 4MB --flash-freq 80m ^
        0x0      bootloader/bootloader.bin ^
        0x8000   partition_table/partition-table.bin ^
        0xf000   ota_data_initial.bin ^
        0x20000  akvalink.bin
    set "FLASH_RC=!errorlevel!"
    popd >nul
    if !FLASH_RC! NEQ 0 ( echo [ERROR] write-flash failed. & exit /b !FLASH_RC! )
    echo.
)

REM --- Step 5: log (serial monitor) -----------------------------------------
if "%DO_LOG%"=="1" (
    if not defined PORT_LOG (
        echo [ERROR] --log: no NORA-W40 EVK detected ^(VID_303A^&PID_1001^).
        echo         Pass an explicit port: --log COM62
        exit /b 3
    )
    if not exist "%LOGS_DIR%" mkdir "%LOGS_DIR%" >nul 2>&1
    for /f "usebackq" %%T in (`powershell -NoProfile -Command "(Get-Date).ToString('yyyyMMdd-HHmmss')"`) do set "TS=%%T"
    set "LOGFILE=%LOGS_DIR%\nora-w40-!TS!.log"
    echo === --log: monitor !PORT_LOG! -^> !LOGFILE! ===
    echo     ^(Ctrl+C to stop^)
    if not defined PYEXE (
        echo [ERROR] --log requires Python 3 + pyserial ^(pip install pyserial^).
        exit /b 4
    )
    %PYEXE% "%SCRIPT_DIR%\scripts\monitor_com.py" --port !PORT_LOG! --log-file "!LOGFILE!"
    exit /b !errorlevel!
)

exit /b 0

REM ========================================================================
REM Helper: autodetect first NORA-W40 COM port (VID_303A&PID_1001).
REM Sets the variable named in %1.
REM ========================================================================
:detect_port
set "_OUT_VAR=%~1"
set "%_OUT_VAR%="
if not defined PYEXE (
    echo     [autodetect] Python 3 + pyserial required ^(pip install pyserial^).
    exit /b 0
)
for /f "usebackq tokens=*" %%P in (`%PYEXE% "%SCRIPT_DIR%\scripts\detect_nora_w40_port.py" 2^>nul`) do set "%_OUT_VAR%=%%P"
if defined %_OUT_VAR% (
    call echo     [autodetect] NORA-W40 EVK on %%%_OUT_VAR%%%
) else (
    echo     [autodetect] No NORA-W40 EVK found ^(VID_303A^&PID_1001^).
)
exit /b 0

REM ========================================================================
:app_build
REM Flutter companion app. Default target = windows (this host).
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

pushd "%SCRIPT_DIR%\app_flutter"
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
echo   akvalink.cmd setup                   One-time ESP-IDF + esp-matter install
echo   akvalink.cmd menuconfig              idf.py menuconfig ^(interactive^)
echo.
echo Variant flags ^(one at a time^):
echo   --wifi  --ble  --ap  --station  --espnow  --sensor  --clickboard
echo.
echo APP ^(Flutter companion, built natively^):
echo   akvalink.cmd --app                   Build for Windows ^(default^)
echo   akvalink.cmd --app --android         Build the Android APK
echo   akvalink.cmd --app --run             Run the app on this machine
echo   akvalink.cmd --app --ios ^| --macos   ^(require a Mac -- use ./akvalink.sh^)
echo.
echo Examples:
echo   akvalink.cmd --build --erase --flash --log
echo   akvalink.cmd --rebuild --wifi
echo   akvalink.cmd --flash COM62 --log COM62
echo   akvalink.cmd --log
echo.
echo Autodetect: looks for VID_303A^&PID_1001 ^(NORA-W40 native USB-Serial/JTAG^).
echo On Linux/macOS use the sibling script:  ./akvalink.sh
exit /b 0