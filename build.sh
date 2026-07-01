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

case "$cmd" in
    setup)
        setup_one_time
        ;;

    build)
        activate_env
        cd "${SCRIPT_DIR}"
        # Parse build sub-options (--wifi, --clickboard, combinable)
        build_wifi=0
        build_ble=0
        build_clickboard=0
        for arg in "${@:2}"; do
            case "$arg" in
                --wifi)       build_wifi=1 ;;
                --ble-only)   build_ble=1 ;;
                --clickboard) build_clickboard=1 ;;
                *) echo "Unknown build option: $arg"; exit 1 ;;
            esac
        done

        cmake_extra=""
        if [ "$build_clickboard" -eq 1 ]; then
            cmake_extra="-DAPP_USE_DS2482=1"
            echo "=== Sensor: DS2482 Click board (I2C-to-1-Wire on MikroBUS 1) ==="
        else
            echo "=== Sensor: direct 1-Wire GPIO15 (RMT bit-bang) ==="
        fi

        if [ "$build_ble" -eq 1 ]; then
            echo "=== Network: BLE-only (standalone NimBLE GATT, no Matter) ==="
            idf.py $cmake_extra -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.defaults.ble" reconfigure
        elif [ "$build_wifi" -eq 1 ]; then
            echo "=== Network: Matter-over-Wi-Fi ==="
            idf.py $cmake_extra -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.defaults.wifi" reconfigure
        else
            echo "=== Network: Matter-over-Thread (SED) — battery target ==="
            idf.py $cmake_extra reconfigure
        fi
        idf.py build
        mkdir -p images
        cp -f build/bootloader/bootloader.bin           images/bootloader.bin
        cp -f build/partition_table/partition-table.bin images/partition-table.bin
        cp -f build/ota_data_initial.bin                images/ota_data_initial.bin
        cp -f build/aqualink.bin                         images/aqualink.bin
        echo
        echo "=== Build complete. Images in images/ ==="
        ;;

    menuconfig)
        activate_env
        cd "${SCRIPT_DIR}"
        idf.py menuconfig
        ;;

    flash)
        activate_env
        cd "${SCRIPT_DIR}"
        port="${2:-}"
        [ -n "$port" ] || { echo "Usage: $0 flash <PORT>  (e.g. /dev/ttyUSB0)"; exit 1; }
        idf.py -p "$port" flash
        ;;

    monitor)
        activate_env
        cd "${SCRIPT_DIR}"
        port="${2:-}"
        [ -n "$port" ] || { echo "Usage: $0 monitor <PORT>"; exit 1; }
        idf.py -p "$port" monitor
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
  build --clickboard        Build with DS2482 I2C-to-1-Wire Click board (MikroBUS 1)
  build --clickboard --wifi Combine both options
  menuconfig                Open idf.py menuconfig
  flash    <PORT>           Flash to NORA-W40 EVK (e.g. /dev/ttyUSB0)
  monitor  <PORT>           idf.py monitor
  clean                     Wipe build/ and sdkconfig

Paths:
  IDF_PATH         = ${IDF_PATH}
  ESP_MATTER_PATH  = ${ESP_MATTER_PATH}

This script is intended for Linux / WSL2. From Windows, run:
  launch-aqualink-wsl.cmd build
EOF
        ;;
esac
