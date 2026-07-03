#!/usr/bin/env bash
# build.sh — Linux/WSL build for the NORA-W40 Matter Thermometer.
#
# Uses Espressif's officially-supported workflow:
#   • ESP-IDF v5.4.1            ($IDF_PATH        = ~/esp/esp-idf)
#   • esp-matter release/v1.5   ($ESP_MATTER_PATH = ~/esp/esp-matter)
#
# Both are cloned and installed manually (NOT via IDF Component Manager —
# the Component Manager workflow is broken for esp-matter because of its
# nested connectedhomeip submodule paths).
#
# Same command surface as build.cmd:
#   build.sh setup                 One-time install of IDF + esp-matter
#   build.sh build                 Build firmware (default = Thread SED)
#   build.sh build --wifi          Build the Wi-Fi variant
#   build.sh menuconfig            idf.py menuconfig
#   build.sh flash <PORT>          Flash via idf.py
#   build.sh monitor <PORT>        idf.py monitor
#   build.sh clean                 Wipe build dir
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Tool locations (WSL home, NOT mounted Windows paths) -------------------
# Espressif explicitly warns against running esp-matter from a /mnt/c path.
IDF_VERSION="v5.4.1"
IDF_PATH="${IDF_PATH:-${HOME}/esp/esp-idf}"
ESP_MATTER_PATH="${ESP_MATTER_PATH:-${HOME}/esp/esp-matter}"

cmd="${1:-help}"

setup_one_time() {
    echo "=== Step 1/3: ESP-IDF ${IDF_VERSION} ==="
    if [ -f "${IDF_PATH}/export.sh" ]; then
        echo "  already at ${IDF_PATH}"
    else
        mkdir -p "$(dirname "${IDF_PATH}")"
        git clone --branch "${IDF_VERSION}" --depth 1 --shallow-submodules \
            --recurse-submodules \
            https://github.com/espressif/esp-idf.git "${IDF_PATH}"
    fi
    "${IDF_PATH}/install.sh" esp32c6

    echo "=== Step 2/3: esp-matter release/v1.5 ==="
    if [ -f "${ESP_MATTER_PATH}/install.sh" ]; then
        echo "  already at ${ESP_MATTER_PATH}"
    else
        mkdir -p "$(dirname "${ESP_MATTER_PATH}")"
        git clone --branch release/v1.5 --depth 1 --shallow-submodules \
            https://github.com/espressif/esp-matter.git "${ESP_MATTER_PATH}"
        ( cd "${ESP_MATTER_PATH}" && git submodule update --init --depth 1 )
    fi
    ( cd "${ESP_MATTER_PATH}/connectedhomeip/connectedhomeip" \
        && ./scripts/checkout_submodules.py --platform esp32 linux --shallow )

    echo "=== Step 3/3: esp-matter install (pigweed bootstrap + host tools) ==="
    # shellcheck source=/dev/null
    . "${IDF_PATH}/export.sh"
    ( cd "${ESP_MATTER_PATH}" && ./install.sh --no-host-tool )

    echo
    echo "=== Setup complete. Run: $0 build ==="
}

activate_env() {
    [ -f "${IDF_PATH}/export.sh" ] \
        || { echo "ERROR: ESP-IDF not installed. Run: $0 setup" >&2; exit 1; }
    [ -f "${ESP_MATTER_PATH}/export.sh" ] \
        || { echo "ERROR: esp-matter not installed. Run: $0 setup" >&2; exit 1; }
    # shellcheck source=/dev/null
    . "${IDF_PATH}/export.sh"
    export ESP_MATTER_PATH
    # shellcheck source=/dev/null
    . "${ESP_MATTER_PATH}/export.sh"
    # esp-matter components live here; expose as EXTRA_COMPONENT_DIRS so the
    # device-firmware CMake project picks up esp_matter, esp_matter_console,
    # esp_matter_ota, etc. without going through the Component Manager.
    export EXTRA_COMPONENT_DIRS="${ESP_MATTER_PATH}/components"
    export IDF_CCACHE_ENABLE=1
}

