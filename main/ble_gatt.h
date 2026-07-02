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

// Bring up the NimBLE host and register the GATT services (Device Information,
// Environmental Sensing, and a custom AkvaLink service). Starts advertising.
// Only valid in the --ble build — it owns the NimBLE host, which would
// clash with esp-matter's BLE commissioning in the Matter variants.
esp_err_t akvalink_ble_gatt_start(void);

// Publish a new temperature (°C). Updates the Environmental Sensing
// characteristic and notifies a subscribed central, if any.
void akvalink_ble_gatt_set_temperature(float celsius);

#ifdef __cplusplus
}
#endif
