# SPDX-License-Identifier: Apache-2.0
# AkvaLink -- NORA-W40 (ESP32-C6) single-SoC Matter pool thermometer
#
# Modelled on esp-matter/examples/light/CMakeLists.txt to ensure all
# MATTER_SDK_PATH-derived include/source paths resolve. Built via the
# WSL launcher (akvalink.cmd) which sources export.sh from
# both ESP-IDF v5.4.1 and esp-matter release/v1.5.

cmake_minimum_required(VERSION 3.16)

# PROJECT_VER is deliberately NOT hard-coded here — ESP-IDF reads it from
# version.txt at the repo root (the single source of truth). A release.py bump
# then flows straight into the firmware image AND the BLE Device Information
# Service "firmware revision" (0x2A26), so "flash latest" can compare the
# running version against the newest GitHub release.

# The --ble and --sensor variants set AKVALINK_NO_MATTER in the
# environment (via build.sh). They must NOT pull in the esp-matter component
# glue below: esp-matter's NetworkCommissioning cluster static_assert fails to
# compile when no transport (Thread/Wi-Fi) is enabled. So build a plain
# ESP-IDF project instead. (Env var, not -D, so it's visible everywhere.)
if(DEFINED ENV{AKVALINK_NO_MATTER})

    include($ENV{IDF_PATH}/tools/cmake/project.cmake)
    project(akvalink)

else()

    # --- esp-matter prerequisites ---------------------------------------------

    if(NOT DEFINED ENV{ESP_MATTER_PATH})
        message(FATAL_ERROR
            "ESP_MATTER_PATH is not set. Source ~/esp/esp-matter/export.sh, "
            "or run via akvalink.cmd.")
    endif()

    # Per-chip device HAL path (drives BSP, default pins, etc).
    if(NOT DEFINED ENV{ESP_MATTER_DEVICE_PATH})
        if("${IDF_TARGET}" STREQUAL "esp32c6" OR "${IDF_TARGET}" STREQUAL "")
            set(ENV{ESP_MATTER_DEVICE_PATH} $ENV{ESP_MATTER_PATH}/device_hal/device/esp32c6_devkit_c)
        elseif("${IDF_TARGET}" STREQUAL "esp32h2")
            set(ENV{ESP_MATTER_DEVICE_PATH} $ENV{ESP_MATTER_PATH}/device_hal/device/esp32h2_devkit_c)
        else()
            message(FATAL_ERROR "Unsupported IDF_TARGET '${IDF_TARGET}' for NORA-W40 thermometer.")
        endif()
    endif()

    set(ESP_MATTER_PATH $ENV{ESP_MATTER_PATH})
    set(MATTER_SDK_PATH ${ESP_MATTER_PATH}/connectedhomeip/connectedhomeip)

    # --- IDF + esp-matter project glue ----------------------------------------

    include($ENV{IDF_PATH}/tools/cmake/project.cmake)
    include(${ESP_MATTER_PATH}/examples/common/cmake_common/components_include.cmake)
    include($ENV{ESP_MATTER_DEVICE_PATH}/esp_matter_device.cmake)

    set(EXTRA_COMPONENT_DIRS
        "${ESP_MATTER_PATH}/examples/common"
        "${MATTER_SDK_PATH}/config/esp32/components"
        "${ESP_MATTER_PATH}/components"
        "${ESP_MATTER_PATH}/device_hal/device"
        ${extra_components_dirs_append})

    project(akvalink)

    # Match esp-matter example compile flags (C++17, size-optimised, suppress
    # noisy upstream warnings on RISC-V).
    idf_build_set_property(CXX_COMPILE_OPTIONS "-std=gnu++17;-Os;-DCHIP_HAVE_CONFIG_H;-Wno-overloaded-virtual" APPEND)
    idf_build_set_property(C_COMPILE_OPTIONS "-Os" APPEND)
    idf_build_set_property(COMPILE_OPTIONS "-Wno-format-nonliteral;-Wno-format-security" APPEND)

endif()
