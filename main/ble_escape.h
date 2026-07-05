// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "esp_err.h"

// Minimal BLE escape hatch: DIS (0x180A) + ESS Temperature (0x181A).
// Active when CONFIG_AKVALINK_BLE_ESCAPE_HATCH=y and GPIO9 is held at boot.
// Uses legacy ble_gap_adv API — compatible with BT_NIMBLE_EXT_ADV=n.
// The linker dead-strips this module when akvalink_ble_escape_start() is
// never called (i.e. when CONFIG_AKVALINK_BLE_ESCAPE_HATCH=n).

esp_err_t akvalink_ble_escape_start(void);
void      akvalink_ble_escape_set_temperature(float celsius);
