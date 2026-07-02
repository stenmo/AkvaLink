// SPDX-License-Identifier: Apache-2.0
//
// 1-Wire DS18B20 sampling task.
//
// Wakes every APP_SAMPLE_PERIOD_MS, reads the sensor via the espressif/ds18b20
// managed component (RMT-based 1-Wire), and only pushes the value into
// Matter when it changed by more than APP_REPORT_THRESHOLD_C. This keeps
// Thread radio wakeups (and AP/router beacon receptions) to a minimum,
// which is the whole point of running as an SED.

#include "ds18b20_task.h"
#include "app_priv.h"
#include "ble_gatt.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "esp_check.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#ifdef APP_USE_DS2482
#include "ds2482_onewire.h"
#else
#include "onewire_bus.h"
#include "ds18b20.h"
#endif

#if !CONFIG_AQUALINK_BLE_ONLY && !CONFIG_AQUALINK_SENSOR_TEST
#include <esp_matter.h>
#include <esp_matter_attribute_utils.h>

using namespace esp_matter;
using namespace chip::app::Clusters;
#endif

static const char * TAG = "ds18b20";

static float __attribute__((unused)) s_last_pushed_c = -1000.0f;

// ============================================================================
// Sensor abstraction: two compile-time implementations
// ============================================================================

#ifdef APP_USE_DS2482
// ---- DS2482 Click board path (I2C → 1-Wire bridge) -------------------------

static esp_err_t sensor_init(void)
{
    ESP_LOGI(TAG, "🔌 Using DS2482 I2C-to-1-Wire Click board (MikroBUS 1)");
    return ds2482_init(APP_DS2482_SDA, APP_DS2482_SCL,
                       APP_DS2482_ADDR, APP_DS2482_CHANNEL);
}

static esp_err_t sensor_read(float *celsius)
{
    return ds2482_read_temperature(celsius);
}

#if CONFIG_AQUALINK_SENSOR_TEST
static void sensor_print_details(void)
{
    ESP_LOGI(TAG, "──────── DS18B20 sensor details ────────");
    ESP_LOGI(TAG, "  Interface : DS2482-800 I2C→1-Wire @ 0x%02X ch%d (SDA=%d SCL=%d)",
             APP_DS2482_ADDR, APP_DS2482_CHANNEL, APP_DS2482_SDA, APP_DS2482_SCL);
    ESP_LOGI(TAG, "  ROM ID    : (not exposed by the DS2482 driver)");
    ESP_LOGI(TAG, "  Resolution: 12-bit · 0.0625 °C/LSB · ~750 ms conversion");
    ESP_LOGI(TAG, "  Interval  : %d s (sensor test mode)", APP_SENSOR_TEST_PERIOD_MS / 1000);
    ESP_LOGI(TAG, "────────────────────────────────────────");
}
#endif // CONFIG_AQUALINK_SENSOR_TEST

#else
// ---- Direct GPIO path (RMT bit-bang, default) ------------------------------

static onewire_bus_handle_t    s_bus = nullptr;
static ds18b20_device_handle_t s_dev = nullptr;
static uint64_t                s_rom_addr = 0;

static esp_err_t sensor_init(void)
{
    ESP_LOGI(TAG, "📡 Using direct 1-Wire GPIO%d (RMT bit-bang)", APP_DS18B20_GPIO);

    onewire_bus_config_t bus_config = {
        .bus_gpio_num = APP_DS18B20_GPIO,
    };
    onewire_bus_rmt_config_t rmt_config = {
        .max_rx_bytes = 10,
    };
    ESP_RETURN_ON_ERROR(onewire_new_bus_rmt(&bus_config, &rmt_config, &s_bus),
                        TAG, "onewire bus create failed");

    onewire_device_iter_handle_t iter = nullptr;
    ESP_RETURN_ON_ERROR(onewire_new_device_iter(s_bus, &iter), TAG, "iter alloc");

    onewire_device_t dev = {};
    int found = 0;
    while (onewire_device_iter_get_next(iter, &dev) == ESP_OK) {
        ds18b20_config_t ds_cfg = {};
        if (ds18b20_new_device(&dev, &ds_cfg, &s_dev) == ESP_OK) {
            s_rom_addr = dev.address;
            ESP_LOGI(TAG, "Found DS18B20 ROM=0x%016llX", dev.address);
            found++;
            break;
        }
    }
    onewire_del_device_iter(iter);

    if (found == 0) {
        ESP_LOGE(TAG, "No DS18B20 found on GPIO%d — check wiring", APP_DS18B20_GPIO);
        return ESP_ERR_NOT_FOUND;
    }

    // 12-bit: 0.0625 °C step, ~750 ms conversion — the finest the DS18B20
    // offers, so Home shows the best reading the sensor can give (absolute
    // accuracy is still ±0.5 °C). Power is managed via the adaptive sampling
    // modes and the report threshold, not by coarsening resolution.
    return ds18b20_set_resolution(s_dev, DS18B20_RESOLUTION_12B);
}

