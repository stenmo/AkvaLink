@echo off
REM ========================================================================
REM AquaLink -- build entry point (compat shim)
REM ========================================================================
REM Native-Windows esp-matter builds are NOT supported: on Windows Espressif
REM requires WSL2 for the esp-matter toolchain (the nested connectedhomeip
REM submodules break the native IDF Component Manager workflow). This shim
REM forwards every argument to the canonical WSL launcher, which builds via
REM ESP-IDF v5.4.1 + esp-matter release/v1.5 -- the latest combination that
REM esp-matter officially supports on the ESP32-C6.
REM
REM   build.cmd setup            One-time IDF + esp-matter install (in WSL)
REM   build.cmd build            Build firmware (Thread SED, default)
REM   build.cmd build --wifi     Build the Matter-over-Wi-Fi variant
REM   build.cmd menuconfig       idf.py menuconfig
REM   build.cmd clean            Wipe build/ + sdkconfig
REM
REM Canonical launcher (more options): launch-aqualink-wsl.cmd --help
REM ========================================================================

setlocal
set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%launch-aqualink-wsl.cmd" %*
exit /b %errorlevel%
