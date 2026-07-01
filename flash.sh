#!/usr/bin/env bash
# flash.sh — Linux/macOS counterpart to flash.cmd.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG_DIR="${SCRIPT_DIR}/images"

PORT="${1:-}"
if [ -z "${PORT}" ]; then
  echo "Usage: $0 /dev/ttyUSB0 [erase] [monitor]"
  exit 1
fi

if [ ! -f "${IMG_DIR}/aqualink.bin" ]; then
  echo "ERROR: No firmware in ${IMG_DIR}. Run: $SCRIPT_DIR/build.sh build"
  exit 2
fi

ESPTOOL=""
if command -v esptool.py >/dev/null 2>&1; then
  ESPTOOL="esptool.py"
else
  echo "ERROR: esptool not found. Install it with:"
  echo "  pip install esptool"
  exit 3
fi

if [ "${2:-}" = "erase" ]; then
  echo "=== Erasing flash on ${PORT} ==="
  "${ESPTOOL}" --chip esp32c6 --port "${PORT}" erase_flash
fi

echo "=== Flashing thermometer firmware to ${PORT} ==="
"${ESPTOOL}" --chip esp32c6 --port "${PORT}" --baud 460800 \
  write_flash --flash_mode dio --flash_size 4MB --flash_freq 80m \
  0x0     "${IMG_DIR}/bootloader.bin" \
  0x20000 "${IMG_DIR}/aqualink.bin" \
  0x8000  "${IMG_DIR}/partition-table.bin" \
  0xf000  "${IMG_DIR}/ota_data_initial.bin"

echo "=== Flash complete ==="