static esp_err_t sensor_read(float *celsius)
{
    esp_err_t err = ds18b20_trigger_temperature_conversion(s_dev);
    if (err != ESP_OK) return err;
    // 12-bit max conversion time is 750 ms; 800 ms is a comfortable margin.
    vTaskDelay(pdMS_TO_TICKS(800));
    return ds18b20_get_temperature(s_dev, celsius);
}

#if CONFIG_AQUALINK_SENSOR_TEST
static const char *ds_model_name(uint8_t family_code)
{
    switch (family_code) {
    case 0x28: return "DS18B20";
    case 0x22: return "DS1822";
    case 0x3B: return "MAX31820 / DS1825";
    case 0x10: return "DS18S20 / DS1820";
    default:   return "unknown 1-Wire temp sensor";
    }
}

// Read Power Supply (0xB4): a parasitically-powered device holds the bus low
// (reads 0) during the following time slot; an externally-powered one lets it
// float high (reads 1).
static const char *sensor_power_mode(void)
{
    if (!s_bus || onewire_bus_reset(s_bus) != ESP_OK) return "unknown";
    uint8_t cmd[2] = { 0xCC /*Skip ROM*/, 0xB4 /*Read Power Supply*/ };
    if (onewire_bus_write_bytes(s_bus, cmd, sizeof(cmd)) != ESP_OK) return "unknown";
    uint8_t bit = 1;
    if (onewire_bus_read_bit(s_bus, &bit) != ESP_OK) return "unknown";
    return bit ? "external (VDD)" : "parasitic";
}

static void sensor_print_details(void)
{
    uint8_t  family = (uint8_t)(s_rom_addr & 0xFF);
    uint8_t  crc    = (uint8_t)((s_rom_addr >> 56) & 0xFF);
    uint64_t serial = (s_rom_addr >> 8) & 0xFFFFFFFFFFFFULL;

    ESP_LOGI(TAG, "──────── DS18B20 sensor details ────────");
    ESP_LOGI(TAG, "  Interface : direct 1-Wire GPIO%d (RMT bit-bang)", APP_DS18B20_GPIO);
    ESP_LOGI(TAG, "  Model     : %s (family 0x%02X)", ds_model_name(family), family);
    ESP_LOGI(TAG, "  ROM ID    : 0x%016llX", s_rom_addr);
    ESP_LOGI(TAG, "  Serial    : 0x%012llX   ROM CRC 0x%02X", serial, crc);
    ESP_LOGI(TAG, "  Power     : %s", sensor_power_mode());
    ESP_LOGI(TAG, "  Resolution: 12-bit · 0.0625 °C/LSB · ~750 ms conversion");
    ESP_LOGI(TAG, "  Interval  : %d s (sensor test mode)", APP_SENSOR_TEST_PERIOD_MS / 1000);
    ESP_LOGI(TAG, "────────────────────────────────────────");
}
#endif // CONFIG_AQUALINK_SENSOR_TEST

#endif // APP_USE_DS2482

#if !CONFIG_AQUALINK_BLE_ONLY && !CONFIG_AQUALINK_SENSOR_TEST
static void push_to_matter(float celsius)
{
    if (g_temp_endpoint_id == 0) {
        return;                                 // Matter not yet up
    }
    if (fabsf(celsius - s_last_pushed_c) < APP_REPORT_THRESHOLD_C) {
        return;                                 // suppress noise → save radio
    }

    // Matter TemperatureMeasurement::MeasuredValue is int16, 0.01 °C units.
    int16_t measured = (int16_t)lroundf(celsius * 100.0f);

    esp_matter_attr_val_t val = esp_matter_int16(measured);
    attribute::update(g_temp_endpoint_id,
                      TemperatureMeasurement::Id,
                      TemperatureMeasurement::Attributes::MeasuredValue::Id,
                      &val);

    ESP_LOGI(TAG, "📈 Pushed MeasuredValue: %.2f °C (raw %d)", celsius, measured);
    s_last_pushed_c = celsius;
}
#endif  // !CONFIG_AQUALINK_BLE_ONLY

