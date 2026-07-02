// SPDX-License-Identifier: Apache-2.0
//
// Standalone BLE GATT server for the --ble AquaLink variant (NimBLE).
//
// Services:
//   - Device Information (0x180A): manufacturer, model, firmware revision
//   - Environmental Sensing (0x181A): Temperature 0x2A6E (sint16, 0.01 °C), notify
//   - AquaLink custom service: uptime (uint32 seconds), read + notify
//
// Advertising rotates between legacy 1M (broad phone compatibility, esp. iOS)
// and extended Coded PHY S=8 (long range, ~2-4x). Coded needs CONFIG_BT_NIMBLE_
// EXT_ADV=y (see sdkconfig.defaults.ble). On connect we request Coded S=8.
//
// C++ note: NimBLE's BLE_UUID16_DECLARE()/BLE_UUID128_DECLARE() macros expand
// to C compound literals, which are NOT valid C++. So every UUID here is a
// file-scope `static const ble_uuidNN_t` object referenced by &obj.u.
//
// Verified on NORA-W40 hardware: boots, advertises (rotating 1M legacy +
// Coded PHY S=8), and serves the GATT services over the --ble sdkconfig.

#include "ble_gatt.h"

#include <math.h>
#include <string.h>

#include "esp_log.h"
#include "esp_app_desc.h"
#include "esp_timer.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "nimble/hci_common.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

static const char *TAG = "ble_gatt";

#define DEVICE_NAME "AquaLink"

// Advertising instances: rotate between broad-compat legacy and long-range Coded.
#define ADV_INST_LEGACY 0    // 1M legacy PDUs — best phone compatibility (esp. iOS)
#define ADV_INST_CODED  1    // Coded PHY S=8 — long range (Android / gateway)
#define ADV_ROTATE_MS   4000 // dwell per PHY before switching

static const char *MANUFACTURER = "u-blox";
static const char *MODEL        = "AquaLink NORA-W40";

// --- UUIDs (static objects — see C++ note above) ----------------------------
static const ble_uuid16_t UUID_DIS          = BLE_UUID16_INIT(0x180A);
static const ble_uuid16_t UUID_ESS          = BLE_UUID16_INIT(0x181A);
static const ble_uuid16_t UUID_MANUFACTURER = BLE_UUID16_INIT(0x2A29);
static const ble_uuid16_t UUID_MODEL        = BLE_UUID16_INIT(0x2A24);
static const ble_uuid16_t UUID_FW_REVISION  = BLE_UUID16_INIT(0x2A26);
static const ble_uuid16_t UUID_TEMPERATURE  = BLE_UUID16_INIT(0x2A6E);

// Custom AquaLink service + uptime characteristic (random 128-bit base).
// f0aq0001-6e40-4a71-9b2c-aqualink0001 style; bytes are little-endian.
static const ble_uuid128_t UUID_AQUALINK_SVC = BLE_UUID128_INIT(
    0x01, 0x00, 0x6c, 0x69, 0x6e, 0x6b, 0x2c, 0x9b,
    0x71, 0x4a, 0x40, 0x6e, 0x01, 0x00, 0xa0, 0xf0);
static const ble_uuid128_t UUID_UPTIME = BLE_UUID128_INIT(
    0x02, 0x00, 0x6c, 0x69, 0x6e, 0x6b, 0x2c, 0x9b,
    0x71, 0x4a, 0x40, 0x6e, 0x01, 0x00, 0xa0, 0xf0);

// --- State ------------------------------------------------------------------
static uint8_t  s_own_addr_type   = 0;
static uint16_t s_conn_handle     = BLE_HS_CONN_HANDLE_NONE;
static uint16_t s_temp_val_handle = 0;
static uint16_t s_uptime_val_handle = 0;
static bool     s_temp_subscribed = false;
static int16_t  s_temp_centi      = 0;   // temperature in 0.01 °C units

