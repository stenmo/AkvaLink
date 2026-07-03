@echo off
REM ==========================================================================
REM  AkvaLink web preview server.
REM  Serves this web\ folder at http://localhost:8000/ so the landing pages
REM  (index.html / index.sv.html) run with a real origin -- Web Bluetooth and
REM  the one-click OTA fetch need http://localhost, not a bare file:// URL.
REM
REM  Usage: double-click serve.cmd, or from a shell:  web\serve.cmd
REM  Stop:  Ctrl+C
REM ==========================================================================
setlocal
cd /d "%~dp0"

echo.
echo   AkvaLink web preview
echo   Serving %~dp0
echo   Open  http://localhost:8000/index.html   (EN)
echo         http://localhost:8000/index.sv.html (SV)
echo   Press Ctrl+C to stop.
echo.

REM Open the English page in the default browser (server comes up right after).
start "" "http://localhost:8000/index.html"

REM Bind to localhost only -- never expose the preview on the network.
py -3 -m http.server 8000 --bind 127.0.0.1

endlocal
