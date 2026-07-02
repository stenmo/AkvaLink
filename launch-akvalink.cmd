@echo off
REM ========================================================================
REM AkvaLink -- u-blox NORA-W40 Matter pool thermometer (compat shim)
REM ========================================================================
REM Thin shim: forwards ALL arguments to the canonical WSL launcher.
REM
REM Native-Windows IDF Component Manager workflow fails on esp-matter's
REM nested submodule init (Espressif officially supports only WSL on
REM Windows). Build goes through WSL; erase/flash/log run natively via
REM esptool (no usbipd needed) from inside the WSL launcher.
REM
REM Canonical: launch-akvalink-wsl.cmd --help
REM ========================================================================

setlocal
set "SCRIPT_DIR=%~dp0"
call "%SCRIPT_DIR%launch-akvalink-wsl.cmd" %*
exit /b %errorlevel%