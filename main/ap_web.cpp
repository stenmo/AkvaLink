// SPDX-License-Identifier: Apache-2.0
//
// Standalone Wi-Fi AP variant (--ap): open SoftAP "AkvaLink" + captive-portal
// DNS so any phone/laptop that joins is pushed straight to the temperature
// page (served by the shared web server in web_page.cpp). No Matter, no BLE,
// no home network.
//
// POWER: an always-on SoftAP keeps the Wi-Fi radio awake — NOT battery
// friendly (days, not years). This variant is for mains/USB-powered use.

#include "ap_web.h"
#include "web_page.h"

#include <string.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/sockets.h"

static const char *TAG = "ap";

#define AP_SSID        "AkvaLink"
#define AP_IP_STR      "192.168.4.1"   // ESP-IDF default SoftAP gateway IP

// --- Captive-portal DNS hijack ---------------------------------------------
// Answer EVERY A query with the SoftAP IP so the OS captive-portal check fails
// its "reach the internet" probe and pops the sign-in page (our web page).
static void dns_hijack_task(void *arg)
{
    (void)arg;
    uint8_t buf[512];
    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock < 0) { ESP_LOGE(TAG, "dns socket"); vTaskDelete(NULL); return; }

    struct sockaddr_in sa = {};
    sa.sin_family = AF_INET;
    sa.sin_port = htons(53);
    sa.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(sock, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        ESP_LOGE(TAG, "dns bind");
        close(sock);
        vTaskDelete(NULL);
        return;
    }

    while (true) {
        struct sockaddr_in src;
        socklen_t sl = sizeof(src);
        int n = recvfrom(sock, buf, sizeof(buf), 0, (struct sockaddr *)&src, &sl);
        if (n < 12) continue;

        // Walk past the question: header (12) + QNAME labels (until 0) + qtype/qclass (4).
        int p = 12;
        while (p < n && buf[p] != 0) { p += buf[p] + 1; }
        p += 1 + 4;
        if (p > (int)sizeof(buf) - 16) continue;   // no room for the answer

        buf[2] |= 0x84;   // QR=1, AA=1 (keep opcode + RD)
        buf[3] = 0x80;    // RA=1, RCODE=0
        buf[6] = 0x00; buf[7] = 0x01;   // ANCOUNT = 1
        buf[8] = buf[9] = buf[10] = buf[11] = 0x00;   // NSCOUNT = ARCOUNT = 0

        static const uint8_t answer[] = {
            0xC0, 0x0C,             // name: pointer to the question
            0x00, 0x01,             // type A
            0x00, 0x01,             // class IN
            0x00, 0x00, 0x00, 0x3C, // TTL 60 s
            0x00, 0x04,             // RDLENGTH 4
            192, 168, 4, 1,         // RDATA = 192.168.4.1
        };
        memcpy(buf + p, answer, sizeof(answer));
        sendto(sock, buf, p + sizeof(answer), 0, (struct sockaddr *)&src, sl);
    }
}

esp_err_t akvalink_ap_start(void)
{
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_ap();

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    wifi_config_t wc = {};
    strncpy((char *)wc.ap.ssid, AP_SSID, sizeof(wc.ap.ssid));
    wc.ap.ssid_len       = strlen(AP_SSID);
    wc.ap.channel        = 1;
    wc.ap.max_connection = 4;
    wc.ap.authmode       = WIFI_AUTH_OPEN;   // open network, no password
    wc.ap.beacon_interval = 200;             // ms — a touch slower than the 100 ms default

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_AP));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &wc));
    ESP_ERROR_CHECK(esp_wifi_start());

    akvalink_web_start_server();
    xTaskCreate(dns_hijack_task, "dns_hijack", 3072, NULL, 5, NULL);

    ESP_LOGI(TAG, "SoftAP \"%s\" (open) up — page at http://%s", AP_SSID, AP_IP_STR);
    return ESP_OK;
}
