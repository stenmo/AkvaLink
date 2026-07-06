// SPDX-License-Identifier: Apache-2.0
//
// The GATT contract AkvaLink firmware exposes. Kept byte-for-byte in step with
// main/ble_gatt.cpp and main/ble_escape.cpp.

/// BT SIG assigned 16-bit UUIDs, expanded to the 128-bit base so `universal_ble`
/// matches them on every platform (some backends don't accept the short form).
class AkvaUuids {
  // Environmental Sensing — live temperature (sint16, 0.01 °C, notify).
  static const essService = '0000181a-0000-1000-8000-00805f9b34fb';
  static const tempChar = '00002a6e-0000-1000-8000-00805f9b34fb';

  // Device Information — firmware revision "{version}-{variant}".
  static const disService = '0000180a-0000-1000-8000-00805f9b34fb';
  static const fwChar = '00002a26-0000-1000-8000-00805f9b34fb';
  static const modelChar = '00002a24-0000-1000-8000-00805f9b34fb';
  static const mfrChar = '00002a29-0000-1000-8000-00805f9b34fb';

  // Battery Service — level 0-100 %.
  static const basService = '0000180f-0000-1000-8000-00805f9b34fb';
  static const batteryChar = '00002a19-0000-1000-8000-00805f9b34fb';

  // Custom AkvaLink OTA service (128-bit). Same base as ble_gatt.cpp:
  //   f0a00001-6e40-4a71-9b2c-6b6e696c00XX
  static const otaService = 'f0a00001-6e40-4a71-9b2c-6b6e696c0010';
  static const otaCtrl =
      'f0a00001-6e40-4a71-9b2c-6b6e696c0011'; // write + notify status
  static const otaData =
      'f0a00001-6e40-4a71-9b2c-6b6e696c0012'; // write firmware chunks

  // OTA control opcodes (written to otaCtrl).
  static const otaBegin = 0x01;
  static const otaEnd = 0x02;
  static const otaAbort = 0x03;

  /// The name prefix the firmware advertises with.
  static const namePrefix = 'AkvaLink';
}
