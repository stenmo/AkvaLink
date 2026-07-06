// SPDX-License-Identifier: Apache-2.0
//
// ble_escape.cpp — minimal BLE escape hatch for --thread and --ap variants.
//
// Activated when GPIO9 (BOOT button) is held at power-on (see app_main.cpp).
// Exposes a minimal GATT server so a phone can:
//   - Read/subscribe to live temperature (ESS 0x181A / Temperature 0x2A6E)
//   - Read manufacturer and firmware revision (DIS 0x180A)
//
// Uses the legacy ble_gap_adv API (not extended advertising), so it compiles
// and runs on Thread builds (BT_NIMBLE_EXT_ADV=n) as well as AP builds.
// No OTA service, no custom service, no NVS — smallest possible escape path.
//
// The linker dead-strips everything in this file when akvalink_ble_escape_start()
// is never referenced (CONFIG_AKVALINK_BLE_ESCAPE_HATCH=n), so there is zero
// flash cost when the feature is disabled.

#include "ble_escape.h"
#include "app_priv.h"   // AKVALINK_VARIANT_STR

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "esp_app_desc.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

static const char *TAG = "ble_esc";

static int16_t  s_temp_centi    = 0;
static uint16_t s_temp_handle   = 0;
static uint16_t s_conn_handle   = BLE_HS_CONN_HANDLE_NONE;
static bool     s_subscribed    = false;
static uint8_t  s_own_addr_type = 0;

#define ADV_ITVL_MS 500u   // 500 ms — diagnostics mode, discovery speed > battery

// --- GATT callbacks ---------------------------------------------------------

static int dis_mfr_cb(uint16_t /*conn*/, uint16_t /*attr*/,
                      struct ble_gatt_access_ctxt *ctx, void * /*arg*/)
{
    static const char mfr[] = "u-blox";
    return os_mbuf_append(ctx->om, mfr, sizeof(mfr) - 1)
               ? BLE_ATT_ERR_INSUFFICIENT_RES : 0;
}

static int dis_fw_cb(uint16_t /*conn*/, uint16_t /*attr*/,
                     struct ble_gatt_access_ctxt *ctx, void * /*arg*/)
{
    // "{version}-{variant}" so a BLE app can auto-select the right OTA binary.
    char buf[48];
    snprintf(buf, sizeof(buf), "%s-" AKVALINK_VARIANT_STR,
             esp_app_get_description()->version);
    return os_mbuf_append(ctx->om, buf, strlen(buf))
               ? BLE_ATT_ERR_INSUFFICIENT_RES : 0;
}

static int ess_temp_cb(uint16_t /*conn*/, uint16_t /*attr*/,
                       struct ble_gatt_access_ctxt *ctx, void * /*arg*/)
{
    if (ctx->op != BLE_GATT_ACCESS_OP_READ_CHR)
        return BLE_ATT_ERR_UNLIKELY;
    return os_mbuf_append(ctx->om, &s_temp_centi, sizeof(s_temp_centi))
               ? BLE_ATT_ERR_INSUFFICIENT_RES : 0;
}

// --- UUIDs ------------------------------------------------------------------
// BLE_UUID16_DECLARE() is a C compound literal, invalid in C++.
// Each UUID is a file-scope const object referenced via &obj.u.

static const ble_uuid16_t s_uuid_dis  = BLE_UUID16_INIT(0x180A);
static const ble_uuid16_t s_uuid_ess  = BLE_UUID16_INIT(0x181A);
static const ble_uuid16_t s_uuid_mfr  = BLE_UUID16_INIT(0x2A29);
static const ble_uuid16_t s_uuid_fw   = BLE_UUID16_INIT(0x2A26);
static const ble_uuid16_t s_uuid_temp = BLE_UUID16_INIT(0x2A6E);

// --- GATT service table -----------------------------------------------------
// Struct field order: uuid, access_cb, arg, descriptors, flags, min_key_size,
// val_handle.  Unspecified (skipped) fields are zero-initialised.
// Suppress -Wmissing-field-initializers: the { 0 } sentinel entries leave
// fields unset by design (NULL uuid = end-of-array marker for NimBLE).
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"

static const struct ble_gatt_svc_def s_svcs[] = {
    {   // DIS — Device Information Service (0x180A)
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_uuid_dis.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            { .uuid = &s_uuid_mfr.u, .access_cb = dis_mfr_cb,
              .flags = BLE_GATT_CHR_F_READ },
            { .uuid = &s_uuid_fw.u,  .access_cb = dis_fw_cb,
              .flags = BLE_GATT_CHR_F_READ },
            { 0 },
        },
    },
    {   // ESS — Environmental Sensing Service (0x181A)
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_uuid_ess.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {   .uuid       = &s_uuid_temp.u,
                .access_cb  = ess_temp_cb,
                .flags      = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &s_temp_handle,
            },
            { 0 },
        },
    },
    { 0 },
};
#pragma GCC diagnostic pop

// --- Advertising (legacy — compatible with BT_NIMBLE_EXT_ADV=n) -------------

// Forward declaration: adv_start and gap_event call each other.
static int gap_event(struct ble_gap_event *ev, void *arg);

