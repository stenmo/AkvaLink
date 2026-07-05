// SPDX-License-Identifier: Apache-2.0
//
// Standalone BLE GATT server for the --ble AkvaLink variant (NimBLE).
//
// Services:
//   - Battery (0x180F): Battery Level 0x2A19 (uint8 0-100, stub=100 until ADC wired)
//   - Device Information (0x180A): manufacturer, model, firmware revision
//   - Environmental Sensing (0x181A): Temperature 0x2A6E (sint16, 0.01 \u00b0C), notify
//   - AkvaLink custom service: uptime, writable device name (NVS-backed),
//     high/low alert thresholds (int16, 0.01 \u00b0C, NVS-backed)
//   - AkvaLink OTA service (128-bit): BLE firmware update — control + data chars
//
// Advertising: legacy connectable/scannable on 1M PHY (broadest phone
// compatibility). Extended advertising API is used so we can set tx_power=127
// (hardware max, 7 dBm conducted / 10 dBm EIRP). Advertises continuously;
// service data beacon refreshed on each new temperature reading.
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
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "nvs_flash.h"
#include "nvs.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/stream_buffer.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "nimble/hci_common.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

static const char *TAG = "ble_gatt";

#define DEVICE_NAME "AkvaLink"

// Advertising instance.
#define ADV_INST        0    // single legacy-1M connectable/scannable instance
#if CONFIG_AKVALINK_BLE_CODED_PHY
#define ADV_INST_LEGACY 0    // 1M legacy PDUs — broad phone compatibility
#define ADV_INST_CODED  1    // Coded PHY S=8 — long range (~2-4×)
#define ADV_ROTATE_MS   CONFIG_AKVALINK_BLE_ADV_ROTATE_MS
#endif
// Advertising interval and Coded PHY toggle from Kconfig
// (menuconfig → AkvaLink → BLE GATT tuning, or sdkconfig.defaults.ble).
#define ADV_ITVL_MS     CONFIG_AKVALINK_BLE_ADV_ITVL_MS

static const char *MANUFACTURER = "u-blox";
static const char *MODEL        = "AkvaLink NORA-W40";

// --- UUIDs (static objects — see C++ note above) ----------------------------
static const ble_uuid16_t UUID_DIS          = BLE_UUID16_INIT(0x180A);
static const ble_uuid16_t UUID_ESS          = BLE_UUID16_INIT(0x181A);
static const ble_uuid16_t UUID_BAS          = BLE_UUID16_INIT(0x180F); // Battery Service
static const ble_uuid16_t UUID_MANUFACTURER = BLE_UUID16_INIT(0x2A29);
static const ble_uuid16_t UUID_MODEL        = BLE_UUID16_INIT(0x2A24);
static const ble_uuid16_t UUID_FW_REVISION  = BLE_UUID16_INIT(0x2A26);
static const ble_uuid16_t UUID_TEMPERATURE  = BLE_UUID16_INIT(0x2A6E);
static const ble_uuid16_t UUID_BATTERY_LVL  = BLE_UUID16_INIT(0x2A19); // Battery Level
static const ble_uuid16_t UUID_CPF          = BLE_UUID16_INIT(0x2904); // Characteristic Presentation Format

// Custom AkvaLink service + uptime characteristic (random 128-bit base).
// f0aq0001-6e40-4a71-9b2c-akvalink0001 style; bytes are little-endian.
static const ble_uuid128_t UUID_AKVALINK_SVC = BLE_UUID128_INIT(
    0x01, 0x00, 0x6c, 0x69, 0x6e, 0x6b, 0x2c, 0x9b,
    0x71, 0x4a, 0x40, 0x6e, 0x01, 0x00, 0xa0, 0xf0);
static const ble_uuid128_t UUID_UPTIME = BLE_UUID128_INIT(
    0x02, 0x00, 0x6c, 0x69, 0x6e, 0x6b, 0x2c, 0x9b,
    0x71, 0x4a, 0x40, 0x6e, 0x01, 0x00, 0xa0, 0xf0);
// Writable device-friendly name (stored in NVS; reflected in GAP on next reboot).
static const ble_uuid128_t UUID_DEV_NAME = BLE_UUID128_INIT(
    0x03, 0x00, 0x6c, 0x69, 0x6e, 0x6b, 0x2c, 0x9b,
    0x71, 0x4a, 0x40, 0x6e, 0x01, 0x00, 0xa0, 0xf0);
