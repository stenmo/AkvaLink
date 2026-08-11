// SPDX-License-Identifier: Apache-2.0
//
// AkvaLink display variant — ESP-NOW receiver half.
//
// Counterpart of espnow_sensor.cpp: sensors broadcast one packed
// akvalink_espnow_payload_t to FF:FF:FF:FF:FF:FF per wake cycle; this device
// sits on the same channel and catches them. No pairing, no provisioning —
// power both ends up and readings arrive.
//
// The radio must stay in RX to catch unscheduled broadcasts, so this variant
// is a mains/USB-powered demo target (like --ap) — no light sleep here. The
// e-ink panel driver isn't implemented yet; the latest reading is kept in
// s_latest_c for it to consume later (see docs/EINK_DISPLAY_PLAN.md).

#include "espnow_display.h"
#include "espnow_sensor.h"   // akvalink_espnow_payload_t — the wire contract

#include <math.h>
#include <string.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_now.h"
#include "esp_wifi.h"

static const char *TAG = "display";

// Latest reading per the most recent packet (any sender). NAN until the
// first packet lands.
static float    s_latest_c   = NAN;
static uint32_t s_rx_count   = 0;

static void on_recv(const esp_now_recv_info_t *info, const uint8_t *data, int len)
{
    if (len != (int)sizeof(akvalink_espnow_payload_t)) {
        ESP_LOGW(TAG, "Ignoring %d-byte packet (want %u)", len,
                 (unsigned)sizeof(akvalink_espnow_payload_t));
        return;
    }
    akvalink_espnow_payload_t p;
    memcpy(&p, data, sizeof(p));
    if (p.version != AKVALINK_ESPNOW_VERSION) {
        ESP_LOGW(TAG, "Ignoring payload version %u (want %u)",
                 p.version, AKVALINK_ESPNOW_VERSION);
        return;
    }

    if (p.temperature_c == INT16_MIN) {
        ESP_LOGW(TAG, "Sensor %02X:%02X:%02X:%02X:%02X:%02X reports no reading (seq=%lu)",
                 p.mac[0], p.mac[1], p.mac[2], p.mac[3], p.mac[4], p.mac[5],
                 (unsigned long)p.seq);
        return;
    }

    float c = p.temperature_c / 100.0f;
    // Heating ↑ red, cooling ↓ blue — same colour language as the sensor logs.
    const char *arrow = "";
    if (!isnanf(s_latest_c)) {
        if (c > s_latest_c + 0.01f)      arrow = " \033[91m\u2191\033[0m";
        else if (c < s_latest_c - 0.01f) arrow = " \033[94m\u2193\033[0m";
    }
    s_latest_c = c;
    s_rx_count++;

    ESP_LOGI(TAG, "\U0001F4E1 %.2f \u00b0C%s  seq=%lu rssi=%d n=%lu from %02X:%02X:%02X:%02X:%02X:%02X",
             c, arrow, (unsigned long)p.seq,
             info->rx_ctrl ? info->rx_ctrl->rssi : 0,
             (unsigned long)s_rx_count,
             p.mac[0], p.mac[1], p.mac[2], p.mac[3], p.mac[4], p.mac[5]);
}

void akvalink_espnow_display_start(void)
{
    // Wi-Fi in station mode, never associates — ESP-NOW only needs the PHY.
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t wcfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&wcfg));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_start());
    // Receiver can't modem-sleep: broadcasts arrive unannounced.
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));
    ESP_ERROR_CHECK(esp_wifi_set_channel(CONFIG_AKVALINK_ESPNOW_CHANNEL,
                                         WIFI_SECOND_CHAN_NONE));

    ESP_ERROR_CHECK(esp_now_init());
    ESP_ERROR_CHECK(esp_now_register_recv_cb(on_recv));

    ESP_LOGI(TAG, "\U0001F4FA Listening for AkvaLink sensors on channel %d",
             CONFIG_AKVALINK_ESPNOW_CHANNEL);
}