static void sample_task(void *)
{
    if (sensor_init() != ESP_OK) {
        ESP_LOGE(TAG, "Sensor init failed — task exiting, no temperature reports");
        vTaskDelete(nullptr);
        return;
    }

#if CONFIG_AQUALINK_SENSOR_TEST
    // Sensor test mode: print the full sensor identity once, then log a rich
    // reading at a steady 30 s cadence. No adaptive rate, no Matter/BLE — this
    // is purely a bench heartbeat for verifying the probe.
    sensor_print_details();

    float prev_celsius = NAN;
    while (true) {
        float celsius = NAN;
        if (sensor_read(&celsius) == ESP_OK &&
            celsius > -55.0f && celsius < 125.0f) {
            float fahrenheit = celsius * 9.0f / 5.0f + 32.0f;
            if (isnanf(prev_celsius)) {
                ESP_LOGI(TAG, "🌡 %.4f °C  (%.2f °F)", celsius, fahrenheit);
            } else {
                ESP_LOGI(TAG, "🌡 %.4f °C  (%.2f °F)  Δ%+.4f °C since last",
                         celsius, fahrenheit, celsius - prev_celsius);
            }
            prev_celsius = celsius;
        } else {
            ESP_LOGW(TAG, "Sensor read failed or out of range — skipping");
        }
        vTaskDelay(pdMS_TO_TICKS(APP_SENSOR_TEST_PERIOD_MS));
    }
#else
    float prev_celsius = NAN;
    int stable_count = APP_FAST_COUNT;  // start in slow mode
    uint32_t sample_ms = APP_SAMPLE_PERIOD_SLOW_MS;

    ESP_LOGI(TAG, "Adaptive sampling: fast=%dms slow=%dms threshold=%.1f°C",
             APP_SAMPLE_PERIOD_FAST_MS, APP_SAMPLE_PERIOD_SLOW_MS, APP_FAST_THRESHOLD_C);

    while (true) {
        float celsius = NAN;
        if (sensor_read(&celsius) == ESP_OK &&
            celsius > -55.0f && celsius < 125.0f) {
            ESP_LOGD(TAG, "raw read: %.4f °C", celsius);
#if CONFIG_AQUALINK_BLE_ONLY
            aqualink_ble_gatt_set_temperature(celsius);
#else
            push_to_matter(celsius);
#endif

            // Adaptive rate: fast on significant change, slow when stable
            if (!isnanf(prev_celsius) &&
                fabsf(celsius - prev_celsius) >= APP_FAST_THRESHOLD_C) {
                // Temperature is changing — switch to fast sampling
                stable_count = 0;
                if (sample_ms != APP_SAMPLE_PERIOD_FAST_MS) {
                    sample_ms = APP_SAMPLE_PERIOD_FAST_MS;
                    ESP_LOGI(TAG, "⚡ Fast sampling (%d ms) — temp changing rapidly", APP_SAMPLE_PERIOD_FAST_MS);
                }
            } else {
                // Stable reading
                if (stable_count < APP_FAST_COUNT) {
                    stable_count++;
                    if (stable_count >= APP_FAST_COUNT && sample_ms != APP_SAMPLE_PERIOD_SLOW_MS) {
                        sample_ms = APP_SAMPLE_PERIOD_SLOW_MS;
                        ESP_LOGI(TAG, "😴 Slow sampling (%d ms) — temp stable", APP_SAMPLE_PERIOD_SLOW_MS);
                    }
                }
            }
            prev_celsius = celsius;
        } else {
            ESP_LOGW(TAG, "Sensor read failed or out of range — skipping");
        }

        vTaskDelay(pdMS_TO_TICKS(sample_ms));
    }
#endif // CONFIG_AQUALINK_SENSOR_TEST
}

void ds18b20_task_start(void)
{
    BaseType_t r = xTaskCreate(sample_task, "ds18b20",
                               4096, nullptr, tskIDLE_PRIORITY + 2, nullptr);
    if (r != pdPASS) {
        ESP_LOGE(TAG, "Failed to create DS18B20 sampling task");
    }
}