// Alert thresholds (sint16, 0.01 \u00b0C). High/low stored in NVS; 0 = disabled.
static const ble_uuid128_t UUID_ALERT_HIGH = BLE_UUID128_INIT(
    0x04, 0x00, 0x6c, 0x69, 0x6e, 0x6b, 0x2c, 0x9b,
    0x71, 0x4a, 0x40, 0x6e, 0x01, 0x00, 0xa0, 0xf0);
static const ble_uuid128_t UUID_ALERT_LOW = BLE_UUID128_INIT(
    0x05, 0x00, 0x6c, 0x69, 0x6e, 0x6b, 0x2c, 0x9b,
    0x71, 0x4a, 0x40, 0x6e, 0x01, 0x00, 0xa0, 0xf0);

// BLE OTA service + control/data characteristics (same 128-bit base).
static const ble_uuid128_t UUID_OTA_SVC = BLE_UUID128_INIT(
    0x10, 0x00, 0x6c, 0x69, 0x6e, 0x6b, 0x2c, 0x9b,
    0x71, 0x4a, 0x40, 0x6e, 0x01, 0x00, 0xa0, 0xf0);
static const ble_uuid128_t UUID_OTA_CTRL = BLE_UUID128_INIT(
    0x11, 0x00, 0x6c, 0x69, 0x6e, 0x6b, 0x2c, 0x9b,
    0x71, 0x4a, 0x40, 0x6e, 0x01, 0x00, 0xa0, 0xf0);
static const ble_uuid128_t UUID_OTA_DATA = BLE_UUID128_INIT(
    0x12, 0x00, 0x6c, 0x69, 0x6e, 0x6b, 0x2c, 0x9b,
    0x71, 0x4a, 0x40, 0x6e, 0x01, 0x00, 0xa0, 0xf0);

// --- State ------------------------------------------------------------------
static uint8_t  s_own_addr_type     = 0;
static uint16_t s_conn_handle       = BLE_HS_CONN_HANDLE_NONE;
static uint16_t s_temp_val_handle   = 0;
static uint16_t s_uptime_val_handle = 0;
static bool     s_temp_subscribed   = false;
static int16_t  s_temp_centi        = 0;   // temperature in 0.01 \u00b0C units

// Battery level (0-100). Stub at 100 % until the ADC circuit is populated.
// Call akvalink_ble_gatt_set_battery() when the ADC is ready.
static uint8_t s_battery_percent = 100;

// Alert thresholds (int16, 0.01 \u00b0C). 0 = disabled. Persisted in NVS.
#define NVS_NS        "akvalink"
#define NVS_KEY_NAME  "devname"
#define NVS_KEY_HIGH  "alert_high"
#define NVS_KEY_LOW   "alert_low"
#define DEV_NAME_MAX  32

static char    s_dev_name[DEV_NAME_MAX + 1] = DEVICE_NAME;
static int16_t s_alert_high = 0;    // 0 = disabled
static int16_t s_alert_low  = 0;    // 0 = disabled

static void load_nvs_settings(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) {
        return;  // no settings yet — use defaults
    }
    size_t len = sizeof(s_dev_name);
    nvs_get_str(h, NVS_KEY_NAME, s_dev_name, &len);
    nvs_get_i16(h, NVS_KEY_HIGH, &s_alert_high);
    nvs_get_i16(h, NVS_KEY_LOW,  &s_alert_low);
    nvs_close(h);
}

// --- BLE OTA state ----------------------------------------------------------
static uint16_t              s_ota_ctrl_handle = 0;
static StreamBufferHandle_t  s_ota_stream = nullptr;
static TaskHandle_t          s_ota_task   = nullptr;
static volatile bool         s_ota_finish = false;
static volatile bool         s_ota_abort  = false;
static uint16_t              s_att_mtu    = 23;   // ATT MTU, updated on negotiation

static void adv_configure(void);
static void adv_start(void);
#if CONFIG_AKVALINK_BLE_CODED_PHY
static void adv_rotate_start(uint8_t instance);
#endif
static int  build_adv_data(struct os_mbuf **out);

