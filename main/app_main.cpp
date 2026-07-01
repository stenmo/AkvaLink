// SPDX-License-Identifier: Apache-2.0
//
// NORA-W40 (ESP32-C6) Matter Thermometer — single-SoC, Matter-over-Thread SED.
//
// Boots Matter via esp-matter, registers a Temperature Sensor endpoint, then
// kicks off the DS18B20 sampling task. Sensor wiring + GPIO choice documented
// in app_priv.h and ../README.md.

#include "app_priv.h"
#include "ds18b20_task.h"

#include "esp_log.h"
#include "nvs_flash.h"

#include <esp_matter.h>
#include <esp_matter_console.h>
#include <esp_matter_ota.h>

#include <app/server/Server.h>
#include <esp_pm.h>

#if CHIP_DEVICE_CONFIG_ENABLE_THREAD
#include <openthread/instance.h>
#include <openthread/thread.h>
#include <esp_openthread.h>
#endif

#if CHIP_DEVICE_CONFIG_ENABLE_THREAD
#include <platform/ESP32/OpenthreadLauncher.h>

// OpenThread platform-config macros (per esp-matter example convention,
// each example defines its own — values cribbed from examples/light/app_priv.h).
#define ESP_OPENTHREAD_DEFAULT_RADIO_CONFIG()       \
    { .radio_mode = RADIO_MODE_NATIVE, }

#define ESP_OPENTHREAD_DEFAULT_HOST_CONFIG()        \
    { .host_connection_mode = HOST_CONNECTION_MODE_NONE, }

#define ESP_OPENTHREAD_DEFAULT_PORT_CONFIG()        \
    { .storage_partition_name = "nvs", .netif_queue_size = 10, .task_queue_size = 10, }
#endif

using namespace esp_matter;
using namespace esp_matter::endpoint;
using namespace chip::app::Clusters;

static const char * TAG = "app_main";

uint16_t g_temp_endpoint_id = 0;

// ---------------------------------------------------------------------------
// Boot banner — a small nod to https://poolmicke.se/ (Micke's "personlig och
// transparent" pool-building site that inspired the warm, focused vibe of
// this demo: do one thing well, talk plainly, share what you learn).
// Cyan = water, bold white = brand, dim gray = credit. Pure escape sequences,
// no terminal-specific assumptions beyond ANSI.
// ---------------------------------------------------------------------------
static void print_banner(void)
{
    ESP_LOGI(TAG, "");
    ESP_LOGI(TAG, "\033[96m   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\033[0m");
    ESP_LOGI(TAG, "\033[96m  ~  \033[1;97m🏊  AquaLink  \033[1;96m\xF0\x9F\x8C\x8A\033[0m\033[96m   ~\033[0m");
    ESP_LOGI(TAG, "\033[96m   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\033[0m");
    ESP_LOGI(TAG, "  \033[37mbattery-powered Matter pool sensor · NORA-W40\033[0m");
    ESP_LOGI(TAG, "  \033[37minspired by \033[96mpoolmicke.se\033[37m — tack Micke! \xF0\x9F\x87\xB8\xF0\x9F\x87\xAA\033[0m");
    ESP_LOGI(TAG, "");
}

// ---------------------------------------------------------------------------
// Matter event callback. Mostly informational — we just log lifecycle events
// so the demo log tells a clear story (commissioning ✓, Thread up ✓, …).
// ---------------------------------------------------------------------------
static void on_matter_event(const ChipDeviceEvent * event, intptr_t)
{
    switch (event->Type) {
        case chip::DeviceLayer::DeviceEventType::kThreadConnectivityChange:
            ESP_LOGI(TAG, "🧵 Thread connectivity changed: %s",
                     event->ThreadConnectivityChange.Result ==
                         chip::DeviceLayer::kConnectivity_Established
                             ? "ESTABLISHED"
                             : "LOST");
            break;
        case chip::DeviceLayer::DeviceEventType::kCommissioningComplete:
            ESP_LOGI(TAG, "🎉 Commissioning complete!");
            break;
        case chip::DeviceLayer::DeviceEventType::kFabricRemoved:
            ESP_LOGW(TAG, "Fabric removed");
            break;
        default:
            break;
    }
}

// ---------------------------------------------------------------------------
// Per-cluster identify callback (spec-required). We have no LED to blink on
// the bare EVK in SED mode, so this is a no-op stub. Could toggle a GPIO if
// the demo unit grows an LED later.
// ---------------------------------------------------------------------------
static esp_err_t on_identification(identification::callback_type_t type,
                                   uint16_t endpoint_id,
                                   uint8_t /*effect_id*/,
                                   uint8_t /*effect_variant*/,
                                   void * /*priv*/)
{
    ESP_LOGI(TAG, "Identify on endpoint %u, type=%d", endpoint_id, (int)type);
    return ESP_OK;
}

