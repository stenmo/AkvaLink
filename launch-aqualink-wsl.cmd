@echo off
REM ========================================================================
REM AquaLink -- u-blox NORA-W40 Matter pool thermometer launcher (WSL)
REM ========================================================================
REM Builds via WSL2 (Espressif's officially-supported workflow:
REM ESP-IDF v5.4.1 + esp-matter release/v1.5), but flashes / erases / logs
REM directly from Windows using native esptool + a Python (pyserial) monitor.
REM This avoids usbipd-win attach gymnastics — the EVK's native USB
REM Serial/JTAG (VID_303A^&PID_1001) is already a Windows COM port.
REM
REM Composable flag-style args (per repo convention: --xxx only, no -x):
REM   --build              Build firmware (default if no other action given)
REM   --clean              Wipe build dir + sdkconfig
REM   --rebuild            --clean then --build
REM   --erase    [COM<N>]  Erase NVS region (commissioning data) via esptool
REM   --flash    [COM<N>]  Flash all 4 partitions via esptool
REM   --log      [COM<N>]  Start serial monitor → timestamped log file
REM   --wifi               Build the Matter-over-Wi-Fi variant
REM   --ble-only           Build the standalone BLE GATT variant (no Matter)
REM   --sensor-only        Build the sensor read test (no Matter/BLE)
REM   --help               Show this help
REM
REM COM port is autodetected by VID_303A&PID_1001 if not supplied.
REM Multiple flags may be combined, executed in this order:
REM     --clean → --build → --erase → --flash → --log
REM
REM Bare verbs (legacy; flag form is preferred):
REM   setup                One-time install of IDF + esp-matter (~6 GB)
REM   menuconfig           idf.py menuconfig (interactive)
REM
REM Examples:
REM   launch-aqualink-wsl.cmd
REM   launch-aqualink-wsl.cmd --build --erase --flash --log
REM   launch-aqualink-wsl.cmd --rebuild --wifi
REM   launch-aqualink-wsl.cmd --flash COM62 --log COM62
REM   launch-aqualink-wsl.cmd --log
REM ========================================================================

setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
REM AquaLink is a stand-alone project — DEV_DIR is the repo root itself,
REM not the legacy u-connectMatter companion/opencpu/nora-w40-thermometer/ subdir.
set "DEV_DIR=%SCRIPT_DIR%"
REM Derive the WSL mount path drive-letter-agnostically
REM (E:\other\AquaLink -> /mnt/e/other/AquaLink). Convert backslashes to
REM forward slashes first, then let wslpath map the drive letter + casing.
set "SCRIPT_DIR_FWD=%SCRIPT_DIR:\=/%"
for /f "usebackq delims=" %%P in (`wsl -- wslpath -a "%SCRIPT_DIR_FWD%"`) do set "DEV_DIR_WSL=%%P"
set "LOGS_DIR=%SCRIPT_DIR%\logs"

REM Prefer the cross-platform Python helpers (scripts\*.py, via pyserial) when
REM Python is available; fall back to the Windows-only PowerShell scripts.
set "PYEXE="
where py >nul 2>&1 && set "PYEXE=py -3"
if not defined PYEXE ( where python >nul 2>&1 && set "PYEXE=python" )
REM Only use Python if pyserial is actually importable; else fall back to PS.
if defined PYEXE ( %PYEXE% -c "import serial.tools.list_ports" >nul 2>&1 || set "PYEXE=" )

call "%SCRIPT_DIR%\scripts\common\header.cmd" 2>nul
echo   Platform: u-blox NORA-W40 (Espressif ESP32-C6) -- WSL2 build
echo   Role:     Single-SoC Matter end-node -- Thermometer (DS18B20)
echo   Network:  Matter-over-Thread (SED)  ^|  --wifi for Wi-Fi variant
echo   Sensor:   1-Wire DS18B20 on GPIO15 (EVK J15.4), 4.7 kOhm to +3V3
echo ========================================
echo.