static void adv_start(void)
{
    if (ble_gap_adv_active()) return;

    struct ble_hs_adv_fields fields = {};
    fields.flags            = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.name             = (const uint8_t *)"AkvaLink";
    fields.name_len         = 8;
    fields.name_is_complete = 1;

    // ESS UUID in the PDU — temperature scanner apps find us without connecting.
    static ble_uuid16_t adv_uuid16 = BLE_UUID16_INIT(0x181A);
    fields.uuids16             = &adv_uuid16;
    fields.num_uuids16         = 1;
    fields.uuids16_is_complete = 1;

    // ESS service-data beacon: [UUID lo, UUID hi, temp lo, temp hi]
    // Lets a passive scanner see the temperature without connecting.
    uint8_t svc_data[4] = {
        0x1A, 0x18,
        (uint8_t)(s_temp_centi & 0xFF),
        (uint8_t)((s_temp_centi >> 8) & 0xFF),
    };
    fields.svc_data_uuid16     = svc_data;
    fields.svc_data_uuid16_len = sizeof(svc_data);

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "adv_set_fields rc=%d", rc);
        return;
    }

    struct ble_gap_adv_params params = {};
    params.conn_mode = BLE_GAP_CONN_MODE_UND;
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    params.itvl_min  = BLE_GAP_ADV_ITVL_MS(ADV_ITVL_MS);
    params.itvl_max  = BLE_GAP_ADV_ITVL_MS(ADV_ITVL_MS);

    rc = ble_gap_adv_start(s_own_addr_type, NULL, BLE_HS_FOREVER,
                           &params, gap_event, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "adv_start rc=%d", rc);
    } else {
        ESP_LOGI(TAG, "advertising 'AkvaLink' (legacy 1M, %u ms interval)",
                 (unsigned)ADV_ITVL_MS);
    }
}

// --- GAP event handler ------------------------------------------------------

static int gap_event(struct ble_gap_event *ev, void * /*arg*/)
{
    switch (ev->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (ev->connect.status == 0) {
            s_conn_handle = ev->connect.conn_handle;
            ESP_LOGI(TAG, "connected (handle %d)", s_conn_handle);
            // Request MTU exchange immediately so we don't stay at 23 bytes.
            // CONFIG_BT_NIMBLE_ATT_PREFERRED_MTU controls the upper bound.
            ble_gattc_exchange_mtu(s_conn_handle, NULL, NULL);
            // Request 15 ms connection interval (12 × 1.25 ms = iOS minimum).
            {
                struct ble_gap_upd_params cp = {};
                cp.itvl_min            = 12;   // 15 ms
                cp.itvl_max            = 24;   // 30 ms
                cp.latency             = 0;
                cp.supervision_timeout = 400;  // 5 s
                cp.min_ce_len          = 0;
                cp.max_ce_len          = 0;
                ble_gap_update_params(s_conn_handle, &cp);
            }
        } else {
            s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
            adv_start();
        }
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        s_subscribed  = false;
        ESP_LOGI(TAG, "disconnected (reason %d) — restarting adv",
                 ev->disconnect.reason);
        adv_start();
        break;
    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(TAG, "ATT MTU negotiated: %u", ev->mtu.value);
        break;
    case BLE_GAP_EVENT_SUBSCRIBE:
        s_subscribed = (ev->subscribe.cur_notify != 0);
        break;
    default:
        break;
    }
    return 0;
}

// --- Host sync / task -------------------------------------------------------

static void on_sync(void)
{
    int rc = ble_hs_util_ensure_addr(0);
    if (rc != 0) { ESP_LOGE(TAG, "ensure_addr rc=%d", rc); return; }
    rc = ble_hs_id_infer_auto(0, &s_own_addr_type);
    if (rc != 0) { ESP_LOGE(TAG, "infer_auto rc=%d", rc); return; }
    adv_start();
}

static void on_reset(int reason)
{
    ESP_LOGW(TAG, "nimble reset reason=%d", reason);
}

static void host_task(void * /*param*/)
{
    nimble_port_run();               // returns only on nimble_port_stop()
    nimble_port_freertos_deinit();
}

// --- Public API -------------------------------------------------------------

esp_err_t akvalink_ble_escape_start(void)
{
    esp_err_t err = nimble_port_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init failed: %d", err);
        return err;
    }

    ble_hs_cfg.sync_cb  = on_sync;
    ble_hs_cfg.reset_cb = on_reset;

    ble_svc_gap_init();
    ble_svc_gatt_init();

    int rc = ble_gatts_count_cfg(s_svcs);
    if (rc != 0) { ESP_LOGE(TAG, "count_cfg rc=%d", rc); return ESP_FAIL; }
    rc = ble_gatts_add_svcs(s_svcs);
    if (rc != 0) { ESP_LOGE(TAG, "add_svcs rc=%d", rc); return ESP_FAIL; }

    rc = ble_svc_gap_device_name_set("AkvaLink");
    if (rc != 0) { ESP_LOGW(TAG, "device_name_set rc=%d", rc); }

    nimble_port_freertos_init(host_task);
    ESP_LOGI(TAG,
             "\xF0\x9F\x8C\x8A AkvaLink BLE escape hatch active "
             "(DIS + ESS temperature — hold GPIO9 at reset to exit)");
    return ESP_OK;
}

void akvalink_ble_escape_set_temperature(float celsius)
{
    s_temp_centi = (int16_t)lroundf(celsius * 100.0f);

    // Refresh beacon when not connected — stop/start to update service data.
    if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE) {
        if (ble_gap_adv_active()) {
            ble_gap_adv_stop();
            adv_start();
        }
        return;
    }

    if (!s_subscribed) return;

    struct os_mbuf *om = ble_hs_mbuf_from_flat(&s_temp_centi, sizeof(s_temp_centi));
    if (om) {
        ble_gatts_notify_custom(s_conn_handle, s_temp_handle, om);
    }
}
