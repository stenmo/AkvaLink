// SPDX-License-Identifier: Apache-2.0
//
// AkvaLink ESP-NOW sensor variant.
//
// Deep-sleep loop: boot → read DS18B20 → broadcast temperature via ESP-NOW →
// deep sleep N seconds → repeat.
//
// No hub, no provisioning, no persistent Wi-Fi connection. Broadcasts to
// FF:FF:FF:FF:FF:FF so any ESP-NOW receiver on the same channel picks it up.
// Friends' ESP32 / ESP32-C6 devices running their own ESP-NOW sketches get the
// reading without any pairing. Multi-sensor deployments are disambiguated by
// the MAC address in the payload.
//
// Channel: CONFIG_AKVALINK_ESPNOW_CHANNEL (default 1, 1–13).
// Sleep interval: CONFIG_AKVALINK_ESPNOW_SLEEP_S (default 60 s).
// Payload: akvalink_espnow_payload_t — versioned, packed, little-endian.
//
// Power profile (estimated, pre-PPK2):
//   - Wi-Fi init + ESP-NOW send + ack ≈ 100–300 ms at ~80 mA
//   - Deep sleep ≈ 7 µA (NORA-W40 datasheet)
//   - Average (60 s cycle, 200 ms active) ≈ (200/60000)*80mA + 0.007mA ≈ 0.27 mA
//   → rough 2× AA (2800 mAh) battery life ≈ 1+ years
//   Measure with PPK2 via J3 to get the real number.

#include "espnow_sensor.h"
#include "app_priv.h"

#include <math.h>
#include <string.h>

#include "esp_log.h"
#include "esp_check.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_now.h"
#include "esp_sleep.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "esp_mac.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "onewire_bus.h"
#include "ds18b20.h"

static const char *TAG = "espnow";

// RTC memory survives deep sleep — used for the sequence counter.
static RTC_DATA_ATTR uint32_t s_seq = 0;

// Semaphore set by the ESP-NOW send callback so we can wait for ack/nack.
static SemaphoreHandle_t s_send_done;
static bool              s_send_ok;

// ---------------------------------------------------------------------------
// Sensor read (inline, no FreeRTOS task — we boot, read, sleep)
// ---------------------------------------------------------------------------
static esp_err_t read_temperature(float *celsius)
{
    onewire_bus_handle_t    bus = NULL;
    ds18b20_device_handle_t dev = NULL;
    esp_err_t               ret = ESP_FAIL;

    onewire_bus_config_t bus_cfg = {
        .bus_gpio_num = APP_DS18B20_GPIO,
        .flags = {},
    };
    onewire_bus_rmt_config_t rmt_cfg = { .max_rx_bytes = 10 };
    ESP_RETURN_ON_ERROR(onewire_new_bus_rmt(&bus_cfg, &rmt_cfg, &bus),
                        TAG, "bus create failed");

    onewire_device_iter_handle_t iter = NULL;
    ESP_GOTO_ON_ERROR(onewire_new_device_iter(bus, &iter), cleanup_bus, TAG, "iter alloc");

    onewire_device_t found = {};
    int n = 0;
    while (onewire_device_iter_get_next(iter, &found) == ESP_OK) {
        ds18b20_config_t ds_cfg = {};
        if (ds18b20_new_device(&found, &ds_cfg, &dev) == ESP_OK) {
            ESP_LOGI(TAG, "DS18B20 ROM=0x%016llX", found.address);
            n++;
            break;
        }
    }
    onewire_del_device_iter(iter);

    if (n == 0) {
        ESP_LOGE(TAG, "No DS18B20 found on GPIO%d", APP_DS18B20_GPIO);
        ret = ESP_ERR_NOT_FOUND;
        goto cleanup_bus;
    }

    ds18b20_set_resolution(dev, DS18B20_RESOLUTION_12B);
    ESP_GOTO_ON_ERROR(ds18b20_trigger_temperature_conversion(dev),
                      cleanup_dev, TAG, "conversion trigger failed");
    // 12-bit conversion: ≤750 ms; 800 ms is a comfortable margin.
    vTaskDelay(pdMS_TO_TICKS(800));
    ret = ds18b20_get_temperature(dev, celsius);

cleanup_dev:
    ds18b20_del_device(dev);
cleanup_bus:
    onewire_bus_del(bus);
    return ret;
}

