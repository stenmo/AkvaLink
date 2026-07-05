// SPDX-License-Identifier: Apache-2.0
//
// Shared HTTP temperature page for the Wi-Fi variants (--ap SoftAP and
// --station Wi-Fi client). Serves a self-contained page at "/" that polls
// "/temp" (JSON) and shows the live DS18B20 temperature. No external assets.
//
// History tracking (Option C):
//   /stats    — min/max since boot, reset via POST /history/reset
//   /trend    — direction (rising/stable/falling) from last 5 readings
//   /history  — 24h at 5-min intervals (288 entries) + 7d at 1-hr (168 entries)
//   POST /history/reset — clear all history + min/max

#include "web_page.h"

#include <inttypes.h>
#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_timer.h"

static const char *TAG = "web";

// --- Live value -------------------------------------------------------------
static volatile float   s_temp_c          = NAN;
static volatile uint8_t s_battery_percent = 255;  // 255 = unknown
static httpd_handle_t   s_httpd           = NULL;

// --- History ring buffers ---------------------------------------------------
// 24h at 5-min intervals (averaged within each window)
#define HIST_M_SIZE  288    // 24 h × 12 samples/h
// 7d at 1-hr intervals
#define HIST_H_SIZE  168    // 7 d × 24 h

static float s_hist_m[HIST_M_SIZE];
static float s_hist_h[HIST_H_SIZE];
static int   s_hist_m_head  = 0;   // next write position
static int   s_hist_m_count = 0;   // entries filled so far (0 → HIST_M_SIZE)
static int   s_hist_h_head  = 0;
static int   s_hist_h_count = 0;

// Running averages for each aggregation window
static float   s_agg_m_sum = 0;
static int     s_agg_m_n   = 0;
static int64_t s_agg_m_start_us = 0;   // start of current 5-min window

static float   s_agg_h_sum = 0;
static int     s_agg_h_n   = 0;
static int64_t s_agg_h_start_us = 0;   // start of current 1-hr window

// --- Min/max + trend -------------------------------------------------------
static float   s_min_c = NAN;
static float   s_max_c = NAN;
static int64_t s_stats_start_us = 0;   // when stats tracking started

// Trend: circular buffer of last 5 readings with timestamps
#define TREND_N 5
static float   s_trend_val[TREND_N];
static int64_t s_trend_ts_us[TREND_N];
static int     s_trend_head  = 0;
static int     s_trend_count = 0;

#define US_PER_MIN  INT64_C(60000000)
#define US_5MIN     (5 * US_PER_MIN)
#define US_PER_HOUR (60 * US_PER_MIN)

// Push a float value into a ring buffer.
static void ring_push(float *buf, int size, int *head, int *count, float val)
{
    buf[*head] = val;
    *head = (*head + 1) % size;
    if (*count < size) (*count)++;
}

// Helper: integer-safe temperature format ("26.50" or "null"). Returns length.
static int fmt_temp(char *out, int len, float t)
{
    if (isnan(t)) return snprintf(out, len, "null");
    int c = (int)lroundf(t * 100.0f);
    const char *s = c < 0 ? "-" : "";
    int a = abs(c);
    return snprintf(out, len, "%s%d.%02d", s, a / 100, a % 100);
}

