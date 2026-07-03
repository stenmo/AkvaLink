// SPDX-License-Identifier: Apache-2.0
//
// Standalone BLE GATT server for the `--ble` AkvaLink variant.
//
// No Matter, no hub, no router: a phone/app connects directly over BLE and
// reads device info + live temperature. Complements the low-power
// manufacturer-data beacon (glance without connecting).

#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

// Bring up the NimBLE host and register the GATT services (Battery, Device
// Information, Environmental Sensing, and a custom AkvaLink service with
// uptime, writable device name, and alert thresholds). Starts advertising.
esp_err_t akvalink_ble_gatt_start(void);

// Publish a new temperature (°C). Updates the Environmental Sensing
// characteristic and notifies a subscribed central, if any.
void akvalink_ble_gatt_set_temperature(float celsius);

// Update the Battery Level characteristic (0–100 %). Call when ADC reading
// is available; no-op until the ADC circuit is populated (defaults to 100 %).
void akvalink_ble_gatt_set_battery(uint8_t percent);

// Read the alert thresholds as last set via the GATT characteristics.
// Values are in 0.01 °C units; 0 = disabled.
int16_t akvalink_ble_gatt_get_alert_high(void);
int16_t akvalink_ble_gatt_get_alert_low(void);

#ifdef __cplusplus
}
#endif
