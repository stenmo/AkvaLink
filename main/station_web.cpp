// SPDX-License-Identifier: Apache-2.0
//
// Standalone Wi-Fi station variant (--station): join the home Wi-Fi as a
// client, provisioned over BLE with Espressif Unified Provisioning (the free
// "ESP BLE Provisioning" app). Once online it:
//   - advertises mDNS "akvalink-<last4mac>.local" and serves the shared page
//   - connects to the configured MQTT broker and publishes HA autodiscovery
// Long-press GPIO9 (EVK BOOT button) 5 s → erases Wi-Fi creds + re-provisions.

#include "station_web.h"
#include "web_page.h"

#include <inttypes.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "driver/gpio.h"
#include "esp_event.h"
#include "esp_http_server.h"   // for httpd_handle_t + httpd_register_uri_handler
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "mdns.h"
#include "mqtt_client.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/task.h"

// Defined in web_page.cpp; declared here rather than in web_page.h to avoid
// pulling esp_http_server.h into non-web (thread/wifi/ble) variants.
httpd_handle_t akvalink_web_get_server(void);

#include "wifi_provisioning/manager.h"
#include "wifi_provisioning/scheme_ble.h"

static const char *TAG = "station";

#define PROV_SERVICE_NAME "AkvaLink"   // BLE name shown in the provisioning app
#define PROV_POP          "akvalink"   // proof-of-possession the app must enter

// mDNS hostname is akvalink-<last4ofmac>.local so multiple devices on the
// same LAN get unique names without any configuration.
// Set in start_mqtt() once the MAC is known; used in start_mdns_and_web().
static char s_mdns_hostname[24] = "akvalink";  // e.g. "akvalink-5f884c"

// MQTT broker URL from Kconfig (default: Mosquitto add-on on Home Assistant).
#define MQTT_BROKER_URL   CONFIG_AKVALINK_MQTT_BROKER_URL

#define WIFI_CONNECTED_BIT BIT0
static EventGroupHandle_t s_events;
static bool s_web_up = false;

// --- MQTT state -------------------------------------------------------------
static esp_mqtt_client_handle_t s_mqtt = NULL;
static bool s_mqtt_connected = false;

// Per-device topics built from the STA MAC (set once on first IP event).
static char s_mac[13];          // "aabbccddeeff"
static char s_state_topic[48];  // "akvalink/<mac>/temperature"
static char s_avail_topic[44];  // "akvalink/<mac>/status"

// Publish the HA MQTT discovery config (retain=1) and an "online" availability
// message. Called once when the MQTT connection is established.
static void mqtt_publish_discovery(void)
{
    char disc_topic[80];
    snprintf(disc_topic, sizeof(disc_topic),
             "homeassistant/sensor/akvalink_%s/temperature/config", s_mac);

    // Discovery payload: one retained JSON message tells HA everything it needs
    // to create a temperature entity with availability tracking.
    char payload[768];
    snprintf(payload, sizeof(payload),
        "{\"name\":\"AkvaLink temperature\","
        "\"unique_id\":\"akvalink_%s_temp\","
        "\"device\":{"
            "\"identifiers\":[\"akvalink_%s\"],"
            "\"name\":\"AkvaLink\","
            "\"model\":\"Wi-Fi station\","
            "\"manufacturer\":\"u-blox NORA-W40\""
        "},"
        "\"state_topic\":\"%s\","
        "\"availability_topic\":\"%s\","
        "\"payload_available\":\"online\","
        "\"payload_not_available\":\"offline\","
        "\"unit_of_measurement\":\"\\u00b0C\","
        "\"device_class\":\"temperature\","
        "\"state_class\":\"measurement\","
        "\"value_template\":\"{{ value_json.celsius }}\"}",
        s_mac, s_mac, s_state_topic, s_avail_topic);

    // qos=1 + retain=1: HA picks up the entity even if it restarted while the
    // device was already online.
    esp_mqtt_client_publish(s_mqtt, disc_topic, payload, 0, 1, 1);
    esp_mqtt_client_publish(s_mqtt, s_avail_topic, "online", 0, 1, 1);
    ESP_LOGI(TAG, "MQTT HA discovery published — entity: akvalink_%s_temp", s_mac);
}