// Called by the sensor task on every new reading.
void akvalink_web_set_temperature(float celsius)
{
    s_temp_c = celsius;
    if (isnan(celsius)) return;

    int64_t now = esp_timer_get_time();

    // -- min/max -------
    if (isnan(s_min_c) || celsius < s_min_c) s_min_c = celsius;
    if (isnan(s_max_c) || celsius > s_max_c) s_max_c = celsius;
    if (s_stats_start_us == 0) s_stats_start_us = now;

    // -- trend ring ----
    s_trend_val[s_trend_head]   = celsius;
    s_trend_ts_us[s_trend_head] = now;
    s_trend_head = (s_trend_head + 1) % TREND_N;
    if (s_trend_count < TREND_N) s_trend_count++;

    // -- 5-min window --
    if (s_agg_m_start_us == 0) s_agg_m_start_us = now;
    s_agg_m_sum += celsius; s_agg_m_n++;
    if (now - s_agg_m_start_us >= US_5MIN) {
        ring_push(s_hist_m, HIST_M_SIZE, &s_hist_m_head, &s_hist_m_count,
                  s_agg_m_sum / s_agg_m_n);
        s_agg_m_sum = 0; s_agg_m_n = 0; s_agg_m_start_us = now;
    }

    // -- 1-hr window ---
    if (s_agg_h_start_us == 0) s_agg_h_start_us = now;
    s_agg_h_sum += celsius; s_agg_h_n++;
    if (now - s_agg_h_start_us >= US_PER_HOUR) {
        ring_push(s_hist_h, HIST_H_SIZE, &s_hist_h_head, &s_hist_h_count,
                  s_agg_h_sum / s_agg_h_n);
        s_agg_h_sum = 0; s_agg_h_n = 0; s_agg_h_start_us = now;
    }
}

void akvalink_web_set_battery(uint8_t percent)
{
    s_battery_percent = (percent > 100) ? 100 : percent;
}

static void history_reset(void)
{
    s_hist_m_head  = s_hist_m_count  = 0;
    s_hist_h_head  = s_hist_h_count  = 0;
    s_agg_m_sum    = s_agg_h_sum     = 0;
    s_agg_m_n      = s_agg_h_n       = 0;
    s_agg_m_start_us = s_agg_h_start_us = 0;
    s_trend_head   = s_trend_count   = 0;
    s_min_c = s_max_c = NAN;
    s_stats_start_us = 0;
}


