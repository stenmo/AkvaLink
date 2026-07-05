// SPDX-License-Identifier: Apache-2.0
//
// NORA-W40 (ESP32-C6) Matter Thermometer — single-SoC, Matter-over-Thread SED.
//
// Boots Matter via esp-matter, registers a Temperature Sensor endpoint, then
// kicks off the DS18B20 sampling task. Sensor wiring + GPIO choice documented
// in app_priv.h and ../README.md.

#include "app_priv.h"
#include "ds18b20_task.h"
#include "ble_gatt.h"
#include "ap_web.h"
#if CONFIG_AKVALINK_BLE_ESCAPE_HATCH
#include "ble_escape.h"
#endif
#include "station_web.h"
#include "espnow_sensor.h"
#include "qr_console.h"

#include "esp_log.h"
#include "esp_timer.h"
#include "nvs_flash.h"
#include "esp_pm.h"
#include "driver/gpio.h"   // GPIO9 escape hatch in --station (boot into BLE mode)

#if !CONFIG_AKVALINK_BLE_ONLY && !CONFIG_AKVALINK_SENSOR_TEST && \
    !CONFIG_AKVALINK_AP && !CONFIG_AKVALINK_STATION && !CONFIG_AKVALINK_ESPNOW
#include <esp_matter.h>
#include <esp_matter_console.h>
#include <esp_matter_ota.h>

#include <app/server/Server.h>
#include <setup_payload/OnboardingCodesUtil.h>

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
#endif  // !CONFIG_AKVALINK_BLE_ONLY

static const char * TAG = "app_main";

uint16_t g_temp_endpoint_id = 0;

// Set to true in the GPIO9 escape hatch paths (AP and Thread). Causes
// ds18b20_task to route temperature updates to akvalink_ble_escape_set_temperature()
// instead of the main transport (web page / Matter attribute report).
#if CONFIG_AKVALINK_BLE_ESCAPE_HATCH
bool g_ble_escape_active = false;
#endif

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
    ESP_LOGI(TAG, "\033[96m  ~  \033[1;97m🏊  AkvaLink  \033[1;96m\xF0\x9F\x8C\x8A\033[0m\033[96m   ~\033[0m");
    ESP_LOGI(TAG, "\033[96m   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\033[0m");
    ESP_LOGI(TAG, "  \033[37mbattery-powered Matter pool sensor · NORA-W40\033[0m");
    ESP_LOGI(TAG, "  \033[37minspired by \033[96mpoolmicke.se\033[37m — tack Micke! \xF0\x9F\x87\xB8\xF0\x9F\x87\xAA\033[0m");
    ESP_LOGI(TAG, "");
}

// ---------------------------------------------------------------------------
// Automatic light sleep (CPU + peripherals power down between events, DFS down
// to 10 MHz). Shared by the Matter/Thread and BLE-only paths — both are
// battery targets. For BLE this only actually engages once the controller is
// allowed to sleep on a low-power clock that survives light sleep — see
// CONFIG_BT_LE_SLEEP_ENABLE + CONFIG_BT_LE_LP_CLK_SRC_DEFAULT in
// sdkconfig.defaults.ble (the IDF default is the main XTAL, which is powered
// down in sleep, so without those the radio pins the CPU awake at ~8 mA).
// ---------------------------------------------------------------------------
#if CONFIG_PM_ENABLE
static void __attribute__((unused)) configure_light_sleep(void)
{
    esp_pm_config_t pm_config = {
        .max_freq_mhz = CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ,
        .min_freq_mhz = 10,
        .light_sleep_enable = true,
    };
    esp_err_t err = esp_pm_configure(&pm_config);
    if (err == ESP_OK) {
        ESP_LOGI(TAG, "\xE2\x9A\xA1 PM: light sleep enabled, DFS %d↔%d MHz",
                 10, CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ);
    } else {
        ESP_LOGW(TAG, "esp_pm_configure failed: %s (continuing without light sleep)",
                 esp_err_to_name(err));
    }
}
#endif

#if !CONFIG_AKVALINK_BLE_ONLY && !CONFIG_AKVALINK_SENSOR_TEST && \
    !CONFIG_AKVALINK_AP && !CONFIG_AKVALINK_STATION && !CONFIG_AKVALINK_ESPNOW

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
        case chip::DeviceLayer::DeviceEventType::kWiFiConnectivityChange:
            // Log uptime at Wi-Fi (re)connect so you can confirm the built-in
            // NVS fast-connect is working — a targeted last-channel reconnect is
            // much quicker than a cold full-channel scan.
            ESP_LOGI(TAG, "📶 Wi-Fi %s (uptime %lld ms)",
                     event->WiFiConnectivityChange.Result ==
                         chip::DeviceLayer::kConnectivity_Established
                             ? "connected"
                             : "lost",
                     esp_timer_get_time() / 1000);
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

