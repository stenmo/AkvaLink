// SPDX-License-Identifier: Apache-2.0
#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

// Start the standalone Wi-Fi AP variant (--ap): brings up an OPEN SoftAP named
// "AkvaLink", a captive-portal DNS hijack, and an HTTP server that serves a
// self-contained page showing the live DS18B20 temperature. No Matter, no BLE,
// no home network needed — any phone/laptop joins the AP and the page opens.
//
// NOTE: an always-on SoftAP keeps the Wi-Fi radio awake — this variant is NOT
// battery-friendly (days, not years). Intended for mains/USB-powered use.
//
// The temperature the page serves is pushed via akvalink_web_set_temperature()
// (see web_page.h), shared with the --station variant.
esp_err_t akvalink_ap_start(void);

#ifdef __cplusplus
}
#endif