REM --- Parse args -----------------------------------------------------------
set "DO_BUILD=0"
set "DO_CLEAN=0"
set "DO_ERASE=0"
set "DO_FLASH=0"
set "DO_LOG=0"
set "DO_WIFI=0"
set "DO_BLE=0"
set "DO_SENSOR=0"
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
if /I "%A%"=="--ble-only"   ( set "DO_BLE=1"        & set "ANY_FLAG=1" & shift & goto parse_args )
if /I "%A%"=="--sensor-only" ( set "DO_SENSOR=1"     & set "ANY_FLAG=1" & shift & goto parse_args )
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

REM Legacy: bare "flash COM5", "monitor COM5"
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

REM Default: no args = show help (KISS — no implicit action)
if "%ANY_FLAG%"=="0" goto :show_help

REM A bare variant/modifier flag (e.g. --ble-only, --wifi, --sensor-only) with
REM no explicit action defaults to --build, matching --sensor-only ergonomics.
if not "%DO_BUILD%"=="1" if not "%DO_CLEAN%"=="1" if not "%DO_FLASH%"=="1" if not "%DO_ERASE%"=="1" if not "%DO_LOG%"=="1" if not "%DO_SETUP%"=="1" if not "%DO_MENUCONFIG%"=="1" set "DO_BUILD=1"

REM --- Setup / menuconfig short-circuits (mutually exclusive) ---------------
if "%DO_SETUP%"=="1" (
    echo === setup: ESP-IDF v5.4.1 + esp-matter v1.5 ===
    wsl -- bash -lc "cd '%DEV_DIR_WSL%' && ./build.sh setup"
    exit /b !errorlevel!
)
if "%DO_MENUCONFIG%"=="1" (
    echo === menuconfig ===
    wsl -- bash -lc "cd '%DEV_DIR_WSL%' && ./build.sh menuconfig"
    exit /b !errorlevel!
)

REM --- Step 1: clean --------------------------------------------------------
if "%DO_CLEAN%"=="1" (
    echo === --clean: wiping build/ + sdkconfig ===
    wsl -- bash -lc "cd '%DEV_DIR_WSL%' && ./build.sh clean"
    if errorlevel 1 exit /b !errorlevel!
    echo.
)

REM --- Step 2: build --------------------------------------------------------
if "%DO_BUILD%"=="1" (
    set "BUILD_ARGS="
    if "%DO_WIFI%"=="1"       set "BUILD_ARGS=!BUILD_ARGS! --wifi"
    if "%DO_BLE%"=="1"        set "BUILD_ARGS=!BUILD_ARGS! --ble-only"
    if "%DO_SENSOR%"=="1"     set "BUILD_ARGS=!BUILD_ARGS! --sensor-only"
    if "%DO_CLICKBOARD%"=="1" set "BUILD_ARGS=!BUILD_ARGS! --clickboard"
    if "%DO_CLICKBOARD%"=="1" (
        echo === --build --clickboard: DS2482 Click board ^(I2C-to-1-Wire, MikroBUS 1^) ===
    ) else if "%DO_SENSOR%"=="1" (
        echo === --build --sensor-only: DS18B20 read test ^(no Matter/BLE^) ===
    ) else if "%DO_BLE%"=="1" (
        echo === --build --ble-only: standalone BLE GATT variant ^(no Matter^) ===
    ) else if "%DO_WIFI%"=="1" (
        echo === --build --wifi: Matter-over-Wi-Fi variant ===
    ) else (
        echo === --build: Matter-over-Thread ^(SED^) ===
    )
    wsl -- bash -lc "cd '%DEV_DIR_WSL%' && ./build.sh build!BUILD_ARGS!"
    if errorlevel 1 (
        echo [ERROR] Build failed. Aborting.
        exit /b !errorlevel!
    )
    echo.
)

