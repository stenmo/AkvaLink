// SPDX-License-Identifier: Apache-2.0
//
// Standalone Wi-Fi station variant (--station): join the home Wi-Fi as a
// client, provisioned over BLE with Espressif Unified Provisioning (the free
// "ESP BLE Provisioning" app). Once online it advertises mDNS "akvalink.local"
// and serves the shared temperature page (web_page.cpp). No Matter, no hub.
//
// POWER: staying associated to an AP keeps the Wi-Fi radio reachable — lighter
// than SoftAP but still not multi-year on a coin cell. For mains/USB or a
// generous battery; Wi-Fi 6 TWT tuning is a future power task (see TODO.md).

#include "station_web.h"
#include "web_page.h"

#include <string.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "mdns.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"

#include "wifi_provisioning/manager.h"
#include "wifi_provisioning/scheme_ble.h"

static const char *TAG = "station";

#define PROV_SERVICE_NAME "AkvaLink"   // BLE name shown in the provisioning app
#define PROV_POP          "akvalink"   // proof-of-possession the app must enter
#define MDNS_HOSTNAME     "akvalink"   // → http://akvalink.local

#define WIFI_CONNECTED_BIT BIT0
static EventGroupHandle_t s_events;
static bool s_web_up = false;

static void start_mdns_and_web(void)
{
    if (s_web_up) {
        return;                                 // reconnect — already serving
    }
    if (mdns_init() == ESP_OK) {
        mdns_hostname_set(MDNS_HOSTNAME);
        mdns_instance_name_set("AkvaLink temperature");
        mdns_service_add(NULL, "_http", "_tcp", 80, NULL, 0);
        ESP_LOGI(TAG, "mDNS up — page at http://%s.local", MDNS_HOSTNAME);
    } else {
        ESP_LOGW(TAG, "mDNS init failed — reach the page by IP instead");
    }
    akvalink_web_start_server();
    s_web_up = true;
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

esp_err_t akvalink_station_start(void)
{
    s_events = xEventGroupCreate();

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
