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
# Activated by CONFIG_AQUALINK_BLE_ONLY (launcher: --ble-only).
if(CONFIG_AQUALINK_BLE_ONLY)
    list(APPEND SRCS "ble_gatt.cpp")
endif()

idf_component_register(
    SRCS ${SRCS}
    INCLUDE_DIRS
        "."
    PRIV_REQUIRES
        nvs_flash
        driver
        esp_timer
        esp_matter
        esp_matter_console
        chip
        bt
        openthread
        mbedtls
        espressif__ds18b20
        espressif__onewire_bus
)

if(APP_USE_DS2482)
    target_compile_definitions(${COMPONENT_LIB} PUBLIC APP_USE_DS2482=1)
    message(STATUS "🔌 DS2482 I2C-to-1-Wire Click board mode (MikroBUS 1, OW_IO0)")
endif()
