// SPDX-License-Identifier: Apache-2.0
#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

// Shared HTTP temperature page, used by the --ap (SoftAP) and --station (Wi-Fi
// client) variants. Serves a self-contained page at "/" that polls "/temp"
// (JSON) and shows the live DS18B20 temperature. Does NOT register the "/*"
// catch-all — call akvalink_web_finish_server() after registering any extra
// routes (see station_web.cpp's /mqtt-status).
esp_err_t akvalink_web_start_server(void);

// Registers the "/*" catch-all handler. Must be called last, after every
// other route is registered — with httpd_uri_match_wildcard, a handler
// registered AFTER a matching wildcard is silently rejected as "already
// registered" and requests fall through to the wildcard instead.
void akvalink_web_finish_server(void);

// Push the latest temperature (deg C) for the page to serve. Called by the
// DS18B20 sampling task on each reading.
void akvalink_web_set_temperature(float celsius);

// Set battery level (0-100 %). Call when ADC reading is available.
// Pass 255 (default) to report "unknown" — the indicator will be hidden.
void akvalink_web_set_battery(uint8_t percent);

#ifdef __cplusplus
}
#endif