#endif  // !CONFIG_AKVALINK_BLE_ONLY

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

    // --- Variant guard: auto-erase NVS on cross-variant OTA ----------------
    // If a different variant's app was flashed via OTA (e.g. BLE → Thread),
    // the new firmware would find stale NVS from the old variant, causing
    // Matter commissioning, BLE pairing, or Wi-Fi provisioning to fail.
    // Store a short variant ID; if it doesn't match what's compiled in, wipe
    // NVS before any subsystem touches it, then record the new ID.
    {
        static const char *VARIANT_ID =
#if   CONFIG_AKVALINK_BLE_ONLY  
            "ble"
#elif CONFIG_AKVALINK_STATION
            "station"
#elif CONFIG_AKVALINK_AP
            "ap"
#elif CONFIG_AKVALINK_ESPNOW
            "espnow"
#else
            "matter"   // both thread and wifi use Matter/chip NVS namespaces
#endif
            ;
        nvs_handle_t h;
        char stored[12] = {};
        size_t len = sizeof(stored);
        bool mismatch = true;
        if (nvs_open("akvalink_sys", NVS_READONLY, &h) == ESP_OK) {
            mismatch = (nvs_get_str(h, "variant", stored, &len) != ESP_OK ||
                        strcmp(stored, VARIANT_ID) != 0);
            nvs_close(h);
        }
        if (mismatch) {
            ESP_LOGW(TAG, "Variant mismatch (stored='%s' vs compiled='%s') — "
                     "erasing NVS for clean cross-variant boot", stored, VARIANT_ID);
            ESP_ERROR_CHECK(nvs_flash_erase());
            ESP_ERROR_CHECK(nvs_flash_init());
            if (nvs_open("akvalink_sys", NVS_READWRITE, &h) == ESP_OK) {
                nvs_set_str(h, "variant", VARIANT_ID);
                nvs_commit(h);
                nvs_close(h);
            }
        }
    }

#if CONFIG_AKVALINK_SENSOR_TEST
    // --- DS18B20 test variant: read the 1-Wire sensor and log it. No Matter,
    // no BLE, no networking — for verifying probe wiring / the sensor.
    ESP_LOGI(TAG, "🌡 DS18B20 test — reading sensor only (no Matter/BLE)");
    ds18b20_task_start();
    ESP_LOGI(TAG, "✨ Sensor test up — watch the log for temperature");
#elif CONFIG_AKVALINK_BLE_ONLY
    // --- BLE-only variant: no Matter, no Thread, no Wi-Fi. Just a standalone
    // NimBLE GATT server + the sensor task feeding it. For homes with no hub.
    ESP_LOGI(TAG, "\xF0\x9F\x94\xB5 BLE-only variant — standalone GATT server (no Matter)");
#if CONFIG_AKVALINK_BLE_PM
    configure_light_sleep();   // CPU/peripheral light sleep between BLE events
#else
    ESP_LOGI(TAG, "PM: light sleep disabled (set CONFIG_AKVALINK_BLE_PM=y to enable)");
#endif
    ESP_ERROR_CHECK(akvalink_ble_gatt_start());
    ds18b20_task_start();
    ESP_LOGI(TAG, "✨ AkvaLink BLE-only up — connect to \"AkvaLink\" over BLE");
#elif CONFIG_AKVALINK_AP
    // --- Wi-Fi AP variant: open SoftAP "AkvaLink" + a captive web page showing
    // the live temperature. No Matter, no BLE. NEEDS EXTERNAL POWER (the Wi-Fi
    // radio stays awake for the AP — not battery friendly).
    ESP_LOGI(TAG, "\xF0\x9F\x93\xB6 Wi-Fi AP variant — SoftAP \"AkvaLink\" + web page (needs external power)");#if CONFIG_AKVALINK_BLE_ESCAPE_HATCH
    // GPIO9 escape hatch: hold BOOT button at power-on to skip SoftAP and
    // boot into standalone BLE GATT mode (Option C, CONNECTIVITY.md).
    {
        gpio_config_t io_cfg = {};
        io_cfg.pin_bit_mask = 1ULL << 9;
        io_cfg.mode         = GPIO_MODE_INPUT;
        io_cfg.pull_up_en   = GPIO_PULLUP_ENABLE;
        gpio_config(&io_cfg);
        vTaskDelay(pdMS_TO_TICKS(50));   // let pin settle
        if (gpio_get_level(GPIO_NUM_9) == 0) {
            ESP_LOGW(TAG, "\xF0\x9F\x94\xB5 GPIO9 held at boot \xe2\x80\x94 BLE escape hatch (skipping SoftAP)");
            g_ble_escape_active = true;
            ESP_ERROR_CHECK(akvalink_ble_escape_start());
            ds18b20_task_start();
            ESP_LOGI(TAG, "\xe2\x9c\xa8 AkvaLink BLE escape hatch up \xe2\x80\x94 connect to \"AkvaLink\" over BLE");
            return;
        }
    }
#endif    ESP_ERROR_CHECK(akvalink_ap_start());
    ds18b20_task_start();
    ESP_LOGI(TAG, "✨ AkvaLink AP up — join open Wi-Fi \"AkvaLink\", the page opens (or http://192.168.4.1)");

