// SPDX-License-Identifier: Apache-2.0
#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

// Start the standalone Wi-Fi station variant (--station): joins the home Wi-Fi
// as a client, provisioned over BLE using Espressif Unified Provisioning (the
// free "ESP BLE Provisioning" app). Once connected it advertises mDNS
// "akvalink-<last4mac>.local" (unique per device), serves the shared temperature
// page (see web_page.h), and publishes temperature readings to the configured
// MQTT broker for Home Assistant autodiscovery. No Matter, no hub.
esp_err_t akvalink_station_start(void);

// Push the latest temperature (deg C). Updates the web page AND publishes to
// MQTT (if connected). Called by the DS18B20 sampling task on each reading.
void akvalink_station_set_temperature(float celsius);

#ifdef __cplusplus
}
#endif