// Attribute writes from the controller. We don't accept writes on
// MeasuredValue — controllers should only read/subscribe — but the callback
// must exist or the SDK rejects every write with INVALID_ACTION.
static esp_err_t on_attribute_update(attribute::callback_type_t /*type*/,
                                     uint16_t /*endpoint_id*/,
                                     uint32_t /*cluster_id*/,
                                     uint32_t /*attribute_id*/,
                                     esp_matter_attr_val_t * /*val*/,
                                     void * /*priv*/)
{
    return ESP_OK;
}

extern "C" void app_main()
{
    print_banner();

    // --- NVS (Matter fabric storage) ----------------------------------------
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_LOGW(TAG, "Erasing NVS (incompatible / full)");
        ESP_ERROR_CHECK(nvs_flash_erase());
        ESP_ERROR_CHECK(nvs_flash_init());
    }
    ESP_ERROR_CHECK(err);

    // --- Matter node + Temperature Sensor endpoint --------------------------
    node::config_t node_cfg;
    node_t * node = node::create(&node_cfg, on_attribute_update, on_identification);
    if (!node) {
        ESP_LOGE(TAG, "Failed to create Matter node");
        return;
    }

    temperature_sensor::config_t ts_cfg;
    // MeasuredValue 0.01 °C units, int16. Start at "unknown" (NULL); first
    // real DS18B20 sample will overwrite it.
    ts_cfg.temperature_measurement.measured_value      = nullable<int16_t>(0);
    ts_cfg.temperature_measurement.min_measured_value  = nullable<int16_t>(-5500);   // -55.00 °C
    ts_cfg.temperature_measurement.max_measured_value  = nullable<int16_t>(12500);   // 125.00 °C

    endpoint_t * ep = temperature_sensor::create(node, &ts_cfg, ENDPOINT_FLAG_NONE, nullptr);
    if (!ep) {
        ESP_LOGE(TAG, "Failed to create Temperature Sensor endpoint");
        return;
    }
    g_temp_endpoint_id = endpoint::get_id(ep);
    ESP_LOGI(TAG, "Temperature Sensor endpoint id = %u", g_temp_endpoint_id);

#if CHIP_DEVICE_CONFIG_ENABLE_THREAD
    // --- OpenThread platform config (REQUIRED before esp_matter::start) ---
    esp_openthread_platform_config_t ot_config = {
        .radio_config = ESP_OPENTHREAD_DEFAULT_RADIO_CONFIG(),
        .host_config  = ESP_OPENTHREAD_DEFAULT_HOST_CONFIG(),
        .port_config  = ESP_OPENTHREAD_DEFAULT_PORT_CONFIG(),
    };
    set_openthread_platform_config(&ot_config);
#endif

    // --- Power management (explicit light sleep + DFS) -----------------------
#if CONFIG_PM_ENABLE
    esp_pm_config_t pm_config = {
        .max_freq_mhz = CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ,
        .min_freq_mhz = 10,
        .light_sleep_enable = true,
    };
    err = esp_pm_configure(&pm_config);
    if (err == ESP_OK) {
        ESP_LOGI(TAG, "\xE2\x9A\xA1 PM: light sleep enabled, DFS %d↔%d MHz",
                 10, CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ);
    } else {
        ESP_LOGW(TAG, "esp_pm_configure failed: %s (continuing without light sleep)",
                 esp_err_to_name(err));
    }
#endif

    // --- Start Matter (BLE commissioning + Thread join) ---------------------
    err = esp_matter::start(on_matter_event);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_matter::start failed: %d", err);
        return;
    }

    // --- Thread SED poll period (Kconfig symbols not honored by esp-matter) --
#if CHIP_DEVICE_CONFIG_ENABLE_THREAD
    {
        otInstance *ot = esp_openthread_get_instance();
        if (ot) {
            otLinkSetPollPeriod(ot, 120000);  // 120 s — ~0.5 wakeups/min
            ESP_LOGI(TAG, "\xF0\x9F\x94\x8B Thread SED poll period set to %lu ms",
                     otLinkGetPollPeriod(ot));
        }
    }
#endif

    // --- Sensor task --------------------------------------------------------
    ds18b20_task_start();

#ifdef APP_USE_DS2482
    ESP_LOGI(TAG, "✨ NORA-W40 Matter Thermometer up — DS2482 Click (I2C 0x%02X, OW_IO%d), Thread SED",
             APP_DS2482_ADDR, APP_DS2482_CHANNEL);
#else
    ESP_LOGI(TAG, "✨ NORA-W40 Matter Thermometer up — DS18B20 on GPIO%d, Thread SED",
             APP_DS18B20_GPIO);
#endif
}