static void adv_configure(void);
static void adv_rotate_start(uint8_t instance);
static int  build_adv_data(struct os_mbuf **out);

// --- GATT characteristic access (reads) -------------------------------------
static int gatt_access(uint16_t /*conn*/, uint16_t /*attr*/,
                       struct ble_gatt_access_ctxt *ctxt, void * /*arg*/)
{
    if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) {
        return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    }

    // Custom 128-bit uptime characteristic.
    if (ble_uuid_cmp(ctxt->chr->uuid, &UUID_UPTIME.u) == 0) {
        uint32_t uptime_s = (uint32_t)(esp_timer_get_time() / 1000000);
        return os_mbuf_append(ctxt->om, &uptime_s, sizeof(uptime_s)) == 0
                   ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }

    switch (ble_uuid_u16(ctxt->chr->uuid)) {
        case 0x2A29:  // Manufacturer
            return os_mbuf_append(ctxt->om, MANUFACTURER, strlen(MANUFACTURER)) == 0
                       ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
        case 0x2A24:  // Model
            return os_mbuf_append(ctxt->om, MODEL, strlen(MODEL)) == 0
                       ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
        case 0x2A26: {  // Firmware revision — from version.txt / PROJECT_VER
            const esp_app_desc_t *desc = esp_app_get_description();
            return os_mbuf_append(ctxt->om, desc->version, strlen(desc->version)) == 0
                       ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
        }
        case 0x2A6E:  // Temperature (sint16, 0.01 °C, little-endian)
            return os_mbuf_append(ctxt->om, &s_temp_centi, sizeof(s_temp_centi)) == 0
                       ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
        default:
            return BLE_ATT_ERR_UNLIKELY;
    }
}

// --- Service / characteristic tables ----------------------------------------
// NimBLE's ble_gatt_chr_def / ble_gatt_svc_def carry several optional trailing
// members (arg, descriptors, cpfd, min_key_size, includes, …) that we
// deliberately leave zero-defaulted. Scope -Wmissing-field-initializers off for
// just these SDK tables rather than spelling out every field (which also drifts
// between NimBLE versions); our own structs stay warning-checked.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"
static const struct ble_gatt_chr_def s_dis_chrs[] = {
    { .uuid = &UUID_MANUFACTURER.u, .access_cb = gatt_access, .flags = BLE_GATT_CHR_F_READ },
    { .uuid = &UUID_MODEL.u,        .access_cb = gatt_access, .flags = BLE_GATT_CHR_F_READ },
    { .uuid = &UUID_FW_REVISION.u,  .access_cb = gatt_access, .flags = BLE_GATT_CHR_F_READ },
    { 0 },
};

static const struct ble_gatt_chr_def s_ess_chrs[] = {
    { .uuid = &UUID_TEMPERATURE.u, .access_cb = gatt_access,
      .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
      .val_handle = &s_temp_val_handle },
    { 0 },
};

static const struct ble_gatt_chr_def s_aqualink_chrs[] = {
    { .uuid = &UUID_UPTIME.u, .access_cb = gatt_access,
      .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
      .val_handle = &s_uptime_val_handle },
    { 0 },
};

static const struct ble_gatt_svc_def s_services[] = {
    { .type = BLE_GATT_SVC_TYPE_PRIMARY, .uuid = &UUID_DIS.u,          .characteristics = s_dis_chrs },
    { .type = BLE_GATT_SVC_TYPE_PRIMARY, .uuid = &UUID_ESS.u,          .characteristics = s_ess_chrs },
    { .type = BLE_GATT_SVC_TYPE_PRIMARY, .uuid = &UUID_AQUALINK_SVC.u, .characteristics = s_aqualink_chrs },
    { 0 },
};
#pragma GCC diagnostic pop

