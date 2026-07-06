@echo off
REM ========================================================================
REM Flash NORA-W40 (ESP32-C6) Matter Thermometer
REM ========================================================================
REM
REM Usage:
REM   flash.cmd COM5            Flash thermometer images
REM   flash.cmd COM5 erase      Erase whole flash first (factory reset)
REM   flash.cmd COM5 monitor    Flash, then drop into idf.py monitor
REM ========================================================================

setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "IMG_DIR=%SCRIPT_DIR%\images"

set "PORT=%1"
if "%PORT%"=="" (
    echo ERROR: COM port required.
    echo   flash.cmd COM5
    echo   flash.cmd COM5 erase
    echo   flash.cmd COM5 monitor
    exit /b 1
)

if not exist "%IMG_DIR%\akvalink.bin" (
    echo ERROR: No firmware in %IMG_DIR%.
    echo Run:  build.cmd build   (or drop the four .bin files in manually)
    exit /b 2
)

REM --- Choose esptool ------------------------------------------------------
REM Use the user's system esptool.py. The canonical flasher
REM (akvalink.cmd --flash) uses the ESP-IDF-bundled esptool.
set "ESPTOOL="
where esptool.py >nul 2>&1
if not errorlevel 1 set "ESPTOOL=esptool.py"
if "%ESPTOOL%"=="" (
    echo ERROR: esptool not found. Install it with:
    echo   py -m pip install esptool
    echo Or use the canonical flasher:  akvalink.cmd --flash %PORT%
    exit /b 3
)

REM --- Optional erase ------------------------------------------------------
if /I "%2"=="erase" (
    echo === Erasing flash on %PORT% ===
    "%ESPTOOL%" --chip esp32c6 --port %PORT% erase_flash
    if errorlevel 1 exit /b 4
)

REM --- Flash ---------------------------------------------------------------
echo === Flashing thermometer firmware to %PORT% ===
"%ESPTOOL%" --chip esp32c6 --port %PORT% --baud 460800 ^
    write_flash --flash_mode dio --flash_size 4MB --flash_freq 80m ^
    0x0       "%IMG_DIR%\bootloader.bin" ^
    0x20000   "%IMG_DIR%\akvalink.bin" ^
    0x8000    "%IMG_DIR%\partition-table.bin" ^
    0xf000    "%IMG_DIR%\ota_data_initial.bin"
if errorlevel 1 exit /b 5

echo.
echo === Flash complete ===
if /I "%2"=="monitor" goto :monitor
if /I "%3"=="monitor" goto :monitor
exit /b 0

:monitor
REM Defer to the canonical launcher's serial monitor (needs the IDF env).
echo.
echo Use:  akvalink.cmd --log %PORT%
exit /b 0
