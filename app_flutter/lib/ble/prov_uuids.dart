// SPDX-License-Identifier: Apache-2.0
//
// UUIDs for Espressif's "Unified Provisioning" BLE transport
// (components/protocomm + components/wifi_provisioning in ESP-IDF), used by
// the `--station` firmware variant (see main/station_web.cpp). This is a
// SEPARATE GATT profile from AkvaLink's own custom service (see
// akvalink_uuids.dart) — it only exists transiently, before the device has
// Wi-Fi credentials.
//
// AkvaLink does not define these UUIDs itself — they come entirely from
// ESP-IDF's `protocomm_ble` transport, which builds each characteristic's
// 128-bit UUID by taking a fixed 128-bit "base" UUID and splicing a fixed
// 16-bit endpoint ID into bytes 12-13 (little-endian) of that base, i.e.
// `uuid128_to_16()` in protocomm_ble.c / protocomm_nimble.c:
//
//   base (LSB..MSB): 07 ed 9b 2d 0f 06 7c 87 9b 43 43 6b [4d 24] 75 17
//                                                         ^^^^^ overwritten
//
// Derived by hand from the actual ESP-IDF v5.5 source (not guessed):
//   - components/wifi_provisioning/src/manager.c (wifi_prov_mgr_init):
//     assigns the fixed 16-bit endpoint IDs below.
//   - components/protocomm/src/transports/protocomm_ble.c (populate_gatt_db /
//     protocomm_ble_start): confirms the base UUID bytes and the splice.
// Not yet confirmed against a live device scan (nRF Connect/LightBlue) —
// AkvaLink's `--station` build uses the NimBLE transport
// (protocomm_nimble.c), which was not read line-by-line, only confirmed to
// exist alongside the Bluedroid one read here. Worth a quick sanity check
// with a real scan before shipping a UI around this.
class ProvUuids {
  /// The provisioning service AkvaLink advertises while unprovisioned
  /// (default "AkvaLink" name from PROV_SERVICE_NAME in station_web.cpp).
  static const service = '1775244d-6b43-439b-877c-060f2d9bed07';

  /// Fixed 16-bit endpoint IDs assigned once, in order, by
  /// `wifi_prov_mgr_init()` — every wifi_provisioning-based device (ESP's own
  /// "ESP BLE Provisioning" app included) uses these same five.
  static const ctrlChar = '1775ff4f-6b43-439b-877c-060f2d9bed07'; // prov-ctrl
  static const scanChar = '1775ff50-6b43-439b-877c-060f2d9bed07'; // prov-scan
  static const sessionChar =
      '1775ff51-6b43-439b-877c-060f2d9bed07'; // prov-session
  static const configChar =
      '1775ff52-6b43-439b-877c-060f2d9bed07'; // prov-config
  static const protoVerChar =
      '1775ff53-6b43-439b-877c-060f2d9bed07'; // proto-ver
}
