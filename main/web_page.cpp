// SPDX-License-Identifier: Apache-2.0
//
// Shared HTTP temperature page for the Wi-Fi variants (--ap SoftAP and
// --station Wi-Fi client). Serves a self-contained page at "/" that polls
// "/temp" (JSON) and shows the live DS18B20 temperature. No external assets.
//
// The AP variant adds a captive-portal DNS hijack on top of this (see
// ap_web.cpp); the station variant reaches the same page via mDNS + DHCP IP.

#include "web_page.h"

#include <math.h>
#include <stdlib.h>
#include <stdio.h>

#include "esp_http_server.h"
#include "esp_log.h"

static const char *TAG = "web";

// Latest temperature (°C). volatile: written by the sensor task, read by the
// HTTP handler on another task. A single 32-bit float store/load is atomic on
// the C6, so no lock is needed for a display value.
static volatile float s_temp_c = NAN;
static httpd_handle_t s_httpd = NULL;

void akvalink_web_set_temperature(float celsius)
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
  .m{opacity:.45;margin-top:6px;font-size:.75rem}
</style></head>
<body><div class="c">
  <h1>AkvaLink &#127754;</h1>
  <div><span class="t" id="t">&ndash;</span><span class="u">&nbsp;&deg;C</span></div>
  <div class="s" id="s">reading&hellip;</div>
  <div class="m" id="m"></div>
</div>
<script>
function u(){fetch('/temp',{cache:'no-store'}).then(r=>r.json()).then(d=>{
  var t=document.getElementById('t'),s=document.getElementById('s');
  if(d.celsius==null){t.textContent='\u2013';s.textContent='no reading yet';}
  else{t.textContent=Number(d.celsius).toFixed(1);s.textContent='live \u00b7 updates every 2s';}
}).catch(function(){document.getElementById('s').textContent='disconnected';});}
function mq(){fetch('/mqtt-status',{cache:'no-store'}).then(function(r){return r.ok?r.json():null;}).then(function(d){
  if(!d)return;
  var m=document.getElementById('m');
  m.textContent=d.connected?'MQTT \u2713 Home Assistant':'MQTT \u2013 no broker';
}).catch(function(){});}
u();setInterval(u,2000);
mq();setInterval(mq,10000);
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
// redirect) is what reliably pops the OS captive-portal sheet on the AP variant,
// and is harmless on station (unknown paths just show the page).
static esp_err_t any_get(httpd_req_t *req)
{
    httpd_resp_set_type(req, "text/html");
    return httpd_resp_send(req, PAGE_HTML, HTTPD_RESP_USE_STRLEN);
}

esp_err_t akvalink_web_start_server(void)
{
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.uri_match_fn = httpd_uri_match_wildcard;   // enables the "/*" catch-all
    config.lru_purge_enable = true;
    config.max_open_sockets = 4;                      // a few phones at once is plenty

    if (httpd_start(&s_httpd, &config) != ESP_OK) {
        ESP_LOGE(TAG, "httpd_start failed");
        return ESP_FAIL;
    }
    httpd_uri_t root = {};
    root.uri = "/"; root.method = HTTP_GET; root.handler = root_get;
    httpd_register_uri_handler(s_httpd, &root);

    httpd_uri_t temp = {};
    temp.uri = "/temp"; temp.method = HTTP_GET; temp.handler = temp_get;
    httpd_register_uri_handler(s_httpd, &temp);

    httpd_uri_t any = {};
    any.uri = "/*"; any.method = HTTP_GET; any.handler = any_get;
    httpd_register_uri_handler(s_httpd, &any);

    return ESP_OK;
}

httpd_handle_t akvalink_web_get_server(void)
{
    return s_httpd;
}