// --- Web page ---------------------------------------------------------------
static const char PAGE_HTML[] = R"HTML(<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AkvaLink</title>
<style>
  :root{color-scheme:dark}
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
       font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;text-align:center;
       background:linear-gradient(160deg,#033f63,#0a4a5a);color:#eaf7fb}
  .c{padding:20px;width:100%;max-width:420px}
  h1{font-weight:800;margin:0 0 14px;font-size:1.6rem}
  .row{display:flex;align-items:baseline;justify-content:center;gap:10px}
  .t{font-size:4.5rem;font-weight:800;color:#28c2d6;line-height:1}
  .u{font-size:1.6rem;color:#28c2d6}
  .arrow{font-size:2rem;line-height:1;transition:color .4s}
  .arrow.up{color:#ff7043}.arrow.dn{color:#64b5f6}.arrow.ok{color:#90a4ae}
  .s{opacity:.7;margin-top:8px;font-size:.95rem}
  .stats{opacity:.6;margin-top:6px;font-size:.8rem}
  .b{opacity:.5;margin-top:4px;font-size:.8rem}.b.low{color:#ff6b6b;opacity:.85}
  .m{opacity:.45;margin-top:4px;font-size:.75rem}
  .graph{margin-top:14px;background:rgba(0,0,0,.2);border-radius:10px;padding:8px 6px 4px}
  .tabs{display:flex;gap:6px;justify-content:center;margin-bottom:6px}
  .tab{font-size:.75rem;padding:2px 10px;border-radius:8px;border:1px solid rgba(255,255,255,.2);
       cursor:pointer;background:transparent;color:#eaf7fb;opacity:.6}
  .tab.on{background:rgba(40,194,214,.25);opacity:1;border-color:#28c2d6}
  .spark{width:100%;height:56px;display:block}
  .glabel{display:flex;justify-content:space-between;font-size:.7rem;opacity:.4;margin-top:2px}
  .clr{font-size:.7rem;opacity:.35;cursor:pointer;margin-top:6px;display:inline-block}
  .clr:hover{opacity:.7}
</style></head>
<body><div class="c">
  <h1>AkvaLink &#127754;</h1>
  <div class="row">
    <span class="t" id="t">&ndash;</span><span class="u">&deg;C</span>
    <span class="arrow ok" id="arr">&rarr;</span>
  </div>
  <div class="s" id="s">reading&hellip;</div>
  <div class="stats" id="st"></div>
  <div class="b" id="b"></div>
  <div class="m" id="m"></div>
  <div class="graph" id="graph" style="display:none">
    <div class="tabs">
      <button class="tab on" id="t24" onclick="showTab(0)">24 h</button>
      <button class="tab" id="t7d" onclick="showTab(1)">7 d</button>
    </div>
    <svg class="spark" id="sp" viewBox="0 0 300 56" preserveAspectRatio="none"></svg>
    <div class="glabel"><span id="glo"></span><span id="ghi"></span></div>
    <span class="clr" onclick="clearHist()">&#10006; clear history</span>
  </div>
  <div id="upd" style="margin-top:16px;padding-top:12px;border-top:1px solid rgba(255,255,255,.12)">
    <div style="font-size:.85rem;opacity:.55;margin-bottom:8px">Firmware update</div>
    <label style="padding:5px 12px;border-radius:8px;border:1px solid rgba(255,255,255,.22);cursor:pointer;font-size:.82rem">
      Choose .bin<input type="file" id="otf" accept=".bin" style="display:none" onchange="selF(this)"></label>
    <span id="ofn" style="font-size:.78rem;opacity:.4;margin-left:6px"></span>
    <div id="opr" style="height:5px;background:rgba(0,0,0,.25);border-radius:3px;margin:8px 0 4px;display:none">
      <div id="obr" style="height:100%;width:0;background:#28c2d6;border-radius:3px;transition:width .2s"></div></div>
    <div id="oms" style="font-size:.78rem;opacity:.6;margin-bottom:6px"></div>
    <button id="ofl" onclick="doOta()" style="padding:5px 14px;border-radius:8px;border:1px solid rgba(40,194,214,.5);background:rgba(40,194,214,.12);color:#28c2d6;cursor:pointer;font-size:.82rem">Flash</button>
  </div>
</div>
<script>
var histData={m:[],h:[]},tab=0;
function fmt(v){return v==null?'\u2013':Number(v).toFixed(1);}
function u(){fetch('/temp',{cache:'no-store'}).then(r=>r.json()).then(d=>{
  var t=document.getElementById('t'),s=document.getElementById('s');
  if(d.celsius==null){t.textContent='\u2013';s.textContent='no reading yet';}
  else{t.textContent=Number(d.celsius).toFixed(1);s.textContent='live \u00b7 updates every 2s';}
}).catch(function(){document.getElementById('s').textContent='disconnected';});}
function trend(){fetch('/trend',{cache:'no-store'}).then(function(r){return r.ok?r.json():null;}).then(function(d){
  if(!d)return;
  var a=document.getElementById('arr');
  if(d.direction==='rising'){a.textContent='\u2191';a.className='arrow up';}
  else if(d.direction==='falling'){a.textContent='\u2193';a.className='arrow dn';}
  else{a.textContent='\u2192';a.className='arrow ok';}
}).catch(function(){});}
function stats(){fetch('/stats',{cache:'no-store'}).then(function(r){return r.ok?r.json():null;}).then(function(d){
  if(!d)return;
  var s=document.getElementById('st');
  s.textContent='\u2193\u00a0'+fmt(d.min)+'\u00b0 \u00b7 \u2191\u00a0'+fmt(d.max)+'\u00b0';
}).catch(function(){});}
function bat(){fetch('/battery',{cache:'no-store'}).then(function(r){return r.ok?r.json():null;}).then(function(d){
  if(!d||d.percent===null)return;
  var el=document.getElementById('b'),p=d.percent;
  el.textContent=(p<=10?'\ud83e\udeb4':'\ud83d\udd0b')+' '+p+'%';
  el.className='b'+(p<=20?' low':'');
}).catch(function(){});}
function mq(){fetch('/mqtt-status',{cache:'no-store'}).then(function(r){return r.ok?r.json():null;}).then(function(d){
  if(!d)return;
  document.getElementById('m').textContent=d.connected?'MQTT \u2713 Home Assistant':'MQTT \u2013 no broker';
}).catch(function(){});}
function hist(){fetch('/history',{cache:'no-store'}).then(function(r){return r.ok?r.json():null;}).then(function(d){
  if(!d)return;
  histData=d;
  var arr=tab===0?d.minute:d.hourly;
  if(arr&&arr.length>1){document.getElementById('graph').style.display='';drawSpark(arr);}
}).catch(function(){});}
function showTab(n){
  tab=n;
  document.getElementById('t24').className='tab'+(n===0?' on':'');
  document.getElementById('t7d').className='tab'+(n===1?' on':'');
  var arr=n===0?histData.minute:histData.hourly;
  if(arr&&arr.length>1)drawSpark(arr);
}
function drawSpark(data){
  var sp=document.getElementById('sp');
  var lo=Math.min.apply(null,data),hi=Math.max.apply(null,data);
  var range=hi-lo||0.5,W=300,H=56,pad=4;
  var pts=data.map(function(v,i){
    return (i/(data.length-1)*(W-2*pad)+pad).toFixed(1)+','+(((1-(v-lo)/range)*(H-2*pad)+pad)).toFixed(1);
  }).join(' ');
  sp.innerHTML='<polyline points="'+pts+'" fill="none" stroke="#28c2d6" stroke-width="1.8" stroke-linejoin="round"/>';
  document.getElementById('glo').textContent=fmt(lo)+'\u00b0';
  document.getElementById('ghi').textContent=fmt(hi)+'\u00b0';
}
function clearHist(){fetch('/history/reset',{method:'POST'}).then(function(){
  histData={m:[],h:[]};
  document.getElementById('graph').style.display='none';
  document.getElementById('st').textContent='';
});}
u();trend();stats();bat();mq();hist();
setInterval(u,2000);setInterval(trend,10000);setInterval(stats,30000);
setInterval(bat,30000);setInterval(mq,10000);setInterval(hist,60000);
var _otaF=null;
function selF(i){_otaF=i.files[0];document.getElementById('ofn').textContent=_otaF?_otaF.name:'';}
function doOta(){
  if(!_otaF){document.getElementById('oms').textContent='Select a .bin file first';return;}
  var btn=document.getElementById('ofl'),pr=document.getElementById('opr'),br=document.getElementById('obr'),ms=document.getElementById('oms');
  btn.disabled=true;btn.textContent='Uploading\u2026';pr.style.display='';br.style.width='0';
  var xhr=new XMLHttpRequest();xhr.open('POST','/ota');
  xhr.setRequestHeader('Content-Type','application/octet-stream');xhr.timeout=120000;
  xhr.upload.onprogress=function(e){if(e.lengthComputable){br.style.width=(e.loaded/e.total*100)+'%';ms.textContent='Uploading '+Math.round(e.loaded/e.total*100)+'%\u2026';}};
  xhr.onload=function(){var r=null;try{r=JSON.parse(xhr.responseText);}catch(e){}
    if(r&&r.ok){br.style.width='100%';ms.textContent='Done \u2014 rebooting\u2026';}
    else{ms.textContent='Failed: '+(r&&r.error||'unknown');}
    btn.textContent='Flash';btn.disabled=false;};
  xhr.onerror=function(){ms.textContent='Upload error';btn.textContent='Flash';btn.disabled=false;};
  _otaF.arrayBuffer().then(function(ab){xhr.send(ab);});
}
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
        int c = (int)lroundf(t * 100.0f);
        const char *s = c < 0 ? "-" : "";
        int a = abs(c);
        n = snprintf(buf, sizeof(buf), "{\"celsius\":%s%d.%02d}", s, a / 100, a % 100);
    }
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    return httpd_resp_send(req, buf, n);
}

static esp_err_t battery_get(httpd_req_t *req)
{
    char buf[32];
    uint8_t pct = s_battery_percent;
    int n = (pct == 255) ? snprintf(buf, sizeof(buf), "{\"percent\":null}")
                         : snprintf(buf, sizeof(buf), "{\"percent\":%u}", (unsigned)pct);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    return httpd_resp_send(req, buf, n);
}

static esp_err_t trend_get(httpd_req_t *req)
{
    char buf[64];
    const char *dir = "stable";
    float delta = 0;
    if (s_trend_count >= 2) {
        // Oldest entry in the ring.
        int oldest = (s_trend_head - s_trend_count + TREND_N) % TREND_N;
        int newest = (s_trend_head - 1 + TREND_N) % TREND_N;
        float dv = s_trend_val[newest] - s_trend_val[oldest];
        int64_t dt_us = s_trend_ts_us[newest] - s_trend_ts_us[oldest];
        if (dt_us > 0) {
            delta = dv / (dt_us / (float)US_PER_MIN);  // °C per minute
            if (delta >  0.05f) dir = "rising";
            if (delta < -0.05f) dir = "falling";
        }
    }
    int dc = (int)lroundf(delta * 100.0f);
    const char *sg = dc < 0 ? "-" : "";
    int da = abs(dc);
    int n = snprintf(buf, sizeof(buf),
        "{\"direction\":\"%s\",\"delta_c_per_min\":%s%d.%02d}",
        dir, sg, da / 100, da % 100);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    return httpd_resp_send(req, buf, n);
}

static esp_err_t stats_get(httpd_req_t *req)
{
    char buf[96], min_s[16], max_s[16];
    fmt_temp(min_s, sizeof(min_s), s_min_c);
    fmt_temp(max_s, sizeof(max_s), s_max_c);
    int64_t since_s = s_stats_start_us ? (esp_timer_get_time() - s_stats_start_us) / 1000000 : 0;
    int n = snprintf(buf, sizeof(buf),
        "{\"min\":%s,\"max\":%s,\"since_s\":%" PRId64 "}",
        min_s, max_s, since_s);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    return httpd_resp_send(req, buf, n);
}

// Stream the history arrays as chunked JSON (avoids a large heap allocation).
static esp_err_t history_get(httpd_req_t *req)
{
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_send_chunk(req, "{\"minute\":[", -1);
    int oldest = (s_hist_m_head - s_hist_m_count + HIST_M_SIZE) % HIST_M_SIZE;
    for (int i = 0; i < s_hist_m_count; i++) {
        char tmp[16];
        int n = fmt_temp(tmp, sizeof(tmp), s_hist_m[(oldest + i) % HIST_M_SIZE]);
        if (i) httpd_resp_send_chunk(req, ",", 1);
        httpd_resp_send_chunk(req, tmp, n);
    }
    httpd_resp_send_chunk(req, "],\"hourly\":[", -1);
    oldest = (s_hist_h_head - s_hist_h_count + HIST_H_SIZE) % HIST_H_SIZE;
    for (int i = 0; i < s_hist_h_count; i++) {
        char tmp[16];
        int n = fmt_temp(tmp, sizeof(tmp), s_hist_h[(oldest + i) % HIST_H_SIZE]);
        if (i) httpd_resp_send_chunk(req, ",", 1);
        httpd_resp_send_chunk(req, tmp, n);
    }
    httpd_resp_send_chunk(req, "]}", -1);
    return httpd_resp_send_chunk(req, NULL, 0);
}

static esp_err_t history_reset_post(httpd_req_t *req)
{
    history_reset();
    httpd_resp_set_type(req, "application/json");
    return httpd_resp_send(req, "{\"ok\":true}", -1);
}

// Catch-all: serve the page for every unmatched GET path.
static esp_err_t any_get(httpd_req_t *req)
{
    httpd_resp_set_type(req, "text/html");
    return httpd_resp_send(req, PAGE_HTML, HTTPD_RESP_USE_STRLEN);
}

// --- OTA firmware upload (POST /ota) ----------------------------------------
// Accepts a raw binary firmware image as the POST body (Content-Type:
// application/octet-stream).  Writes to the inactive OTA slot via
// esp_ota_ops, commits, then reboots after a short grace period so the HTTP
// response can be flushed to the browser.
static void ota_reboot_cb(void *) { esp_restart(); }
static bool s_ota_running = false;

static esp_err_t ota_post(httpd_req_t *req)
{
    int total = req->content_len;
    if (total <= 0 || total > 2 * 1024 * 1024) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "invalid content-length");
        return ESP_FAIL;
    }
    if (s_ota_running) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "ota already running");
        return ESP_FAIL;
    }
    s_ota_running = true;

    const esp_partition_t *upd = esp_ota_get_next_update_partition(NULL);
    if (!upd) {
        s_ota_running = false;
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "no OTA partition");
        return ESP_FAIL;
    }

    esp_ota_handle_t handle = 0;
    if (esp_ota_begin(upd, OTA_WITH_SEQUENTIAL_WRITES, &handle) != ESP_OK) {
        s_ota_running = false;
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "ota begin failed");
        return ESP_FAIL;
    }

    char chunk[1024];
    int received = 0;
    bool ok = true;
    while (received < total && ok) {
        int want = total - received;
        if (want > (int)sizeof(chunk)) want = (int)sizeof(chunk);
        int n = httpd_req_recv(req, chunk, (size_t)want);
        if (n <= 0) { ok = false; break; }
        if (esp_ota_write(handle, chunk, (size_t)n) != ESP_OK) { ok = false; break; }
        received += n;
    }

    if (!ok || esp_ota_end(handle) != ESP_OK ||
        esp_ota_set_boot_partition(upd) != ESP_OK) {
        s_ota_running = false;
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "ota write/end failed");
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "OTA upload done (%d bytes) — rebooting", received);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, "{\"ok\":true}", HTTPD_RESP_USE_STRLEN);

    // Reboot 1.5 s after response flushes.
    esp_timer_handle_t timer;
    esp_timer_create_args_t ta = {};
    ta.callback = ota_reboot_cb;
    ta.name     = "ota_reboot";
    esp_timer_create(&ta, &timer);
    esp_timer_start_once(timer, 1500000);
    return ESP_OK;
}

