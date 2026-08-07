// SPDX-License-Identifier: Apache-2.0
//
// Battery voltage sensing via ADC1 + resistor divider.
//
// Disabled by default (CONFIG_AKVALINK_BATTERY_ADC): no AkvaLink hardware has
// the divider populated yet. When disabled every entry point here is a no-op
// and callers must keep reporting the level as *unknown* rather than guessing.

#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

// True when the firmware was built with battery sensing enabled. Callers use
// this to decide between "report a level" and "report unknown" — do not
// substitute a placeholder percentage when this is false.
bool akvalink_battery_enabled(void);

// Set up ADC1 + calibration. Safe to call once at boot on any variant;
// returns ESP_OK immediately when sensing is disabled.
esp_err_t akvalink_battery_init(void);

// Sample the pack. Writes the battery voltage in millivolts (already scaled
// back up through the divider) and/or the level in percent (0-100); either
// pointer may be NULL. Returns false when disabled or if the read failed, in
// which case the outputs are untouched.
bool akvalink_battery_read(int *out_mv, uint8_t *out_percent);

#ifdef __cplusplus
}
#endif
