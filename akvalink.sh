#!/usr/bin/env bash
# ==========================================================================
# akvalink.sh -- unified AkvaLink launcher (native Linux / macOS)
# ==========================================================================
# ONE front door for everything, the twin of akvalink.cmd on Windows:
#
#   Firmware  (NORA-W40 / ESP32-C6)  -> forwarded to ./scripts/build.sh (native IDF).
#   App       (Flutter companion)    -> built natively with the Flutter SDK.
#
# Usage:
#   ./akvalink.sh [firmware args...]        Firmware (forwarded to scripts/build.sh)
#   ./akvalink.sh --app                     Build the app for THIS host
#   ./akvalink.sh --app --linux             Build the Linux app
#   ./akvalink.sh --app --macos             Build the macOS app  (needs a Mac)
#   ./akvalink.sh --app --ios               Build the iOS app    (needs a Mac)
#   ./akvalink.sh --app --android           Build the Android APK
#   ./akvalink.sh --app --run               Run the app on this machine
#   ./akvalink.sh --help                    Show this help
#
# Firmware examples (see ./scripts/build.sh for the full set):
#   ./akvalink.sh build --wifi
#   ./akvalink.sh flash /dev/ttyUSB0
# ==========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

uname_s="$(uname -s)"
case "$uname_s" in
    Darwin*) HOST="macos" ;;
    Linux*)  HOST="linux" ;;
    *)       HOST="linux" ;;
esac

show_help() {
    cat <<EOF
AkvaLink -- unified launcher (native ${HOST})

FIRMWARE (NORA-W40, forwarded to ./scripts/build.sh):
  ./akvalink.sh setup                  One-time ESP-IDF + esp-matter install
  ./akvalink.sh build [--wifi|--ble|--ap|--station|--espnow|--sensor]
  ./akvalink.sh flash <PORT> [variant] Flash the EVK (e.g. /dev/ttyUSB0)
  ./akvalink.sh monitor <PORT>         Serial monitor
  ./akvalink.sh clean                  Wipe build/

APP (Flutter companion, built natively):
  ./akvalink.sh --app                  Build for this host (${HOST})
  ./akvalink.sh --app --linux          Build the Linux app
  ./akvalink.sh --app --macos          Build the macOS app  (needs a Mac)
  ./akvalink.sh --app --ios            Build the iOS app     (needs a Mac)
  ./akvalink.sh --app --android        Build the Android APK
  ./akvalink.sh --app --run            Run the app on this machine

On Windows use the sibling script:  akvalink.cmd
EOF
}

# --- Is this an --app invocation? -----------------------------------------
app_mode=0
for a in "$@"; do
    [ "$a" = "--app" ] && app_mode=1
done

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    show_help
    exit 0
fi

# --- Firmware path: forward everything to scripts/build.sh ----------------
if [ "$app_mode" -eq 0 ]; then
    exec "${SCRIPT_DIR}/scripts/build.sh" "$@"
fi

# --- App path -------------------------------------------------------------
target="$HOST"     # default to the host platform
do_run=0
for a in "$@"; do
    case "$a" in
        --app)     ;;
        --linux)   target="linux" ;;
        --macos)   target="macos" ;;
        --ios)     target="ipa" ;;
        --android) target="apk" ;;
        --windows) target="windows" ;;
        --run)     do_run=1 ;;
        *) echo "[ERROR] Unknown --app option: $a" >&2; exit 2 ;;
    esac
done

# Guard platform-specific targets against the wrong host.
if [ "$target" = "windows" ]; then
    echo "[ERROR] Windows app builds require Windows. Use: akvalink.cmd --app --windows" >&2
    exit 3
fi
if { [ "$target" = "macos" ] || [ "$target" = "ipa" ]; } && [ "$HOST" != "macos" ]; then
    echo "[ERROR] $target builds require macOS." >&2
    exit 3
fi

command -v flutter >/dev/null 2>&1 || {
    echo "[ERROR] 'flutter' not found on PATH. Install the Flutter SDK first." >&2
    exit 4
}

cd "${SCRIPT_DIR}/app_flutter"
echo "=== app: flutter pub get ==="
flutter pub get

if [ "$do_run" -eq 1 ]; then
    echo "=== app: flutter run (this machine) ==="
    exec flutter run
fi

echo "=== app: flutter build ${target} ==="
exec flutter build "${target}"