// --- GATT characteristic access (reads) -------------------------------------
static int gatt_access(uint16_t /*conn*/, uint16_t /*attr*/,
                       struct ble_gatt_access_ctxt *ctxt, void * /*arg*/)
{
    if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) {
        return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    }

    // Custom 128-bit characteristics.
    if (ble_uuid_cmp(ctxt->chr->uuid, &UUID_UPTIME.u) == 0) {
        uint32_t uptime_s = (uint32_t)(esp_timer_get_time() / 1000000);
        return os_mbuf_append(ctxt->om, &uptime_s, sizeof(uptime_s)) == 0
                   ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if (ble_uuid_cmp(ctxt->chr->uuid, &UUID_DEV_NAME.u) == 0) {
        if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
            // Writable device name: update NVS + in-memory copy.
            uint16_t len = 0;
            char buf[DEV_NAME_MAX + 1] = {};
            ble_hs_mbuf_to_flat(ctxt->om, buf, DEV_NAME_MAX, &len);
            buf[len] = '\0';
            strncpy(s_dev_name, buf, DEV_NAME_MAX);
            nvs_handle_t h;
            if (nvs_open(NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
                nvs_set_str(h, NVS_KEY_NAME, s_dev_name);
                nvs_commit(h);
                nvs_close(h);
            }
            ESP_LOGI(TAG, "Device name updated to \"%s\" (takes effect on reboot)", s_dev_name);
            return 0;
        }
        return os_mbuf_append(ctxt->om, s_dev_name, strlen(s_dev_name)) == 0
                   ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if (ble_uuid_cmp(ctxt->chr->uuid, &UUID_ALERT_HIGH.u) == 0) {
        if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
            uint16_t len = 0;
            ble_hs_mbuf_to_flat(ctxt->om, &s_alert_high, sizeof(s_alert_high), &len);
            nvs_handle_t h;
            if (nvs_open(NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
                nvs_set_i16(h, NVS_KEY_HIGH, s_alert_high);
                nvs_commit(h); nvs_close(h);
            }
            ESP_LOGI(TAG, "Alert high set to %d (%.2f\u00b0C)", s_alert_high, s_alert_high / 100.0f);
            return 0;
        }
        return os_mbuf_append(ctxt->om, &s_alert_high, sizeof(s_alert_high)) == 0
                   ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if (ble_uuid_cmp(ctxt->chr->uuid, &UUID_ALERT_LOW.u) == 0) {
        if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
            uint16_t len = 0;
            ble_hs_mbuf_to_flat(ctxt->om, &s_alert_low, sizeof(s_alert_low), &len);
            nvs_handle_t h;
            if (nvs_open(NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
                nvs_set_i16(h, NVS_KEY_LOW, s_alert_low);
                nvs_commit(h); nvs_close(h);
            }
            ESP_LOGI(TAG, "Alert low set to %d (%.2f\u00b0C)", s_alert_low, s_alert_low / 100.0f);
            return 0;
        }
        return os_mbuf_append(ctxt->om, &s_alert_low, sizeof(s_alert_low)) == 0
                   ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }

    switch (ble_uuid_u16(ctxt->chr->uuid)) {
        case 0x2A29:  // Manufacturer
            return os_mbuf_append(ctxt->om, MANUFACTURER, strlen(MANUFACTURER)) == 0
                       ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
        case 0x2A24:  // Model
            return os_mbuf_append(ctxt->om, MODEL, strlen(MODEL)) == 0
                       ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
        case 0x2A26: {  // Firmware revision
            const esp_app_desc_t *desc = esp_app_get_description();
            return os_mbuf_append(ctxt->om, desc->version, strlen(desc->version)) == 0
                       ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
        }
        case 0x2A6E:  // Temperature (sint16, 0.01 \u00b0C)
            return os_mbuf_append(ctxt->om, &s_temp_centi, sizeof(s_temp_centi)) == 0
                       ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
        case 0x2A19:  // Battery Level (uint8, 0-100 %)
            return os_mbuf_append(ctxt->om, &s_battery_percent, sizeof(s_battery_percent)) == 0
                       ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
        default:
            return BLE_ATT_ERR_UNLIKELY;
    }
}

// --- BLE OTA (custom service) -----------------------------------------------
// Firmware update straight over BLE: the client streams the image in chunks and
// we write it into the passive OTA slot via esp_ota. The flash work runs in a
// dedicated task fed by a stream buffer, so the NimBLE host task never blocks on
// the (multi-second) slot erase or the per-chunk writes.
//
// Protocol:
//   OTA_CTRL (write, + notify status):  0x01 BEGIN | 0x02 END | 0x03 ABORT
//   OTA_DATA (write / write-no-rsp):    raw firmware bytes, in order
//   Status notify on OTA_CTRL: [echoed opcode][result]  (result 0 = OK)

static void ota_notify(uint8_t opcode, uint8_t result)
{
    if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE || s_ota_ctrl_handle == 0) {
        return;
    }
    uint8_t buf[2] = { opcode, result };
    struct os_mbuf *om = ble_hs_mbuf_from_flat(buf, sizeof(buf));
    if (om) {
        ble_gatts_notify_custom(s_conn_handle, s_ota_ctrl_handle, om);
    }
}

static void ota_task(void * /*arg*/)
{
    esp_ota_handle_t       handle = 0;
    const esp_partition_t *part   = esp_ota_get_next_update_partition(NULL);
    if (!part || esp_ota_begin(part, OTA_SIZE_UNKNOWN, &handle) != ESP_OK) {
        ESP_LOGE(TAG, "OTA begin failed");
        ota_notify(0x01, 2);
        s_ota_task = nullptr;
        vTaskDelete(NULL);
        return;
    }
    ESP_LOGI(TAG, "\xF0\x9F\x9A\x80 BLE OTA started → slot '%s' (ATT MTU %u)",
             part->label, s_att_mtu);
    ota_notify(0x01, 0);

    uint8_t  buf[512];
    uint32_t total    = 0;
    uint32_t last_log = 0;
    int64_t  t_start  = esp_timer_get_time();
    bool     failed   = false;

    while (true) {
        size_t n = xStreamBufferReceive(s_ota_stream, buf, sizeof(buf), pdMS_TO_TICKS(100));
        if (n > 0) {
            esp_err_t werr = esp_ota_write(handle, buf, n);
            if (werr != ESP_OK) {
                ESP_LOGE(TAG, "esp_ota_write failed at %lu B: %s",
                         (unsigned long)total, esp_err_to_name(werr));
                failed = true;
            }
            total += n;
            if (total - last_log >= 32768) {
                uint32_t dt_ms = (uint32_t)((esp_timer_get_time() - t_start) / 1000);
                uint32_t kbps  = dt_ms ? (uint32_t)((uint64_t)total * 1000 / dt_ms / 1024) : 0;
                ESP_LOGI(TAG, "OTA progress: %lu B, %lu ms, ~%lu kB/s",
                         (unsigned long)total, (unsigned long)dt_ms, (unsigned long)kbps);
                last_log = total;
            }
        }
        if (s_ota_abort || failed) {
            esp_ota_abort(handle);
            ESP_LOGW(TAG, "BLE OTA aborted at %lu B (%s)", (unsigned long)total,
                     failed ? "write error" : "disconnect/host-abort");
            ota_notify(failed ? 0x02 : 0x03, failed ? 6 : 0);
            break;
        }
        if (s_ota_finish && xStreamBufferIsEmpty(s_ota_stream)) {
            uint32_t dt_ms = (uint32_t)((esp_timer_get_time() - t_start) / 1000);
            ESP_LOGI(TAG, "OTA received %lu B in %lu ms — finalising",
                     (unsigned long)total, (unsigned long)dt_ms);
            if (esp_ota_end(handle) == ESP_OK &&
                esp_ota_set_boot_partition(part) == ESP_OK) {
                ESP_LOGI(TAG, "\xE2\x9C\x85 BLE OTA complete (%lu bytes) — rebooting",
                         (unsigned long)total);
                ota_notify(0x02, 0);
                vTaskDelay(pdMS_TO_TICKS(500));   // let the notify flush
                esp_restart();
            } else {
                ESP_LOGE(TAG, "OTA end / set-boot failed");
                ota_notify(0x02, 4);
            }
            break;
        }
    }
    s_ota_task = nullptr;
    vTaskDelete(NULL);
}

static int ota_access(uint16_t /*conn*/, uint16_t /*attr*/,
                      struct ble_gatt_access_ctxt *ctxt, void * /*arg*/)
{
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
        return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    }

    // Control channel: 1-byte opcode.
    if (ble_uuid_cmp(ctxt->chr->uuid, &UUID_OTA_CTRL.u) == 0) {
        uint8_t  cmd[8];
        uint16_t len = 0;
        ble_hs_mbuf_to_flat(ctxt->om, cmd, sizeof(cmd), &len);
        if (len < 1) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        switch (cmd[0]) {
            case 0x01:  // BEGIN
                if (s_ota_task) { return 0; }   // already running
                s_ota_finish = false;
                s_ota_abort  = false;
                if (!s_ota_stream) {
                    s_ota_stream = xStreamBufferCreate(8192, 1);
                }
                if (!s_ota_stream) { ota_notify(0x01, 7); return 0; }
                xStreamBufferReset(s_ota_stream);
                if (xTaskCreate(ota_task, "ble_ota", 4096, NULL,
                                tskIDLE_PRIORITY + 4, &s_ota_task) != pdPASS) {
                    s_ota_task = nullptr;
                    ota_notify(0x01, 8);
                }
                break;
            case 0x02:  // END
                s_ota_finish = true;
                break;
            case 0x03:  // ABORT
                s_ota_abort = true;
                break;
            default:
                return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        return 0;
    }

    // Data channel: append raw firmware bytes to the stream.
    if (ble_uuid_cmp(ctxt->chr->uuid, &UUID_OTA_DATA.u) == 0) {
        if (!s_ota_task || !s_ota_stream) {
            return BLE_ATT_ERR_UNLIKELY;   // no OTA in progress
        }
        uint8_t  chunk[512];
        uint16_t len = 0;
        ble_hs_mbuf_to_flat(ctxt->om, chunk, sizeof(chunk), &len);
        // Flash is usually faster than BLE, but if the stream buffer fills we
        // drop bytes — log it, because silent drops corrupt the image.
        size_t sent = xStreamBufferSend(s_ota_stream, chunk, len, pdMS_TO_TICKS(200));
        if (sent < len) {
            ESP_LOGW(TAG, "OTA stream full — dropped %u/%u B (flash slower than BLE)",
                     (unsigned)(len - sent), (unsigned)len);
        }
        return 0;
    }

    return BLE_ATT_ERR_UNLIKELY;
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

// Characteristic Presentation Format (0x2904) for Temperature 0x2A6E:
//   Format=0x0E (sint16), Exponent=0xFE (-2 → value/100=°C),
//   Unit=0x272F (degrees Celsius), Namespace=0x01 (BT SIG), Description=0x0000.
// Makes nRF Connect / GATT browsers display the temperature as a decimal °C value.
static const uint8_t s_temp_cpf[] = { 0x0E, 0xFE, 0x2F, 0x27, 0x01, 0x00, 0x00 };
static int cpf_access(uint16_t, uint16_t, struct ble_gatt_access_ctxt *ctxt, void *)
{
    return os_mbuf_append(ctxt->om, s_temp_cpf, sizeof(s_temp_cpf)) == 0
               ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
}
static const struct ble_gatt_dsc_def s_temp_dscs[] = {
    { .uuid = &UUID_CPF.u, .att_flags = BLE_ATT_F_READ, .access_cb = cpf_access },
    { 0 },
};

static const struct ble_gatt_chr_def s_ess_chrs[] = {
    { .uuid = &UUID_TEMPERATURE.u, .access_cb = gatt_access,
      .flags       = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
      .descriptors = s_temp_dscs,
      .val_handle  = &s_temp_val_handle },
    { 0 },
};

static const struct ble_gatt_chr_def s_akvalink_chrs[] = {
    { .uuid = &UUID_UPTIME.u,     .access_cb = gatt_access,
      .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
      .val_handle = &s_uptime_val_handle },
    // Writable device-friendly name (stored in NVS; reflected after reboot).
    { .uuid = &UUID_DEV_NAME.u,   .access_cb = gatt_access,
      .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE },
    // Alert thresholds (sint16, 0.01 \u00b0C; 0 = disabled; stored in NVS).
    { .uuid = &UUID_ALERT_HIGH.u, .access_cb = gatt_access,
      .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE },
    { .uuid = &UUID_ALERT_LOW.u,  .access_cb = gatt_access,
      .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE },
    { 0 },
};

static const struct ble_gatt_chr_def s_bas_chrs[] = {
    { .uuid = &UUID_BATTERY_LVL.u, .access_cb = gatt_access,
      .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY },
    { 0 },
};

static const struct ble_gatt_chr_def s_ota_chrs[] = {
    { .uuid = &UUID_OTA_CTRL.u, .access_cb = ota_access,
      .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_NOTIFY,
      .val_handle = &s_ota_ctrl_handle },
    { .uuid = &UUID_OTA_DATA.u, .access_cb = ota_access,
      .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP },
    { 0 },
};

static const struct ble_gatt_svc_def s_services[] = {
    { .type = BLE_GATT_SVC_TYPE_PRIMARY, .uuid = &UUID_BAS.u,          .characteristics = s_bas_chrs },
    { .type = BLE_GATT_SVC_TYPE_PRIMARY, .uuid = &UUID_DIS.u,          .characteristics = s_dis_chrs },
    { .type = BLE_GATT_SVC_TYPE_PRIMARY, .uuid = &UUID_ESS.u,          .characteristics = s_ess_chrs },
    { .type = BLE_GATT_SVC_TYPE_PRIMARY, .uuid = &UUID_AKVALINK_SVC.u, .characteristics = s_akvalink_chrs },
    { .type = BLE_GATT_SVC_TYPE_PRIMARY, .uuid = &UUID_OTA_SVC.u,      .characteristics = s_ota_chrs },
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
                // Prefer 2M PHY for throughput (BLE OTA: 2 Mbps vs 125 kbps on
                // Coded S=8), falling back to 1M. Connections are close-range
                // (OTA / config); long-range discovery still uses Coded advertising.
                ble_gap_set_prefered_le_phy(
                    s_conn_handle,
                    BLE_GAP_LE_PHY_2M_MASK | BLE_GAP_LE_PHY_1M_MASK,
                    BLE_GAP_LE_PHY_2M_MASK | BLE_GAP_LE_PHY_1M_MASK,
                    0);
            } else {
                adv_start();  // failed \u2014 resume advertising
            }
            break;
        case BLE_GAP_EVENT_DISCONNECT:
            // NimBLE encodes the HCI reason in the low byte (0x200 + hci).
            // 0x13 = remote/host terminated, 0x08 = supervision timeout,
            // 0x3d = connection-event/MIC failure, 0x22 = LMP timeout.
            ESP_LOGW(TAG, "central disconnected (reason %d, HCI 0x%02x)",
                     event->disconnect.reason, event->disconnect.reason & 0xFF);
            s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
            s_att_mtu = 23;
            s_temp_subscribed = false;
            s_ota_abort = true;   // cancel any OTA in flight
            adv_start();
            break;
        case BLE_GAP_EVENT_MTU:
            s_att_mtu = event->mtu.value;
            ESP_LOGI(TAG, "ATT MTU negotiated: %u", s_att_mtu);
            break;
        case BLE_GAP_EVENT_PHY_UPDATE_COMPLETE:
            ESP_LOGI(TAG, "PHY updated: tx=%u rx=%u (1=1M, 2=2M)",
                     event->phy_updated.tx_phy, event->phy_updated.rx_phy);
            break;
        case BLE_GAP_EVENT_SUBSCRIBE:
            if (event->subscribe.attr_handle == s_temp_val_handle) {
                s_temp_subscribed = event->subscribe.cur_notify;
            }
            break;
#if CONFIG_AKVALINK_BLE_CODED_PHY
        case BLE_GAP_EVENT_ADV_COMPLETE:
            // Rotation: legacy \u2192 coded \u2192 legacy \u2026 while unconnected.
            if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE) {
                uint8_t next = (event->adv_complete.instance == ADV_INST_LEGACY)
                                   ? ADV_INST_CODED : ADV_INST_LEGACY;
                adv_rotate_start(next);
            }
            break;
#endif
            break;
    }
    return 0;
}