# Map build sub-options → a variant slug + its sdkconfig defaults, so each
# variant lives in its OWN build directory (build/<variant>) with its OWN
# sdkconfig (build/<variant>/sdkconfig). That isolation is what lets you switch
# variants without a full reconfigure/rebuild — each keeps its own ccache.
# Sets: VARIANT, SDKCFG, CMAKE_EXTRA, BUILD_DIR, NO_MATTER, BLE_ONLY.
resolve_variant() {
    local wifi=0 ble=0 sensor=0 ap=0 station=0 clickboard=0 arg
    for arg in "$@"; do
        case "$arg" in
            --wifi)       wifi=1 ;;
            --ble)        ble=1 ;;
            --sensor)     sensor=1 ;;
            --ap)         ap=1 ;;
            --station)    station=1 ;;
            --clickboard) clickboard=1 ;;
            *) echo "Unknown build option: $arg" >&2; exit 1 ;;
        esac
    done
    if [ "$ble" -eq 1 ]; then
        VARIANT="ble";    SDKCFG="sdkconfig.defaults;sdkconfig.defaults.ble"
    elif [ "$sensor" -eq 1 ]; then
        VARIANT="sensor"; SDKCFG="sdkconfig.defaults;sdkconfig.defaults.sensor"
    elif [ "$ap" -eq 1 ]; then
        VARIANT="ap";     SDKCFG="sdkconfig.defaults;sdkconfig.defaults.ap"
    elif [ "$station" -eq 1 ]; then
        VARIANT="station"; SDKCFG="sdkconfig.defaults;sdkconfig.defaults.station"
    elif [ "$wifi" -eq 1 ]; then
        VARIANT="wifi";   SDKCFG="sdkconfig.defaults;sdkconfig.defaults.wifi"
    else
        VARIANT="thread"; SDKCFG="sdkconfig.defaults"
    fi
    CMAKE_EXTRA=""
    if [ "$clickboard" -eq 1 ]; then
        CMAKE_EXTRA="-DAPP_USE_DS2482=1"
        VARIANT="${VARIANT}-ds2482"
    fi
    NO_MATTER=0; BLE_ONLY=0; AP_ONLY=0; STATION_ONLY=0
    [ "$ble" -eq 1 ] && { NO_MATTER=1; BLE_ONLY=1; }
    [ "$sensor" -eq 1 ] && NO_MATTER=1
    [ "$ap" -eq 1 ] && { NO_MATTER=1; AP_ONLY=1; }
    [ "$station" -eq 1 ] && { NO_MATTER=1; STATION_ONLY=1; }
    BUILD_DIR="build/${VARIANT}"
}