// --- GAP events -------------------------------------------------------------
static int gap_event(struct ble_gap_event *event, void * /*arg*/)
{
    switch (event->type) {
        case BLE_GAP_EVENT_CONNECT:
            if (event->connect.status == 0) {
                s_conn_handle = event->connect.conn_handle;
                ESP_LOGI(TAG, "central connected (handle %u)", s_conn_handle);
                // Prefer Coded S=8 when the peer supports it; fall back to 1M.
                ble_gap_set_prefered_le_phy(
                    s_conn_handle,
                    BLE_GAP_LE_PHY_1M_MASK | BLE_GAP_LE_PHY_CODED_MASK,
                    BLE_GAP_LE_PHY_1M_MASK | BLE_GAP_LE_PHY_CODED_MASK,
                    BLE_GAP_LE_PHY_CODED_S8);
            } else {
                adv_rotate_start(ADV_INST_LEGACY);  // failed → resume rotation
            }
            break;
        case BLE_GAP_EVENT_DISCONNECT:
            ESP_LOGI(TAG, "central disconnected (reason %d)", event->disconnect.reason);
            s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
            s_temp_subscribed = false;
            adv_rotate_start(ADV_INST_LEGACY);
            break;
        case BLE_GAP_EVENT_SUBSCRIBE:
            if (event->subscribe.attr_handle == s_temp_val_handle) {
                s_temp_subscribed = event->subscribe.cur_notify;
            }
            break;
        case BLE_GAP_EVENT_ADV_COMPLETE:
            // Rotation: legacy -> coded -> legacy … while unconnected.
            if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE) {
                uint8_t next = (event->adv_complete.instance == ADV_INST_LEGACY)
                                   ? ADV_INST_CODED : ADV_INST_LEGACY;
                adv_rotate_start(next);
            }
            break;
        default:
            break;
    }
    return 0;
}

// --- Advertising (rotating legacy 1M + Coded PHY S=8) -----------------------
static int build_adv_data(struct os_mbuf **out)
{
    struct ble_hs_adv_fields fields;
    memset(&fields, 0, sizeof(fields));
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.name = (uint8_t *)DEVICE_NAME;
    fields.name_len = strlen(DEVICE_NAME);
    fields.name_is_complete = 1;
    // Advertise the Environmental Sensing service so temperature apps find us.
    static ble_uuid16_t adv_uuid = BLE_UUID16_INIT(0x181A);
    fields.uuids16 = &adv_uuid;
    fields.num_uuids16 = 1;
    fields.uuids16_is_complete = 1;

    uint8_t buf[BLE_HS_ADV_MAX_SZ];
    uint8_t buf_len = 0;
    int rc = ble_hs_adv_set_fields(&fields, buf, &buf_len, sizeof(buf));
    if (rc != 0) {
        return rc;
    }
    *out = ble_hs_mbuf_from_flat(buf, buf_len);
    return *out ? 0 : BLE_HS_ENOMEM;
}

static void adv_configure(void)
{
    struct ble_gap_ext_adv_params params;
    struct os_mbuf *om;
    int rc;

    // Instance 0 — legacy connectable/scannable on 1M (phone-friendly).
    memset(&params, 0, sizeof(params));
    params.connectable   = 1;
    params.scannable     = 1;
    params.legacy_pdu    = 1;
    params.own_addr_type = s_own_addr_type;
    params.primary_phy   = BLE_HCI_LE_PHY_1M;
    params.secondary_phy = BLE_HCI_LE_PHY_1M;
    params.itvl_min      = BLE_GAP_ADV_ITVL_MS(200);
    params.itvl_max      = BLE_GAP_ADV_ITVL_MS(250);
    params.sid           = ADV_INST_LEGACY;
    rc = ble_gap_ext_adv_configure(ADV_INST_LEGACY, &params, NULL, gap_event, NULL);
    if (rc == 0 && build_adv_data(&om) == 0) {
        ble_gap_ext_adv_set_data(ADV_INST_LEGACY, om);
    } else if (rc != 0) {
        ESP_LOGE(TAG, "ext_adv_configure(legacy) rc=%d", rc);
    }

    // Instance 1 — extended connectable on Coded PHY S=8 (long range).
    // Extended connectable adv cannot be scannable — that's a spec rule.
    memset(&params, 0, sizeof(params));
    params.connectable   = 1;
    params.scannable     = 0;
    params.legacy_pdu    = 0;
    params.own_addr_type = s_own_addr_type;
    params.primary_phy   = BLE_HCI_LE_PHY_CODED;
    params.secondary_phy = BLE_HCI_LE_PHY_CODED;
    params.itvl_min      = BLE_GAP_ADV_ITVL_MS(400);
    params.itvl_max      = BLE_GAP_ADV_ITVL_MS(500);
    params.sid           = ADV_INST_CODED;
    rc = ble_gap_ext_adv_configure(ADV_INST_CODED, &params, NULL, gap_event, NULL);
    if (rc == 0 && build_adv_data(&om) == 0) {
        ble_gap_ext_adv_set_data(ADV_INST_CODED, om);
    } else if (rc != 0) {
        ESP_LOGE(TAG, "ext_adv_configure(coded) rc=%d", rc);
    }
}

