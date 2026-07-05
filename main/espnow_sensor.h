// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// ESP-NOW broadcast payload — sent once per wake cycle.
//
// Both sender (AkvaLink) and receiver (friends' devices) must agree on this
// layout. Keep it versioned so the receiver can ignore unknown formats.
//
// Wire format: little-endian, packed (no padding between fields).
// ---------------------------------------------------------------------------

#define AKVALINK_ESPNOW_VERSION 1

typedef struct __attribute__((packed)) {
    uint8_t  version;        // always AKVALINK_ESPNOW_VERSION
    int16_t  temperature_c;  // temperature in 0.01 °C units (same as BLE/Matter)
    uint16_t battery_mv;     // battery voltage in mV; 0 = not measured yet
    uint32_t seq;            // boot-count sequence number (from RTC memory)
    uint8_t  mac[6];         // sender MAC address (for multi-device deployments)
} akvalink_espnow_payload_t;

// Start the ESP-NOW sensor: init Wi-Fi + ESP-NOW, broadcast one reading, then
// go to deep sleep for CONFIG_AKVALINK_ESPNOW_SLEEP_S seconds.
// Never returns.
void akvalink_espnow_start(void);

#ifdef __cplusplus
}
#endif
