// SPDX-License-Identifier: Apache-2.0
//
// All user-facing strings, in English (source of truth) and Swedish — mirroring
// the EN/SV split of the web landing page. The spell-check test asserts key
// parity between the two and screens both for common misspellings.
//
// Brand tokens ("AkvaLink", "u-blox", "NORA-W40", "Matter", "Bluetooth",
// "ESP32-C6", firmware variant slugs) are intentionally NOT translated.

import 'dart:ui';

class Strings {
  const Strings({
    required this.tagline,
    required this.connect,
    required this.disconnect,
    required this.scanning,
    required this.connecting,
    required this.lookingNearby,
    required this.notConnected,
    required this.btOff,
    required this.btUnsupported,
    required this.btUnavailable,
    required this.noDeviceFound,
    required this.justNow,
    required this.firmwareUpdate,
    required this.otaConnectFirst,
    required this.flashLatest,
    required this.updating,
    required this.connectFirst,
    required this.dismiss,
    required this.footerLocal,
    required this.footerHw,
    // OTA status line (transient).
    required this.otaFetching,
    required this.otaConnecting,
    required this.otaErasing,
    required this.otaFinalising,
    required this.otaDone,
    required this.otaFailedPrefix,
    required this.otaDeviceErrorPrefix,
  });

  final String tagline;
  final String connect;
  final String disconnect;
  final String scanning;
  final String connecting;
  final String lookingNearby;
  final String notConnected;
  final String btOff;
  final String btUnsupported;
  final String btUnavailable;
  final String noDeviceFound;
  final String justNow;
  final String firmwareUpdate;
  final String otaConnectFirst;
  final String flashLatest;
  final String updating;
  final String connectFirst;
  final String dismiss;
  final String footerLocal;
  final String footerHw;
  final String otaFetching;
  final String otaConnecting;
  final String otaErasing;
  final String otaFinalising;
  final String otaDone;
  final String otaFailedPrefix;
  final String otaDeviceErrorPrefix;

  // ---- Parameterised helpers (kept out of the constructor) ----------------

  String connectedTo(String name) =>
      isSwedish ? 'Ansluten · $name' : 'Connected · $name';

  String updatedAgo(String age) =>
      isSwedish ? 'uppdaterad $age' : 'updated $age';

  String secondsAgo(int s) => isSwedish ? 'för $s s sedan' : '${s}s ago';

  String minutesAgo(int m) => isSwedish ? 'för $m min sedan' : '${m}m ago';

  String flashLatestTag(String tag) => isSwedish
      ? 'Installera senaste firmware ($tag)'
      : 'Flash latest firmware ($tag)';

  String onDevice(String version) =>
      isSwedish ? 'På enheten: v$version' : 'On device: v$version';

  String latestLabel(String tag) =>
      isSwedish ? 'senaste: $tag' : 'latest: $tag';

  String otaFetchingFor(String variant) => isSwedish
      ? 'Hämtar senaste $variant-firmware…'
      : 'Fetching latest $variant firmware…';

  String otaUploading(int percent) =>
      isSwedish ? 'Laddar upp $percent %' : 'Uploading $percent%';

  bool get isSwedish => this == sv;

  /// Every user-facing string (constants + a sample render of each
  /// parameterised helper). Used by the spell-check test to screen the whole
  /// surface. Excludes [footerHw], which is pure brand/part tokens.
  List<String> debugAllStrings() => [
    tagline,
    connect,
    disconnect,
    scanning,
    connecting,
    lookingNearby,
    notConnected,
    btOff,
    btUnsupported,
    btUnavailable,
    noDeviceFound,
    justNow,
    firmwareUpdate,
    otaConnectFirst,
    flashLatest,
    updating,
    connectFirst,
    dismiss,
    footerLocal,
    otaFetching,
    otaConnecting,
    otaErasing,
    otaFinalising,
    otaDone,
    otaFailedPrefix,
    otaDeviceErrorPrefix,
    connectedTo('Sensor'),
    updatedAgo(justNow),
    secondsAgo(5),
    minutesAgo(3),
    flashLatestTag('v0.3.2'),
    onDevice('0.3.1'),
    latestLabel('v0.3.2'),
    otaFetchingFor('thread'),
    otaUploading(50),
  ];

  // ---- The two locales ----------------------------------------------------

  static const en = Strings(
    tagline: 'Battery-powered Matter pool & aquatic sensor',
    connect: 'Connect over Bluetooth',
    disconnect: 'Disconnect',
    scanning: 'Scanning…',
    connecting: 'Connecting…',
    lookingNearby: 'Looking for an AkvaLink nearby…',
    notConnected: 'Not connected',
    btOff: 'Bluetooth is turned off',
    btUnsupported: 'Bluetooth not supported on this device',
    btUnavailable: 'Bluetooth unavailable',
    noDeviceFound: 'No AkvaLink found nearby',
    justNow: 'just now',
    firmwareUpdate: 'Firmware update',
    otaConnectFirst:
        'Connect to an AkvaLink to update its firmware over Bluetooth.',
    flashLatest: 'Flash latest firmware',
    updating: 'Updating…',
    connectFirst: 'Connect first',
    dismiss: 'Dismiss',
    footerLocal: 'Local Bluetooth only · no cloud, ever.',
    footerHw: 'u-blox NORA-W40 · ESP32-C6',
    otaFetching: 'Fetching firmware…',
    otaConnecting: 'Connecting…',
    otaErasing: 'Preparing device (erasing slot)…',
    otaFinalising: 'Finalising…',
    otaDone: 'Update sent — device rebooting into new firmware ✓',
    otaFailedPrefix: 'Update failed',
    otaDeviceErrorPrefix: 'Device reported error',
  );

  static const sv = Strings(
    tagline: 'Batteridriven Matter-sensor för pool och akvarium',
    connect: 'Anslut via Bluetooth',
    disconnect: 'Koppla från',
    scanning: 'Söker…',
    connecting: 'Ansluter…',
    lookingNearby: 'Letar efter en AkvaLink i närheten…',
    notConnected: 'Inte ansluten',
    btOff: 'Bluetooth är avstängt',
    btUnsupported: 'Bluetooth stöds inte på den här enheten',
    btUnavailable: 'Bluetooth är inte tillgängligt',
    noDeviceFound: 'Ingen AkvaLink hittades i närheten',
    justNow: 'just nu',
    firmwareUpdate: 'Uppdatera firmware',
    otaConnectFirst:
        'Anslut till en AkvaLink för att uppdatera dess firmware via Bluetooth.',
    flashLatest: 'Installera senaste firmware',
    updating: 'Uppdaterar…',
    connectFirst: 'Anslut först',
    dismiss: 'Stäng',
    footerLocal: 'Endast lokal Bluetooth · aldrig något moln.',
    footerHw: 'u-blox NORA-W40 · ESP32-C6',
    otaFetching: 'Hämtar firmware…',
    otaConnecting: 'Ansluter…',
    otaErasing: 'Förbereder enheten (raderar minnesbank)…',
    otaFinalising: 'Slutför…',
    otaDone: 'Uppdatering skickad — enheten startar om med ny firmware ✓',
    otaFailedPrefix: 'Uppdateringen misslyckades',
    otaDeviceErrorPrefix: 'Enheten rapporterade ett fel',
  );

  /// Pick a locale's strings from a [Locale] (falls back to English).
  static Strings forLocale(Locale? locale) =>
      locale?.languageCode == 'sv' ? sv : en;
}