#elif CONFIG_AKVALINK_STATION
    // --- Wi-Fi station variant
    // GPIO9 escape hatch: hold the BOOT button at power-on to skip Wi-Fi and
    // boot into standalone BLE GATT mode instead (Option C, CONNECTIVITY.md).
    // Useful for recovery, demo without Wi-Fi, or when provisioning is broken.
    {
        gpio_config_t io_cfg = {};
        io_cfg.pin_bit_mask = 1ULL << 9;
        io_cfg.mode         = GPIO_MODE_INPUT;
        io_cfg.pull_up_en   = GPIO_PULLUP_ENABLE;
        gpio_config(&io_cfg);
        vTaskDelay(pdMS_TO_TICKS(50));   // let pin settle
        if (gpio_get_level(GPIO_NUM_9) == 0) {
            ESP_LOGW(TAG, "\xF0\x9F\x94\xB5 GPIO9 held at boot \xe2\x80\x94 BLE escape hatch (skipping Wi-Fi station)");
            ESP_ERROR_CHECK(akvalink_ble_gatt_start());
            ds18b20_task_start();
            ESP_LOGI(TAG, "\xe2\x9c\xa8 AkvaLink BLE GATT up (escape hatch) \xe2\x80\x94 connect to \"AkvaLink\" over BLE");
            return;
        }
    }
    ESP_LOGI(TAG, "\xF0\x9F\x93\xB6 Wi-Fi station variant — BLE-provisioned client + akvalink.local");
    ESP_ERROR_CHECK(akvalink_station_start());
    ds18b20_task_start();
    ESP_LOGI(TAG, "\u2728 AkvaLink station up — provision over BLE, then open http://akvalink-<last4mac>.local");
#elif CONFIG_AKVALINK_ESPNOW
    // --- ESP-NOW variant: deep-sleep broadcast, no hub, no provisioning.
    // Never returns — goes to deep sleep after sending one packet.
    ESP_LOGI(TAG, "\xF0\x9F\x93\xA1 ESP-NOW variant — broadcasting to channel %d (deep sleep %d s)",
             CONFIG_AKVALINK_ESPNOW_CHANNEL, CONFIG_AKVALINK_ESPNOW_SLEEP_S);
    akvalink_espnow_start();  // never returns
#else

    // --- Matter node + Temperature Sensor endpoint --------------------------
#if CONFIG_AKVALINK_BLE_ESCAPE_HATCH
    // GPIO9 escape hatch: hold BOOT button at power-on to skip Matter/Thread
    // and boot into minimal BLE GATT mode instead (Option C, CONNECTIVITY.md).
    // BLE stack is already compiled in for CHIPoBLE commissioning — incremental
    // cost is only the ble_escape.cpp GATT server (~15 KB).
    {
        gpio_config_t io_cfg = {};
        io_cfg.pin_bit_mask = 1ULL << 9;
        io_cfg.mode         = GPIO_MODE_INPUT;
        io_cfg.pull_up_en   = GPIO_PULLUP_ENABLE;
        gpio_config(&io_cfg);
        vTaskDelay(pdMS_TO_TICKS(50));   // let pin settle
        if (gpio_get_level(GPIO_NUM_9) == 0) {
            ESP_LOGW(TAG, "\xF0\x9F\x94\xB5 GPIO9 held at boot \xe2\x80\x94 BLE escape hatch (skipping Matter)");
            g_ble_escape_active = true;
            ESP_ERROR_CHECK(akvalink_ble_escape_start());
            ds18b20_task_start();
            ESP_LOGI(TAG, "\xe2\x9c\xa8 AkvaLink BLE escape hatch up \xe2\x80\x94 connect to \"AkvaLink\" over BLE");
            return;
        }
    }
#endif

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
    configure_light_sleep();
#endif

    // --- Start Matter (BLE commissioning + Thread join) ---------------------
    err = esp_matter::start(on_matter_event);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_matter::start failed: %d", err);
        return;
    }

    // Quiet OpenThread's per-packet mesh logging (keeps our own INFO logs).
    // Raise to ESP_LOG_INFO when debugging Thread routing.
    esp_log_level_set("OPENTHREAD", ESP_LOG_WARN);

    // --- Scannable QR straight into the log (no "open this URL" round-trip) --
    // esp-matter only logs the MT: payload + a link to the online QR viewer;
    // render the real thing so you can scan it from the serial monitor.
    {
        char qr_buf[128];
        chip::MutableCharSpan qr(qr_buf);
        if (GetQRCode(qr, chip::RendezvousInformationFlags(chip::RendezvousInformationFlag::kBLE)) == CHIP_NO_ERROR
            && qr.size() < sizeof(qr_buf)) {
            qr_buf[qr.size()] = '\0';   // MutableCharSpan isn't NUL-terminated
            akvalink_qr_print(qr_buf);
        } else {
            ESP_LOGW(TAG, "Could not build Matter QR payload");
        }
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
#endif  // !CONFIG_AKVALINK_BLE_ONLY
}
