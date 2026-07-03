// SPDX-License-Identifier: Apache-2.0
#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

// Start the standalone Wi-Fi station variant (--station): joins the home Wi-Fi
// as a client, provisioned over BLE using Espressif Unified Provisioning (the
// free "ESP BLE Provisioning" app). Once connected it advertises mDNS
// "akvalink.local" and serves the shared temperature page (see web_page.h).
// No Matter, no hub — just the phone/app on the same LAN.
//
// Credentials are stored in NVS; on later boots it reconnects silently and
// only re-enters BLE provisioning if it has none. Long-press logic for
// re-provisioning is a future addition (see TODO.md).
esp_err_t akvalink_station_start(void);

#ifdef __cplusplus
}
#endif