static void mqtt_event_handler(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg; (void)base; (void)data;
    switch ((esp_mqtt_event_id_t)id) {
    case MQTT_EVENT_CONNECTED:
        s_mqtt_connected = true;
        mqtt_publish_discovery();
        break;
    case MQTT_EVENT_DISCONNECTED:
        s_mqtt_connected = false;
        ESP_LOGW(TAG, "MQTT disconnected — will retry");
        break;
    case MQTT_EVENT_ERROR:
        ESP_LOGW(TAG, "MQTT error — check broker URL: %s", MQTT_BROKER_URL);
        break;
    default:
        break;
    }
}

static void start_mqtt(void)
{
    // Build per-device topics from the STA MAC address so multiple AkvaLink
    // devices on the same network get distinct MQTT topics and HA entity IDs.
    uint8_t mac[6];
    esp_wifi_get_mac(WIFI_IF_STA, mac);
    snprintf(s_mac, sizeof(s_mac), "%02x%02x%02x%02x%02x%02x",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    // Unique hostname: akvalink-<last4ofmac>.local (avoids collisions on shared LANs).
    snprintf(s_mdns_hostname, sizeof(s_mdns_hostname), "akvalink-%02x%02x%02x",
             mac[3], mac[4], mac[5]);
    snprintf(s_state_topic, sizeof(s_state_topic), "akvalink/%s/temperature", s_mac);
    snprintf(s_avail_topic, sizeof(s_avail_topic), "akvalink/%s/status", s_mac);

    esp_mqtt_client_config_t cfg = {};
    cfg.broker.address.uri            = MQTT_BROKER_URL;
    // LWT: broker publishes "offline" on unclean disconnect — HA marks the
    // entity unavailable so dashboards don’t show a stale value.
    cfg.session.last_will.topic       = s_avail_topic;
    cfg.session.last_will.msg         = "offline";
    cfg.session.last_will.msg_len     = 7;
    cfg.session.last_will.qos         = 1;
    cfg.session.last_will.retain      = 1;

    s_mqtt = esp_mqtt_client_init(&cfg);
    esp_mqtt_client_register_event(s_mqtt, MQTT_EVENT_ANY, mqtt_event_handler, NULL);
    esp_mqtt_client_start(s_mqtt);
    ESP_LOGI(TAG, "MQTT client started — broker %s", MQTT_BROKER_URL);
}

// Push the latest temperature for the web page AND publish to MQTT.
// Called by the DS18B20 task on each sample.
void akvalink_station_set_temperature(float celsius)
{
    akvalink_web_set_temperature(celsius);          // update the /temp endpoint

    if (!s_mqtt_connected) {
        return;
    }
    char buf[32];
    int n;
    if (isnan(celsius)) {
        n = snprintf(buf, sizeof(buf), "{\"celsius\":null}");
    } else {
        // Integer-safe formatting — CONFIG_NEWLIB_NANO_FORMAT drops %f.
        int centi = (int)lroundf(celsius * 100.0f);
        const char *sign = centi < 0 ? "-" : "";
        int a = abs(centi);
        n = snprintf(buf, sizeof(buf), "{\"celsius\":%s%d.%02d}", sign, a / 100, a % 100);
    }
    // qos=0, no retain: state updates are frequent; HA only needs the latest.
    esp_mqtt_client_publish(s_mqtt, s_state_topic, buf, n, 0, 0);
}

static esp_err_t mqtt_status_get(httpd_req_t *req)
{
    char buf[32];
    int n = snprintf(buf, sizeof(buf), "{\"connected\":%s}",
                     s_mqtt_connected ? "true" : "false");
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    return httpd_resp_send(req, buf, n);
}

static void start_mdns_and_web(void)
{
    if (s_web_up) {
        return;                                 // reconnect — already serving
    }
    s_web_up = true;                            // set early — prevent double-init on rapid IP events
    if (mdns_init() == ESP_OK) {
        mdns_hostname_set(s_mdns_hostname);
        mdns_instance_name_set("AkvaLink temperature");
        mdns_service_add(NULL, "_http", "_tcp", 80, NULL, 0);
        ESP_LOGI(TAG, "mDNS up — page at http://%s.local", s_mdns_hostname);
    } else {
        ESP_LOGW(TAG, "mDNS init failed — reach the page by IP instead");
    }
    akvalink_web_start_server();

    // Register the /mqtt-status endpoint (station-only — the web page polls
    // this silently and shows MQTT connection state in the card).
    httpd_handle_t httpd = akvalink_web_get_server();
    if (httpd) {
        httpd_uri_t ms = {};
        ms.uri = "/mqtt-status"; ms.method = HTTP_GET; ms.handler = mqtt_status_get;
        httpd_register_uri_handler(httpd, &ms);
    }

    start_mqtt();
}

static void event_handler(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    if (base == WIFI_PROV_EVENT) {
        switch (id) {
        case WIFI_PROV_START:
            ESP_LOGI(TAG, "BLE provisioning started — open the ESP BLE "
                          "Provisioning app, pick \"%s\", POP \"%s\"",
                     PROV_SERVICE_NAME, PROV_POP);
            break;
        case WIFI_PROV_CRED_RECV: {
            wifi_sta_config_t *c = (wifi_sta_config_t *)data;
            ESP_LOGI(TAG, "Got Wi-Fi credentials — SSID \"%s\"", (const char *)c->ssid);
            break;
        }
        case WIFI_PROV_CRED_FAIL:
            ESP_LOGE(TAG, "Provisioning failed — wrong password or AP not found; retrying");
            break;
        case WIFI_PROV_CRED_SUCCESS:
            ESP_LOGI(TAG, "Provisioning succeeded");
            break;
        case WIFI_PROV_END:
            wifi_prov_mgr_deinit();             // release the provisioning manager
            break;
        default:
            break;
        }
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        ESP_LOGW(TAG, "Disconnected — reconnecting");
        esp_wifi_connect();
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *ev = (ip_event_got_ip_t *)data;
        ESP_LOGI(TAG, "Online — IP " IPSTR, IP2STR(&ev->ip_info.ip));
        start_mdns_and_web();
        xEventGroupSetBits(s_events, WIFI_CONNECTED_BIT);
    }
}

// --- Re-provisioning button (GPIO9 = EVK BOOT button) ----------------------
// Long-press 5 s → erase Wi-Fi NVS namespace + restart into BLE provisioning.
// Gives the user a hardware recovery path without needing a flash-erase.
#define REPROV_GPIO        GPIO_NUM_9
#define REPROV_HOLD_MS     5000   // 5 s continuous press

static void reprov_task(void *)
{
    gpio_config_t io = {};
    io.pin_bit_mask = (1ULL << REPROV_GPIO);
    io.mode         = GPIO_MODE_INPUT;
    io.pull_up_en   = GPIO_PULLUP_ENABLE;
    io.pull_down_en = GPIO_PULLDOWN_DISABLE;
    io.intr_type    = GPIO_INTR_DISABLE;
    gpio_config(&io);

    uint32_t held_ms = 0;
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(100));
        if (gpio_get_level(REPROV_GPIO) == 0) {  // button pressed (active-low)
            held_ms += 100;
            if (held_ms >= REPROV_HOLD_MS) {
                ESP_LOGW(TAG, "\xe2\x9a\x99 BOOT held %" PRIu32 " ms \xe2\x80\x94 erasing Wi-Fi creds, restarting BLE provisioning", held_ms);
                wifi_prov_mgr_reset_provisioning();   // clears the wifi_prov NVS namespace
                esp_restart();
            }
        } else {
            held_ms = 0;
        }
    }
}

