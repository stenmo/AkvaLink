# SPDX-License-Identifier: Apache-2.0

set(SRCS
    "app_main.cpp"
    "ds18b20_task.cpp"
)

# DS2482 Click board support (I2C-to-1-Wire bridge on MikroBUS 1).
# Activated by: idf.py -DAPP_USE_DS2482=1 build
# or from launcher: --clickboard
if(APP_USE_DS2482)
    list(APPEND SRCS "ds2482_onewire.cpp")
endif()

# Standalone BLE-only variant (no Matter): NimBLE GATT server.
# Gated on the AQUALINK_BLE *environment* var (build.sh --ble-only), NOT a
# CONFIG_ value nor a -D cache var: component SRCS/REQUIRES are expanded before
# Kconfig loads, and -D cache vars aren't visible during that expansion.
if(DEFINED ENV{AQUALINK_BLE})
    list(APPEND SRCS "ble_gatt.cpp")
endif()

# QR-in-console for Matter commissioning: renders the "MT:..." setup payload as
# a scannable ASCII QR (Nayuki qrcodegen, MIT). Needs CHIP's GetQRCode, so it's
# Matter-only — i.e. neither the BLE nor the no-Matter env var is set.
if(NOT DEFINED ENV{AQUALINK_BLE} AND NOT DEFINED ENV{AQUALINK_NO_MATTER})
    list(APPEND SRCS "qrcodegen.c" "qr_console.c")
endif()

# The --ble-only / --sensor-only variants drop the whole Matter stack (with no
# Thread/Wi-Fi transport esp-matter's NetworkCommissioning static_assert fails).
# Gate on env vars for the same expansion-timing reason as above.
set(AQ_PRIV_REQ nvs_flash driver esp_timer
    espressif__ds18b20 espressif__onewire_bus)
if(DEFINED ENV{AQUALINK_BLE})
    list(APPEND AQ_PRIV_REQ bt esp_app_format)
elseif(NOT DEFINED ENV{AQUALINK_NO_MATTER})
    list(APPEND AQ_PRIV_REQ esp_matter esp_matter_console chip openthread mbedtls)
endif()

idf_component_register(
    SRCS ${SRCS}
    INCLUDE_DIRS
        "."
    PRIV_REQUIRES ${AQ_PRIV_REQ}
)

if(APP_USE_DS2482)
    target_compile_definitions(${COMPONENT_LIB} PUBLIC APP_USE_DS2482=1)
    message(STATUS "🔌 DS2482 I2C-to-1-Wire Click board mode (MikroBUS 1, OW_IO0)")
endif()