esp_err_t akvalink_web_start_server(void)
{
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.uri_match_fn     = httpd_uri_match_wildcard;
    config.lru_purge_enable = true;
    config.max_open_sockets = 4;
    config.max_uri_handlers = 13;   // room for all endpoints incl. /ota
    config.recv_wait_timeout = 30;  // allow large OTA uploads

    if (httpd_start(&s_httpd, &config) != ESP_OK) {
        ESP_LOGE(TAG, "httpd_start failed");
        return ESP_FAIL;
    }
    // Register specific handlers before the "/*" catch-all.
    httpd_uri_t h = {};
    h.uri = "/";              h.method = HTTP_GET;  h.handler = root_get;            httpd_register_uri_handler(s_httpd, &h);
    h.uri = "/temp";          h.method = HTTP_GET;  h.handler = temp_get;            httpd_register_uri_handler(s_httpd, &h);
    h.uri = "/battery";       h.method = HTTP_GET;  h.handler = battery_get;         httpd_register_uri_handler(s_httpd, &h);
    h.uri = "/trend";         h.method = HTTP_GET;  h.handler = trend_get;           httpd_register_uri_handler(s_httpd, &h);
    h.uri = "/stats";         h.method = HTTP_GET;  h.handler = stats_get;           httpd_register_uri_handler(s_httpd, &h);
    h.uri = "/history";       h.method = HTTP_GET;  h.handler = history_get;         httpd_register_uri_handler(s_httpd, &h);
    h.uri = "/history/reset"; h.method = HTTP_POST; h.handler = history_reset_post;  httpd_register_uri_handler(s_httpd, &h);
    h.uri = "/ota";           h.method = HTTP_POST; h.handler = ota_post;            httpd_register_uri_handler(s_httpd, &h);
    h.uri = "/*";             h.method = HTTP_GET;  h.handler = any_get;             httpd_register_uri_handler(s_httpd, &h);

    ESP_LOGI(TAG, "HTTP server up — /, /temp, /battery, /trend, /stats, /history, /ota");
    return ESP_OK;
}

httpd_handle_t akvalink_web_get_server(void)
{
    return s_httpd;
}