case "$cmd" in
    setup)
        setup_one_time
        ;;

    build)
        activate_env
        cd "${SCRIPT_DIR}"
        resolve_variant "${@:2}"

        if [ -n "$CMAKE_EXTRA" ]; then
            echo "=== Sensor: DS2482 Click board (I2C-to-1-Wire on MikroBUS 1) ==="
        else
            echo "=== Sensor: direct 1-Wire GPIO15 (RMT bit-bang) ==="
        fi
        case "$VARIANT" in
            ble*)    echo "=== Network: BLE-only (standalone NimBLE GATT, no Matter) ===" ;;
            sensor*) echo "=== Sensor-only test: read the sensor, no Matter/BLE ===" ;;
            ap*)     echo "=== Network: Wi-Fi SoftAP + captive web page (needs external power) ===" ;;
            station*) echo "=== Network: Wi-Fi client (BLE-provisioned) + akvalink.local web page ===" ;;
            wifi*)   echo "=== Network: Matter-over-Wi-Fi ===" ;;
            *)       echo "=== Network: Matter-over-Thread (SED) — battery target ===" ;;
        esac
        [ "$NO_MATTER" -eq 1 ] && export AKVALINK_NO_MATTER=1
        [ "$BLE_ONLY" -eq 1 ]  && export AKVALINK_BLE=1
        [ "$AP_ONLY" -eq 1 ]   && export AKVALINK_AP=1
        [ "$STATION_ONLY" -eq 1 ] && export AKVALINK_STATION=1

        echo "=== Build dir: ${BUILD_DIR} (isolated — no rebuild when switching variants) ==="
        idf.py -B "${BUILD_DIR}" -D SDKCONFIG="${BUILD_DIR}/sdkconfig" \
            -D SDKCONFIG_DEFAULTS="${SDKCFG}" $CMAKE_EXTRA reconfigure
        idf.py -B "${BUILD_DIR}" -D SDKCONFIG="${BUILD_DIR}/sdkconfig" build

        mkdir -p "images/${VARIANT}"
        cp -f "${BUILD_DIR}/bootloader/bootloader.bin"           "images/${VARIANT}/bootloader.bin"
        cp -f "${BUILD_DIR}/partition_table/partition-table.bin" "images/${VARIANT}/partition-table.bin"
        cp -f "${BUILD_DIR}/ota_data_initial.bin"                "images/${VARIANT}/ota_data_initial.bin"
        cp -f "${BUILD_DIR}/akvalink.bin"                         "images/${VARIANT}/akvalink.bin"
        echo
        echo "=== Build complete. Images in images/${VARIANT}/ ==="
        ;;

    menuconfig)
        activate_env
        cd "${SCRIPT_DIR}"
        resolve_variant "${@:2}"
        idf.py -B "${BUILD_DIR}" -D SDKCONFIG="${BUILD_DIR}/sdkconfig" menuconfig
        ;;

    flash)
        activate_env
        cd "${SCRIPT_DIR}"
        port="${2:-}"
        [ -n "$port" ] || { echo "Usage: $0 flash <PORT> [--wifi|--ble|--sensor] [--clickboard]"; exit 1; }
        resolve_variant "${@:3}"
        idf.py -B "${BUILD_DIR}" -D SDKCONFIG="${BUILD_DIR}/sdkconfig" -p "$port" flash
        ;;

    monitor)
        activate_env
        cd "${SCRIPT_DIR}"
        port="${2:-}"
        [ -n "$port" ] || { echo "Usage: $0 monitor <PORT> [--wifi|--ble|--sensor]"; exit 1; }
        resolve_variant "${@:3}"
        idf.py -B "${BUILD_DIR}" -p "$port" monitor
        ;;

    clean)
        rm -rf "${SCRIPT_DIR}/build" "${SCRIPT_DIR}/sdkconfig"
        echo "Cleaned."
        ;;

    *)
        cat <<EOF
Usage: $0 <command> [args]

Commands:
  setup                     One-time install of ESP-IDF v5.4.1 + esp-matter v1.5
  build                     Build firmware (default = Thread SED, battery)
  build --wifi              Build the Matter-over-Wi-Fi variant
  build --ble               Build the standalone BLE GATT variant (no Matter)
  build --sensor            Build the sensor read test (no Matter/BLE)
  build --clickboard        Build with DS2482 I2C-to-1-Wire Click board (MikroBUS 1)
  build --clickboard --wifi Combine both options
  menuconfig [--wifi|...]   Open idf.py menuconfig for a variant
  flash    <PORT> [--wifi]  Flash a variant to NORA-W40 EVK (e.g. /dev/ttyUSB0)
  monitor  <PORT> [--wifi]  idf.py monitor a variant
  clean                     Wipe build/ and sdkconfig

Each variant builds into its OWN directory (build/thread, build/wifi, build/ble,
build/sensor, +'-ds2482' for the Click board) with its own sdkconfig, so you can
switch variants without a reconfigure or rebuild.

Paths:
  IDF_PATH         = ${IDF_PATH}
  ESP_MATTER_PATH  = ${ESP_MATTER_PATH}

This script is intended for Linux / WSL2. From Windows, run:
  launch-akvalink-wsl.cmd build
EOF
        ;;
esac
