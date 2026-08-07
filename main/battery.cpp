// SPDX-License-Identifier: Apache-2.0
//
// Battery voltage sensing — see battery.h. Off unless
// CONFIG_AKVALINK_BATTERY_ADC is set, which it isn't by default.

#include "battery.h"

#include "esp_log.h"
#include "sdkconfig.h"

#if CONFIG_AKVALINK_BATTERY_ADC

#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"
#include "esp_adc/adc_oneshot.h"

static const char *TAG = "battery";

// 12 dB gives the widest input span (~0-3.1 V on the ESP32-C6); the divider
// keeps the pack comfortably inside it.
#define BAT_ATTEN     ADC_ATTEN_DB_12
#define BAT_BITWIDTH  ADC_BITWIDTH_DEFAULT

// The pack is a high-impedance source through a deliberately large divider, so
// single conversions are noisy — average a handful.
#define BAT_SAMPLES   16

static adc_oneshot_unit_handle_t s_adc  = NULL;
static adc_cali_handle_t         s_cali = NULL;
static adc_channel_t             s_chan;
static bool                      s_ready = false;

bool akvalink_battery_enabled(void) { return true; }

esp_err_t akvalink_battery_init(void)
{
    if (s_ready) {
        return ESP_OK;
    }

    adc_unit_t unit;
    esp_err_t err = adc_oneshot_io_to_channel(CONFIG_AKVALINK_BATTERY_ADC_GPIO,
                                              &unit, &s_chan);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "GPIO%d is not an ADC pin (%s) — check "
                      "CONFIG_AKVALINK_BATTERY_ADC_GPIO",
                 CONFIG_AKVALINK_BATTERY_ADC_GPIO, esp_err_to_name(err));
        return err;
    }
    if (unit != ADC_UNIT_1) {
        ESP_LOGE(TAG, "GPIO%d is on ADC%d; only ADC1 is usable here",
                 CONFIG_AKVALINK_BATTERY_ADC_GPIO, unit + 1);
        return ESP_ERR_NOT_SUPPORTED;
    }

    adc_oneshot_unit_init_cfg_t unit_cfg = {};
    unit_cfg.unit_id = ADC_UNIT_1;
    err = adc_oneshot_new_unit(&unit_cfg, &s_adc);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "adc_oneshot_new_unit failed: %s", esp_err_to_name(err));
        return err;
    }

    adc_oneshot_chan_cfg_t chan_cfg = {};
    chan_cfg.atten    = BAT_ATTEN;
    chan_cfg.bitwidth = BAT_BITWIDTH;
    err = adc_oneshot_config_channel(s_adc, s_chan, &chan_cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "adc_oneshot_config_channel failed: %s", esp_err_to_name(err));
        adc_oneshot_del_unit(s_adc);
        s_adc = NULL;
        return err;
    }

    // Without eFuse calibration data the raw counts are only roughly linear;
    // we still run, just with a cruder volts conversion.
#if ADC_CALI_SCHEME_CURVE_FITTING_SUPPORTED
    adc_cali_curve_fitting_config_t cali_cfg = {};
    cali_cfg.unit_id  = ADC_UNIT_1;
    cali_cfg.chan     = s_chan;
    cali_cfg.atten    = BAT_ATTEN;
    cali_cfg.bitwidth = BAT_BITWIDTH;
    if (adc_cali_create_scheme_curve_fitting(&cali_cfg, &s_cali) != ESP_OK) {
        ESP_LOGW(TAG, "no ADC calibration available — voltages are approximate");
        s_cali = NULL;
    }
#else
    ESP_LOGW(TAG, "no ADC calibration scheme on this chip — voltages are approximate");
    s_cali = NULL;
#endif

    s_ready = true;
    ESP_LOGI(TAG, "Battery sensing on GPIO%d (ADC1_CH%d), divider %d/1000, "
                  "%d mV = 0%%, %d mV = 100%%",
             CONFIG_AKVALINK_BATTERY_ADC_GPIO, s_chan,
             CONFIG_AKVALINK_BATTERY_DIVIDER_PERMILLE,
             CONFIG_AKVALINK_BATTERY_EMPTY_MV, CONFIG_AKVALINK_BATTERY_FULL_MV);
    return ESP_OK;
}

bool akvalink_battery_read(int *out_mv, uint8_t *out_percent)
{
    if (!s_ready) {
        return false;
    }

    int32_t sum = 0;
    int n = 0;
    for (int i = 0; i < BAT_SAMPLES; i++) {
        int raw = 0;
        if (adc_oneshot_read(s_adc, s_chan, &raw) == ESP_OK) {
            sum += raw;
            n++;
        }
    }
    if (n == 0) {
        ESP_LOGW(TAG, "ADC read failed");
        return false;
    }

    const int raw_avg = (int)(sum / n);

    int adc_mv = 0;
    if (s_cali) {
        if (adc_cali_raw_to_voltage(s_cali, raw_avg, &adc_mv) != ESP_OK) {
            return false;
        }
    } else {
        // Uncalibrated fallback: assume the nominal full-scale for 12 dB.
        adc_mv = raw_avg * 3100 / 4095;
    }

    // Undo the divider to get back to the pack voltage.
    const int pack_mv = adc_mv * 1000 / CONFIG_AKVALINK_BATTERY_DIVIDER_PERMILLE;

    const int empty = CONFIG_AKVALINK_BATTERY_EMPTY_MV;
    const int full  = CONFIG_AKVALINK_BATTERY_FULL_MV;
    int pct = 0;
    if (full > empty) {
        pct = (pack_mv - empty) * 100 / (full - empty);
        if (pct < 0)   pct = 0;
        if (pct > 100) pct = 100;
    }

    if (out_mv)      *out_mv = pack_mv;
    if (out_percent) *out_percent = (uint8_t)pct;
    ESP_LOGD(TAG, "raw %d -> %d mV at pin -> %d mV pack -> %d %%",
             raw_avg, adc_mv, pack_mv, pct);
    return true;
}

#else  // !CONFIG_AKVALINK_BATTERY_ADC

bool akvalink_battery_enabled(void) { return false; }

esp_err_t akvalink_battery_init(void) { return ESP_OK; }

bool akvalink_battery_read(int *out_mv, uint8_t *out_percent)
{
    (void)out_mv;
    (void)out_percent;
    return false;
}

#endif // CONFIG_AKVALINK_BATTERY_ADC