static void adv_rotate_start(uint8_t instance)
{
    if (ble_gap_ext_adv_active(instance)) {
        return;  // already advertising on this instance
    }
    // duration is in 10 ms units; stop after ADV_ROTATE_MS so we rotate.
    int rc = ble_gap_ext_adv_start(instance, ADV_ROTATE_MS / 10, 0);
    if (rc != 0) {
        ESP_LOGE(TAG, "ext_adv_start(inst %u) rc=%d", instance, rc);
        return;
    }
    ESP_LOGI(TAG, "advertising: %s",
             instance == ADV_INST_CODED ? "Coded PHY S=8 (long range)" : "1M legacy");
}

// --- Host sync / task -------------------------------------------------------
static void on_sync(void)
{
    int rc = ble_hs_util_ensure_addr(0);
    if (rc != 0) {
        ESP_LOGE(TAG, "ensure_addr rc=%d", rc);
        return;
    }
    rc = ble_hs_id_infer_auto(0, &s_own_addr_type);
    if (rc != 0) {
        ESP_LOGE(TAG, "infer_auto rc=%d", rc);
        return;
    }
    adv_configure();
    adv_rotate_start(ADV_INST_LEGACY);
}

static void on_reset(int reason)
{
    ESP_LOGW(TAG, "nimble reset, reason=%d", reason);
}

static void host_task(void * /*param*/)
{
    nimble_port_run();               // returns only on nimble_port_stop()
    nimble_port_freertos_deinit();
}

// --- Public API -------------------------------------------------------------
esp_err_t aqualink_ble_gatt_start(void)
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

    int rc = ble_gatts_count_cfg(s_services);
    if (rc != 0) { ESP_LOGE(TAG, "count_cfg rc=%d", rc); return ESP_FAIL; }
    rc = ble_gatts_add_svcs(s_services);
    if (rc != 0) { ESP_LOGE(TAG, "add_svcs rc=%d", rc); return ESP_FAIL; }

    rc = ble_svc_gap_device_name_set(DEVICE_NAME);
    if (rc != 0) { ESP_LOGW(TAG, "device_name_set rc=%d", rc); }

    nimble_port_freertos_init(host_task);
    ESP_LOGI(TAG, "🌊 AquaLink BLE GATT server started");
    return ESP_OK;
}

void aqualink_ble_gatt_set_temperature(float celsius)
{
    s_temp_centi = (int16_t)lroundf(celsius * 100.0f);

    if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE || !s_temp_subscribed) {
        return;  // nobody listening — the value is served on the next read
    }
    struct os_mbuf *om = ble_hs_mbuf_from_flat(&s_temp_centi, sizeof(s_temp_centi));
    if (om) {
        ble_gatts_notify_custom(s_conn_handle, s_temp_val_handle, om);
    }
}