// --- Advertising (legacy 1M, single instance, continuous) ------------------
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

    // Beacon the latest temperature as ESS (0x181A) service data:
    // [UUID_lo, UUID_hi, temp_lo, temp_hi] — sint16, 0.01 °C, little-endian.
    // Lets an app glance at the value without connecting; refreshed on each
    // adv_start() call.
    uint8_t svc_data[4] = {
        0x1A, 0x18,
        (uint8_t)(s_temp_centi & 0xFF), (uint8_t)((s_temp_centi >> 8) & 0xFF),
    };
    fields.svc_data_uuid16     = svc_data;
    fields.svc_data_uuid16_len = sizeof(svc_data);

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

    // Single instance — legacy connectable/scannable on 1M PHY.
    // Extended advertising API used so we can set tx_power=127 (hardware max).
    memset(&params, 0, sizeof(params));
    params.connectable   = 1;
    params.scannable     = 1;
    params.legacy_pdu    = 1;
    params.own_addr_type = s_own_addr_type;
    params.primary_phy   = BLE_HCI_LE_PHY_1M;
    params.secondary_phy = BLE_HCI_LE_PHY_1M;
    params.itvl_min      = BLE_GAP_ADV_ITVL_MS(ADV_ITVL_MS);
    params.itvl_max      = BLE_GAP_ADV_ITVL_MS(ADV_ITVL_MS);
    params.sid           = ADV_INST;
    params.tx_power      = 127;  // 0x7F = "no preference" → controller uses max (7 dBm conducted)
    int rc = ble_gap_ext_adv_configure(ADV_INST, &params, NULL, gap_event, NULL);
    if (rc == 0 && build_adv_data(&om) == 0) {
        ble_gap_ext_adv_set_data(ADV_INST, om);
    } else if (rc != 0) {
        ESP_LOGE(TAG, "ext_adv_configure rc=%d", rc);
    }
}