esp_err_t akvalink_station_start(void)
{
    s_events = xEventGroupCreate();

    // Start the re-provisioning monitor early — before Wi-Fi init — so the
    // button works even if Wi-Fi connection hangs.
    xTaskCreate(reprov_task, "reprov", 2048, NULL, 3, NULL);

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_PROV_EVENT, ESP_EVENT_ANY_ID, event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, event_handler, NULL));

    wifi_prov_mgr_config_t prov_cfg = {};
    prov_cfg.scheme = wifi_prov_scheme_ble;
    prov_cfg.scheme_event_handler = WIFI_PROV_SCHEME_BLE_EVENT_HANDLER_FREE_BTDM;
    ESP_ERROR_CHECK(wifi_prov_mgr_init(prov_cfg));

    bool provisioned = false;
    ESP_ERROR_CHECK(wifi_prov_mgr_is_provisioned(&provisioned));

    if (!provisioned) {
        ESP_LOGI(TAG, "No Wi-Fi credentials stored — starting BLE provisioning");
        wifi_prov_security_t security = WIFI_PROV_SECURITY_1;
        ESP_ERROR_CHECK(wifi_prov_mgr_start_provisioning(
            security, PROV_POP, PROV_SERVICE_NAME, NULL));
    } else {
        ESP_LOGI(TAG, "Wi-Fi credentials found — connecting");
        wifi_prov_mgr_deinit();                 // not needed for a normal connect
        ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
        ESP_ERROR_CHECK(esp_wifi_start());
    }

    return ESP_OK;
}
