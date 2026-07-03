// SPDX-License-Identifier: Apache-2.0
//
// Standalone Wi-Fi AP variant (--ap): open SoftAP "AkvaLink" + captive-portal
// DNS + an HTTP server serving a self-contained page that shows the live
// DS18B20 temperature. No Matter, no BLE, no home network.
//
// The HTTP page + /temp JSON handler are written to be reused by the planned
// --station variant (same page, Wi-Fi client + mDNS instead of SoftAP).
//
// POWER: an always-on SoftAP keeps the Wi-Fi radio awake — NOT battery
// friendly (days, not years). This variant is for mains/USB-powered use.

#include "ap_web.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "esp_event.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/sockets.h"

static const char *TAG = "ap";

#define AP_SSID        "AkvaLink"
#define AP_IP_STR      "192.168.4.1"   // ESP-IDF default SoftAP gateway IP

// Latest temperature (°C). volatile: written by the sensor task, read by the
// HTTP handler on another task. A single 32-bit float store/load is atomic on
// the C6, so no lock is needed for a display value.
static volatile float s_temp_c = NAN;
static httpd_handle_t s_httpd = NULL;

void akvalink_ap_set_temperature(float celsius)
{
    s_temp_c = celsius;
}

// --- Web page (self-contained, no external assets) --------------------------
static const char PAGE_HTML[] = R"HTML(<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AkvaLink</title>
<style>
  :root{color-scheme:dark}
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
       font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;text-align:center;
       background:linear-gradient(160deg,#033f63,#0a4a5a);color:#eaf7fb}
  .c{padding:24px}
  h1{font-weight:800;margin:0 0 18px;font-size:1.6rem}
  .t{font-size:4.5rem;font-weight:800;color:#28c2d6;line-height:1}
  .u{font-size:1.6rem;color:#28c2d6}
  .s{opacity:.7;margin-top:10px;font-size:.95rem}
</style></head>
<body><div class="c">
  <h1>AkvaLink &#127754;</h1>
  <div><span class="t" id="t">&ndash;</span><span class="u">&nbsp;&deg;C</span></div>
  <div class="s" id="s">reading&hellip;</div>
</div>
<script>
function u(){fetch('/temp',{cache:'no-store'}).then(r=>r.json()).then(d=>{
  var t=document.getElementById('t'),s=document.getElementById('s');
  if(d.celsius==null){t.textContent='\u2013';s.textContent='no reading yet';}
  else{t.textContent=Number(d.celsius).toFixed(1);s.textContent='live \u00b7 updates every 2s';}
}).catch(function(){document.getElementById('s').textContent='disconnected';});}
u();setInterval(u,2000);
</script></body></html>)HTML";

static esp_err_t root_get(httpd_req_t *req)
{
    httpd_resp_set_type(req, "text/html");
    return httpd_resp_send(req, PAGE_HTML, HTTPD_RESP_USE_STRLEN);
}

static esp_err_t temp_get(httpd_req_t *req)
{
    char buf[48];
    float t = s_temp_c;
    int n;
    if (isnan(t)) {
        n = snprintf(buf, sizeof(buf), "{\"celsius\":null}");
    } else {
        // Integer formatting only — CONFIG_NEWLIB_NANO_FORMAT drops %f.
        int centi = (int)lroundf(t * 100.0f);
        const char *sign = centi < 0 ? "-" : "";
        int a = abs(centi);
        n = snprintf(buf, sizeof(buf), "{\"celsius\":%s%d.%02d}", sign, a / 100, a % 100);
    }
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    return httpd_resp_send(req, buf, n);
}

// Catch-all: serve the page for every path. A 200 with HTML (rather than a 302
// redirect) is what reliably pops the OS captive-portal sheet on join.
static esp_err_t captive_get(httpd_req_t *req)
{
    httpd_resp_set_type(req, "text/html");
    return httpd_resp_send(req, PAGE_HTML, HTTPD_RESP_USE_STRLEN);
}

static void start_http(void)
{
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.uri_match_fn = httpd_uri_match_wildcard;   // enables the "/*" catch-all
    config.lru_purge_enable = true;
    config.max_open_sockets = 4;                      // a few phones at once is plenty

    if (httpd_start(&s_httpd, &config) != ESP_OK) {
        ESP_LOGE(TAG, "httpd_start failed");
        return;
    }
    httpd_uri_t root = {};
    root.uri = "/"; root.method = HTTP_GET; root.handler = root_get;
    httpd_register_uri_handler(s_httpd, &root);

    httpd_uri_t temp = {};
    temp.uri = "/temp"; temp.method = HTTP_GET; temp.handler = temp_get;
    httpd_register_uri_handler(s_httpd, &temp);

    httpd_uri_t any = {};
    any.uri = "/*"; any.method = HTTP_GET; any.handler = captive_get;
    httpd_register_uri_handler(s_httpd, &any);
}

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

    start_http();
    xTaskCreate(dns_hijack_task, "dns_hijack", 3072, NULL, 5, NULL);

    ESP_LOGI(TAG, "SoftAP \"%s\" (open) up — page at http://%s", AP_SSID, AP_IP_STR);
    return ESP_OK;
}