static void adv_start(void)
{
    if (ble_gap_ext_adv_active(ADV_INST)) {
        return;  // already advertising
    }
    // Refresh payload so the beacon carries the latest temperature.
    struct os_mbuf *om;
    if (build_adv_data(&om) == 0) {
        ble_gap_ext_adv_set_data(ADV_INST, om);
    }
    // duration=0: advertise indefinitely until a connection is made.
    int rc = ble_gap_ext_adv_start(ADV_INST, 0, 0);
    if (rc != 0) {
        ESP_LOGE(TAG, "ext_adv_start rc=%d", rc);
        return;
    }
    ESP_LOGI(TAG, "advertising (1M legacy, 200 ms interval)");
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
#if CONFIG_AKVALINK_BLE_CODED_PHY
    adv_rotate_start(ADV_INST_LEGACY);
#else
    adv_start();
#endif
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
esp_err_t akvalink_ble_gatt_start(void)
{
    load_nvs_settings();   // load device name + alert thresholds from NVS

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

    rc = ble_svc_gap_device_name_set(s_dev_name);  // uses NVS name if set
    if (rc != 0) { ESP_LOGW(TAG, "device_name_set rc=%d", rc); }

    nimble_port_freertos_init(host_task);
    ESP_LOGI(TAG, "🌊 AkvaLink BLE GATT server started (name: \"%s\", alert high=%d low=%d)",
             s_dev_name, s_alert_high, s_alert_low);
    return ESP_OK;
}

void akvalink_ble_gatt_set_temperature(float celsius)
{
    s_temp_centi = (int16_t)lroundf(celsius * 100.0f);

    if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE || !s_temp_subscribed) {
        return;
    }
    struct os_mbuf *om = ble_hs_mbuf_from_flat(&s_temp_centi, sizeof(s_temp_centi));
    if (om) {
        ble_gatts_notify_custom(s_conn_handle, s_temp_val_handle, om);
    }
}

void akvalink_ble_gatt_set_battery(uint8_t percent)
{
    if (percent > 100) percent = 100;
    s_battery_percent = percent;
    // NOTE: no active notify here — the client reads on demand. Add a
    // val_handle + notify call (like temperature) when the ADC is wired.
}

int16_t akvalink_ble_gatt_get_alert_high(void) { return s_alert_high; }
int16_t akvalink_ble_gatt_get_alert_low(void)  { return s_alert_low;  }

