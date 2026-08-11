// SPDX-License-Identifier: Apache-2.0
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Start the display variant's ESP-NOW receiver: init Wi-Fi (station mode, no
// association) on CONFIG_AKVALINK_ESPNOW_CHANNEL and listen for broadcast
// akvalink_espnow_payload_t packets from --espnow sensors. Each valid packet
// is logged and stored as "latest reading" for the future e-ink driver.
// Returns after registering the receive callback (reception is event-driven).
void akvalink_espnow_display_start(void);

#ifdef __cplusplus
}
#endif