REM --- Resolve a default port for any of erase/flash/log --------------------
REM Used only if the user didn't pass an explicit port to that flag.
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
    if errorlevel 1 (
        echo [ERROR] erase-region failed.
        exit /b !errorlevel!
    )
    echo.
)

REM --- Step 4: flash --------------------------------------------------------
if "%DO_FLASH%"=="1" (
    if not defined PORT_FLASH (
        echo [ERROR] --flash: no NORA-W40 EVK detected ^(VID_303A^&PID_1001^).
        echo         Pass an explicit port: --flash COM62
        exit /b 3
    )
    set "BLD=%DEV_DIR%\build"
    if not exist "!BLD!\aqualink.bin" (
        echo [ERROR] No firmware to flash. Run with --build first.
        echo         Looked at: !BLD!\aqualink.bin
        exit /b 4
    )
    echo === --flash: 4 partitions to !PORT_FLASH! ===
    pushd "!BLD!" >nul
    py -m esptool --chip esp32c6 -p !PORT_FLASH! -b 460800 ^
        --before default-reset --after hard-reset ^
        write-flash --flash-mode dio --flash-size 4MB --flash-freq 80m ^
        0x0      bootloader/bootloader.bin ^
        0x8000   partition_table/partition-table.bin ^
        0xf000   ota_data_initial.bin ^
        0x20000  aqualink.bin
    set "FLASH_RC=!errorlevel!"
    popd >nul
    if !FLASH_RC! NEQ 0 (
        echo [ERROR] write-flash failed.
        exit /b !FLASH_RC!
    )
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
    REM Timestamped log file name: nora-w40-YYYYMMDD-HHMMSS.log
    for /f "usebackq" %%T in (`powershell -NoProfile -Command "(Get-Date).ToString('yyyyMMdd-HHmmss')"`) do set "TS=%%T"
    set "LOGFILE=%LOGS_DIR%\nora-w40-!TS!.log"
    echo === --log: monitor !PORT_LOG! → !LOGFILE! ===
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
REM Helper: autodetect first NORA-W40 COM port via VID_303A&PID_1001
REM Sets the variable named in %1 (passed by name).
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
:show_help
echo Composable flag-style commands ^(executed in order: clean^>build^>erase^>flash^>log^):
echo.
echo   --build              Build firmware ^(Thread SED unless --wifi^)
echo   --clean              Wipe build/ + sdkconfig
echo   --rebuild            --clean then --build
echo   --erase    [COM^<N^>]  Erase NVS via esptool ^(autodetect if no port^)
echo   --flash    [COM^<N^>]  Flash 4 partitions via esptool ^(autodetect if no port^)
echo   --log      [COM^<N^>]  Serial monitor → logs/nora-w40-^<TS^>.log ^(autodetect if no port^)
echo   --wifi               Build the Matter-over-Wi-Fi variant
echo   --ble-only           Build the standalone BLE GATT variant ^(no Matter^)
echo   --sensor-only        Build the sensor read test ^(no Matter/BLE^)
echo   --clickboard         Build with DS2482 Click board ^(I2C-to-1-Wire, MikroBUS 1^)
echo   --help               Show this help
echo.
echo Verbs ^(initial setup^):
echo   setup                One-time install of ESP-IDF + esp-matter ^(~6 GB^)
echo   menuconfig           idf.py menuconfig ^(interactive^)
echo.
echo Examples:
echo   launch-aqualink-wsl.cmd --build --erase --flash --log
echo   launch-aqualink-wsl.cmd --rebuild --wifi
echo   launch-aqualink-wsl.cmd --rebuild --clickboard --flash --log
echo   launch-aqualink-wsl.cmd --flash COM62 --log COM62
echo   launch-aqualink-wsl.cmd --log
echo.
echo Autodetect: looks for VID_303A^&PID_1001 ^(NORA-W40 native USB-Serial/JTAG^).
echo Native esptool ^(`py -m esptool`^) is used for erase/flash — no usbipd needed.
echo.
exit /b 0
