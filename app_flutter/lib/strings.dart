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
    required this.lookingWider,
    required this.notConnected,
    required this.btOff,
    required this.btUnsupported,
    required this.btUnavailable,
    required this.noDeviceFound,
    required this.justNow,
    required this.firmwareUpdate,
    required this.otaConnectFirst,
    required this.otaFindFirst,
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
    required this.linkWebsite,
    required this.linkGithub,
    required this.chooseDevice,
    required this.cancel,
    required this.unknownDevice,
    // Wi-Fi provisioning + station discovery (see ble/prov_controller.dart
    // and net/station_discovery.dart).
    required this.wifiSetupTitle,
    required this.wifiSetupIntro,
    required this.findSetupDevice,
    required this.provSessionEstablishing,
    required this.provReady,
    required this.provScanNetworks,
    required this.provScanningNetworks,
    required this.provNoNetworks,
    required this.provSelectNetwork,
    required this.provPasswordLabel,
    required this.provJoin,
    required this.provSettingConfig,
    required this.provWaitingResult,
    required this.provJoined,
    required this.provFindingOnLan,
    required this.provNotFoundOnLan,
    required this.setupFailedPrefix,
    required this.tryAgain,
    required this.done,
    required this.openInBrowser,
    // Manual "find on Wi-Fi network" (net/station_discovery.dart), separate
    // from the BLE provisioning flow above.
    required this.findOnNetwork,
    required this.lanDiscoverIntro,
    required this.lanSearching,
    required this.lanNotFoundHint,
    required this.tempToggleHint,
    // Alert thresholds (custom AkvaLink GATT service).
    required this.alertsTitle,
    required this.alertsHint,
    required this.alertHighLabel,
    required this.alertLowLabel,
    required this.alertSave,
    required this.alertSaved,
    required this.alertSaveFailed,
    required this.alertRangeError,
    // Temperature history chart (LAN only — BLE exposes no history).
    required this.historyTitle,
    required this.history24h,
    required this.history7d,
    required this.historyBuilding,
  });

  final String tagline;
  final String connect;
  final String disconnect;
  final String scanning;
  final String connecting;
  final String lookingNearby;
  final String lookingWider;
  final String notConnected;
  final String btOff;
  final String btUnsupported;
  final String btUnavailable;
  final String noDeviceFound;
  final String justNow;
  final String firmwareUpdate;
  final String otaConnectFirst;
  final String otaFindFirst;
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
  final String linkWebsite;
  final String linkGithub;
  final String chooseDevice;
  final String cancel;
  final String unknownDevice;
  final String wifiSetupTitle;
  final String wifiSetupIntro;
  final String findSetupDevice;
  final String provSessionEstablishing;
  final String provReady;
  final String provScanNetworks;
  final String provScanningNetworks;
  final String provNoNetworks;
  final String provSelectNetwork;
  final String provPasswordLabel;
  final String provJoin;
  final String provSettingConfig;
  final String provWaitingResult;
  final String provJoined;
  final String provFindingOnLan;
  final String provNotFoundOnLan;
  final String setupFailedPrefix;
  final String tryAgain;
  final String done;
  final String openInBrowser;
  final String findOnNetwork;
  final String lanDiscoverIntro;
  final String lanSearching;
  final String lanNotFoundHint;
  final String tempToggleHint;
  final String alertsTitle;
  final String alertsHint;
  final String alertHighLabel;
  final String alertLowLabel;
  final String alertSave;
  final String alertSaved;
  final String alertSaveFailed;
  final String alertRangeError;
  final String historyTitle;
  final String history24h;
  final String history7d;
  final String historyBuilding;

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

  String foundOnLan(String host) =>
      isSwedish ? 'Hittades på $host' : 'Found at $host';

  String connectedViaWifi(String host) =>
      isSwedish ? 'Ansluten via Wi-Fi · $host' : 'Connected via Wi-Fi · $host';

  String waitingForReading(String host) => isSwedish
      ? 'Hittades vid $host – väntar på en avläsning…'
      : 'Found $host — waiting for a reading…';

  String reachableAt(String url) =>
      isSwedish ? 'Nås på $url' : 'Reachable at $url';

  String liveTemperature(String celsius) =>
      isSwedish ? 'Live-avläsning: $celsius °C' : 'Live reading: $celsius °C';

  String passwordPromptFor(String ssid) =>
      isSwedish ? 'Ange lösenord för $ssid' : 'Enter password for $ssid';

  String historyRange(String min, String max) => isSwedish
      ? 'Lägst $min °C · högst $max °C'
      : 'Low $min °C · high $max °C';

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
    lookingWider,
    notConnected,
    btOff,
    btUnsupported,
    btUnavailable,
    noDeviceFound,
    justNow,
    firmwareUpdate,
    otaConnectFirst,
    otaFindFirst,
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
    linkWebsite,
    linkGithub,
    chooseDevice,
    cancel,
    unknownDevice,
    wifiSetupTitle,
    wifiSetupIntro,
    findSetupDevice,
    provSessionEstablishing,
    provReady,
    provScanNetworks,
    provScanningNetworks,
    provNoNetworks,
    provSelectNetwork,
    provPasswordLabel,
    provJoin,
    provSettingConfig,
    provWaitingResult,
    provJoined,
    provFindingOnLan,
    provNotFoundOnLan,
    setupFailedPrefix,
    tryAgain,
    done,
    openInBrowser,
    connectedTo('Sensor'),
    updatedAgo(justNow),
    secondsAgo(5),
    minutesAgo(3),
    flashLatestTag('v0.3.2'),
    onDevice('0.3.1'),
    latestLabel('v0.3.2'),
    otaFetchingFor('thread'),
    otaUploading(50),
    foundOnLan('akvalink-pool.local'),
    connectedViaWifi('akvalink-pool.local'),
    waitingForReading('akvalink-pool.local'),
    reachableAt('http://station.local'),
    liveTemperature('26.6'),
    passwordPromptFor('Sensor'),
    findOnNetwork,
    lanDiscoverIntro,
    lanSearching,
    lanNotFoundHint,
    tempToggleHint,
    alertsTitle,
    alertsHint,
    alertHighLabel,
    alertLowLabel,
    alertSave,
    alertSaved,
    alertSaveFailed,
    alertRangeError,
    historyTitle,
    history24h,
    history7d,
    historyBuilding,
    historyRange('26.1', '29.8'),
  ];

  // ---- The two locales ----------------------------------------------------

  static const en = Strings(
    tagline: 'Battery-powered Matter pool & aquatic sensor',
    connect: 'Connect over Bluetooth',
    disconnect: 'Disconnect',
    scanning: 'Scanning…',
    connecting: 'Connecting…',
    lookingNearby: 'Looking for an AkvaLink nearby…',
    lookingWider: 'No AkvaLink found — now looking for all nearby devices…',
    notConnected: 'Not connected',
    btOff: 'Bluetooth is turned off',
    btUnsupported: 'Bluetooth not supported on this device',
    btUnavailable: 'Bluetooth unavailable',
    noDeviceFound: 'No AkvaLink found nearby',
    justNow: 'just now',
    firmwareUpdate: 'Firmware update',
    otaConnectFirst:
        'Connect to an AkvaLink to update its firmware over Bluetooth.',
    otaFindFirst:
        'Find it on the Wi-Fi network first to update its firmware over Wi-Fi.',
    flashLatest: 'Flash latest firmware',
    updating: 'Updating…',
    connectFirst: 'Connect first',
    dismiss: 'Dismiss',
    footerLocal: 'Local Bluetooth or Wi-Fi · no cloud, ever.',
    footerHw: 'u-blox NORA-W40 · ESP32-C6',
    otaFetching: 'Fetching firmware…',
    otaConnecting: 'Connecting…',
    otaErasing: 'Preparing device (erasing slot)…',
    otaFinalising: 'Finalising…',
    otaDone: 'Update sent — device rebooting into new firmware ✓',
    otaFailedPrefix: 'Update failed',
    otaDeviceErrorPrefix: 'Device reported error',
    linkWebsite: 'Website',
    linkGithub: 'GitHub',
    chooseDevice: 'No exact match — choose a nearby device:',
    cancel: 'Cancel',
    unknownDevice: 'Unknown device',
    wifiSetupTitle: 'Wi-Fi setup',
    wifiSetupIntro: 'Set up a fresh AkvaLink station over Bluetooth.',
    findSetupDevice: 'Find AkvaLink in setup mode',
    provSessionEstablishing: 'Opening secure session…',
    provReady: 'Connected',
    provScanNetworks: 'Scan Wi-Fi networks',
    provScanningNetworks: 'Scanning Wi-Fi networks…',
    provNoNetworks: 'No Wi-Fi networks found',
    provSelectNetwork: 'Select a Wi-Fi network',
    provPasswordLabel: 'Password',
    provJoin: 'Join',
    provSettingConfig: 'Sending Wi-Fi credentials…',
    provWaitingResult: 'Waiting for it to join Wi-Fi…',
    provJoined: 'Joined Wi-Fi',
    provFindingOnLan: 'Finding it via mDNS…',
    provNotFoundOnLan:
        'Could not find it via mDNS yet — you can still use the address above.',
    setupFailedPrefix: 'Setup failed',
    tryAgain: 'Try again',
    done: 'Done',
    openInBrowser: 'Open in browser',
    findOnNetwork: 'Find on Wi-Fi network',
    lanDiscoverIntro: 'Locate an already set-up AkvaLink station via mDNS.',
    lanSearching: 'Searching the network…',
    lanNotFoundHint:
        'No AkvaLink found via mDNS. It may be blocked by a firewall or router client isolation.',
    tempToggleHint: 'Tap to switch °C/°F',
    alertsTitle: 'Temperature alerts',
    alertsHint:
        'Saved on the sensor itself. Leave a field empty to switch that alert off.',
    alertHighLabel: 'High',
    alertLowLabel: 'Low',
    alertSave: 'Save',
    alertSaved: 'Saved to the sensor',
    alertSaveFailed: 'Could not save',
    alertRangeError: 'Enter a value between -55 and 125 °C',
    historyTitle: 'History',
    history24h: '24 h',
    history7d: '7 d',
    historyBuilding: 'Building history — check back in a few minutes.',
  );

  static const sv = Strings(
    tagline: 'Batteridriven Matter-sensor för pool och akvarium',
    connect: 'Anslut via Bluetooth',
    disconnect: 'Koppla från',
    scanning: 'Söker…',
    connecting: 'Ansluter…',
    lookingNearby: 'Letar efter en AkvaLink i närheten…',
    lookingWider:
        'Ingen AkvaLink hittades — letar nu efter alla enheter i närheten…',
    notConnected: 'Inte ansluten',
    btOff: 'Bluetooth är avstängt',
    btUnsupported: 'Bluetooth stöds inte på den här enheten',
    btUnavailable: 'Bluetooth är inte tillgängligt',
    noDeviceFound: 'Ingen AkvaLink hittades i närheten',
    justNow: 'just nu',
    firmwareUpdate: 'Uppdatera firmware',
    otaConnectFirst:
        'Anslut till en AkvaLink för att uppdatera dess firmware via Bluetooth.',
    otaFindFirst:
        'Hitta den på Wi-Fi-nätverket för att uppdatera dess firmware via Wi-Fi.',
    flashLatest: 'Installera senaste firmware',
    updating: 'Uppdaterar…',
    connectFirst: 'Anslut först',
    dismiss: 'Stäng',
    footerLocal: 'Lokal Bluetooth eller Wi-Fi · aldrig något moln.',
    footerHw: 'u-blox NORA-W40 · ESP32-C6',
    otaFetching: 'Hämtar firmware…',
    otaConnecting: 'Ansluter…',
    otaErasing: 'Förbereder enheten (raderar minnesbank)…',
    otaFinalising: 'Slutför…',
    otaDone: 'Uppdatering skickad — enheten startar om med ny firmware ✓',
    otaFailedPrefix: 'Uppdateringen misslyckades',
    otaDeviceErrorPrefix: 'Enheten rapporterade ett fel',
    linkWebsite: 'Webbplats',
    linkGithub: 'GitHub',
    chooseDevice: 'Ingen exakt träff — välj en enhet i närheten:',
    cancel: 'Avbryt',
    unknownDevice: 'Okänd enhet',
    wifiSetupTitle: 'Wi-Fi-inställning',
    wifiSetupIntro: 'Konfigurera en ny AkvaLink-station via Bluetooth.',
    findSetupDevice: 'Hitta AkvaLink i inställningsläge',
    provSessionEstablishing: 'Öppnar säker session…',
    provReady: 'Ansluten',
    provScanNetworks: 'Sök Wi-Fi-nätverk',
    provScanningNetworks: 'Söker Wi-Fi-nätverk…',
    provNoNetworks: 'Inga Wi-Fi-nätverk hittades',
    provSelectNetwork: 'Välj ett Wi-Fi-nätverk',
    provPasswordLabel: 'Lösenord',
    provJoin: 'Anslut',
    provSettingConfig: 'Skickar Wi-Fi-uppgifter…',
    provWaitingResult: 'Väntar på att den ska ansluta till Wi-Fi…',
    provJoined: 'Ansluten till Wi-Fi',
    provFindingOnLan: 'Hittar den via mDNS…',
    provNotFoundOnLan:
        'Kunde inte hitta den via mDNS än — du kan ändå använda adressen ovan.',
    setupFailedPrefix: 'Konfigurationen misslyckades',
    tryAgain: 'Försök igen',
    done: 'Klar',
    openInBrowser: 'Öppna i webbläsaren',
    findOnNetwork: 'Hitta på Wi-Fi-nätverket',
    lanDiscoverIntro: 'Hitta en redan konfigurerad AkvaLink-station via mDNS.',
    lanSearching: 'Söker på nätverket…',
    lanNotFoundHint:
        'Ingen AkvaLink hittades via mDNS. Den kan vara blockerad av en brandvägg eller klientisolering i routern.',
    tempToggleHint: 'Tryck för att växla °C/°F',
    alertsTitle: 'Temperaturlarm',
    alertsHint:
        'Sparas i sensorn. Lämna ett fält tomt för att stänga av det larmet.',
    alertHighLabel: 'Hög',
    alertLowLabel: 'Låg',
    alertSave: 'Spara',
    alertSaved: 'Sparat i sensorn',
    alertSaveFailed: 'Kunde inte spara',
    alertRangeError: 'Ange ett värde mellan -55 och 125 °C',
    historyTitle: 'Historik',
    history24h: '24 h',
    history7d: '7 d',
    historyBuilding: 'Bygger historik — kom tillbaka om några minuter.',
  );

  /// Pick a locale's strings from a [Locale] (falls back to English).
  static Strings forLocale(Locale? locale) =>
      locale?.languageCode == 'sv' ? sv : en;
}