// ---------------------------------------------------------------------------
// ESP-NOW send callback
// ---------------------------------------------------------------------------
static void on_send(const uint8_t * /*mac*/, esp_now_send_status_t status)
{
    s_send_ok = (status == ESP_NOW_SEND_SUCCESS);
    xSemaphoreGiveFromISR(s_send_done, NULL);
}

// ---------------------------------------------------------------------------
// Public entry point (called from app_main, never returns)
// ---------------------------------------------------------------------------
void akvalink_espnow_start(void)
{
    float celsius = NAN;
    esp_err_t err = read_temperature(&celsius);
    if (err != ESP_OK || celsius < -55.0f || celsius > 125.0f) {
        ESP_LOGW(TAG, "Sensor read failed (%s) — sending NaN payload",
                 esp_err_to_name(err));
        celsius = NAN;
    }

    // --- Wi-Fi init (station mode, no scan, no association) -----------------
    // ESP-NOW uses the Wi-Fi PHY but never associates with an AP.
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t wcfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&wcfg));
    ESP_ERROR_CHECK(esp_wifi_set_storage(WIFI_STORAGE_RAM));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_start());
    ESP_ERROR_CHECK(esp_wifi_set_channel(CONFIG_AKVALINK_ESPNOW_CHANNEL,
                                         WIFI_SECOND_CHAN_NONE));

    // --- ESP-NOW init -------------------------------------------------------
    ESP_ERROR_CHECK(esp_now_init());
    ESP_ERROR_CHECK(esp_now_register_send_cb(on_send));

    // Add broadcast peer (no encryption — public sensor data).
    esp_now_peer_info_t peer = {};
    memset(peer.peer_addr, 0xFF, ESP_NOW_ETH_ALEN);   // FF:FF:FF:FF:FF:FF
    peer.channel  = CONFIG_AKVALINK_ESPNOW_CHANNEL;
    peer.ifidx    = WIFI_IF_STA;
    peer.encrypt  = false;
    ESP_ERROR_CHECK(esp_now_add_peer(&peer));

    // --- Build payload -------------------------------------------------------
    akvalink_espnow_payload_t payload = {};
    payload.version       = AKVALINK_ESPNOW_VERSION;
    payload.temperature_c = isnanf(celsius) ? INT16_MIN
                            : (int16_t)lroundf(celsius * 100.0f);
    payload.battery_mv    = 0;   // ADC not wired yet
    payload.seq           = s_seq++;
    esp_read_mac(payload.mac, ESP_MAC_WIFI_STA);

    // --- Send (wait for callback, 500 ms timeout) ---------------------------
    s_send_done = xSemaphoreCreateBinary();
    const uint8_t bcast[6] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    err = esp_now_send(bcast, (uint8_t *)&payload, sizeof(payload));
    if (err == ESP_OK) {
        xSemaphoreTake(s_send_done, pdMS_TO_TICKS(500));
        ESP_LOGI(TAG, "%s %.2f °C seq=%lu → %s",
                 isnanf(celsius) ? "NaN" : "📡",
                 isnanf(celsius) ? 0.0f : celsius,
                 (unsigned long)payload.seq,
                 s_send_ok ? "sent ✓" : "nack ✗");
    } else {
        ESP_LOGE(TAG, "esp_now_send failed: %s", esp_err_to_name(err));
    }

    // --- Deep sleep ----------------------------------------------------------
    int sleep_s = CONFIG_AKVALINK_ESPNOW_SLEEP_S;
    ESP_LOGI(TAG, "😴 deep sleep %d s (seq=%lu)", sleep_s, (unsigned long)payload.seq);
    esp_deep_sleep(((uint64_t)sleep_s) * 1000000ULL);
    // never returns
}
