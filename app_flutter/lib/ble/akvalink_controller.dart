// SPDX-License-Identifier: Apache-2.0
//
// AkvaLinkController — a ChangeNotifier that owns the BLE lifecycle:
// scan → connect → subscribe temperature → read firmware/battery. The UI
// (provider) just listens; all BLE detail lives here.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import 'akvalink_uuids.dart';
import '../strings.dart';

enum AkvaConnState { idle, scanning, connecting, connected, error, selecting }

class AkvaLinkController extends ChangeNotifier {
  AkvaLinkController({
    Duration scanSettle = const Duration(seconds: 4),
    Strings strings = Strings.en,
  }) : _scanSettle = scanSettle,
       _s = strings;

  /// How long to keep scanning to find the strongest advertiser before
  /// connecting. Short in tests, a few seconds in production.
  final Duration _scanSettle;
  final Strings _s;

  AkvaConnState _state = AkvaConnState.idle;
  AkvaConnState get state => _state;

  String? _deviceId;
  String? get deviceId => _deviceId;

  String _deviceName = AkvaUuids.namePrefix;
  String get deviceName => _deviceName;

  double? _temperatureC; // null until first reading
  double? get temperatureC => _temperatureC;

  int? _batteryPercent;
  int? get batteryPercent => _batteryPercent;

  /// Full firmware revision string, e.g. "0.3.1-thread".
  String? _firmware;
  String? get firmware => _firmware;

  /// Parsed variant from [firmware] (the part after the last '-'), e.g. "thread".
  String? get variant => parseVariant(_firmware);

  /// Parsed version from [firmware] (the part before the last '-'), e.g. "0.3.1".
  String? get firmwareVersion => parseVersion(_firmware);

  /// Extract the variant suffix from a firmware revision like "0.3.1-thread".
  static String? parseVariant(String? fw) {
    if (fw == null || !fw.contains('-')) return null;
    return fw.substring(fw.lastIndexOf('-') + 1);
  }

  /// Extract the version prefix from a firmware revision like "0.3.1-thread".
  static String? parseVersion(String? fw) {
    if (fw == null) return null;
    return fw.contains('-') ? fw.substring(0, fw.lastIndexOf('-')) : fw;
  }

  DateTime? _lastUpdate;
  DateTime? get lastUpdate => _lastUpdate;

  String? _error;
  String? get error => _error;

  /// Devices found by the broader, unfiltered fallback scan (see
  /// [_scanAllFallback]) — populated only when no AkvaLink-shaped device was
  /// found by name/service, so the user can pick one manually.
  List<BleDevice> _discovered = [];
  List<BleDevice> get discoveredDevices => List.unmodifiable(_discovered);

  /// True once the name/service scan came up empty and the broader,
  /// unfiltered fallback scan has taken over — lets the UI say what it's
  /// actually looking for right now.
  bool _scanningAll = false;
  bool get isScanningAll => _scanningAll;

  StreamSubscription<BleDevice>? _scanSub;
  StreamSubscription<bool>? _connSub;
  StreamSubscription<Uint8List>? _tempSub;
  Timer? _scanTimeout;

  bool get isConnected => _state == AkvaConnState.connected;

  void _set(AkvaConnState s, {String? error}) {
    _state = s;
    _error = error;
    notifyListeners();
  }

  /// Ensure BLE is available and permissions granted. Returns an error string
  /// on failure, or null on success.
  Future<String?> _preflight() async {
    try {
      final avail = await UniversalBle.getBluetoothAvailabilityState();
      if (avail == AvailabilityState.unsupported) {
        return _s.btUnsupported;
      }
      if (avail == AvailabilityState.poweredOff) {
        return _s.btOff;
      }
      final ok = await UniversalBle.hasPermissions();
      if (!ok) await UniversalBle.requestPermissions();
      return null;
    } catch (e) {
      return '${_s.btUnavailable}: $e';
    }
  }

  /// Scan for the nearest AkvaLink and connect to it. If [deviceId] is given,
  /// connect straight to that (a previously-seen device).
  Future<void> scanAndConnect() async {
    if (_state == AkvaConnState.scanning ||
        _state == AkvaConnState.connecting ||
        _state == AkvaConnState.selecting) {
      return;
    }
    // Claim the scanning state synchronously (before the first await) so a
    // rapid second call is reliably rejected by the guard above.
    _scanningAll = false;
    _set(AkvaConnState.scanning);

    final err = await _preflight();
    if (err != null) {
      _set(AkvaConnState.error, error: err);
      return;
    }

    BleDevice? best;

    await _scanSub?.cancel();
    _scanSub = UniversalBle.scanStream.listen((d) {
      final name = d.name ?? '';
      final advertisesEss = d.services
          .map((s) => s.toLowerCase())
          .any((s) => s.contains('181a'));
      if (name.startsWith(AkvaUuids.namePrefix) || advertisesEss) {
        // Keep the strongest signal seen so far.
        if (best == null || (d.rssi ?? -999) > (best!.rssi ?? -999)) {
          best = d;
        }
      }
    });

    try {
      // Filters on BOTH the "AkvaLink-" name prefix and the Environmental
      // Sensing Service UUID. Native scan filters can be stricter than the
      // Dart-side OR check above (e.g. Android ANDs multiple ScanFilter
      // fields together), so a real device that only advertises one of the
      // two in a given packet can be missed here even though it would pass
      // the app-level check. That's exactly what the unfiltered fallback
      // scan below (triggered on zero matches) is for.
      await UniversalBle.startScan(
        scanFilter: ScanFilter(
          withServices: [AkvaUuids.essService],
          withNamePrefix: [AkvaUuids.namePrefix],
        ),
        // On Android, request LOW_LATENCY so a fast advertiser (the sensor
        // beacons ~every 200 ms) is found quickly. Same tuning proven in the
        // u-connectXplorer app. Ignored on other platforms.
        platformConfig: PlatformConfig(
          android: AndroidOptions(scanMode: AndroidScanMode.lowLatency),
        ),
      );
    } catch (e) {
      await _stopScan();
      _set(AkvaConnState.error, error: 'Scan failed: $e');
      return;
    }

    // Give it a few seconds to find the strongest advertiser, then connect.
    _scanTimeout = Timer(_scanSettle, () async {
      await _stopScan();
      final target = best;
      if (target == null) {
        await _scanAllFallback();
        return;
      }
      await _connect(target.deviceId, target.name ?? AkvaUuids.namePrefix);
    });
  }

  /// Nothing matched the name/service filter above \u2014 broaden to an
  /// unfiltered scan and let the user pick from every nearby BLE device.
  Future<void> _scanAllFallback() async {
    _discovered = [];
    _scanningAll = true;
    _set(AkvaConnState.scanning);
    final seen = <String, BleDevice>{};

    await _scanSub?.cancel();
    _scanSub = UniversalBle.scanStream.listen((d) {
      seen[d.deviceId] = d;
      _discovered = seen.values.toList()
        ..sort((a, b) => (b.rssi ?? -999).compareTo(a.rssi ?? -999));
      notifyListeners();
    });

    try {
      await UniversalBle.startScan();
    } catch (e) {
      await _stopScan();
      _set(AkvaConnState.error, error: 'Scan failed: $e');
      return;
    }

    _scanTimeout = Timer(_scanSettle, () async {
      await _stopScan();
      if (_discovered.isEmpty) {
        _set(AkvaConnState.error, error: _s.noDeviceFound);
      } else {
        _set(AkvaConnState.selecting);
      }
    });
  }

  /// Connect to a device the user picked from [discoveredDevices].
  Future<void> connectToDiscovered(BleDevice device) async {
    await _stopScan();
    await _connect(device.deviceId, device.name ?? AkvaUuids.namePrefix);
  }

  /// Abandon device selection and go back to idle.
  Future<void> cancelSelecting() async {
    await _stopScan();
    _discovered = [];
    _set(AkvaConnState.idle);
  }

  Future<void> _stopScan() async {
    _scanTimeout?.cancel();
    _scanTimeout = null;
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
  }

  Future<void> _connect(String id, String name) async {
    _deviceId = id;
    _deviceName = name;
    _set(AkvaConnState.connecting);

    await _connSub?.cancel();
    _connSub = UniversalBle.connectionStream(id).listen((connected) {
      if (!connected && _state == AkvaConnState.connected) {
        _onDisconnected();
      }
    });

    try {
      await UniversalBle.connect(id);
      // Opportunistically raise the MTU (best-effort; OS may override).
      try {
        await UniversalBle.requestMtu(id, 247);
      } catch (_) {}
      // withDescriptors: true is required on Windows — the WinRT GATT stack
      // only populates its internal characteristic cache when descriptors are
      // also discovered; without it, subscribeNotifications throws serviceNotFound
      // (ATT error 0x13) because the characteristic handles are unknown.
      await UniversalBle.discoverServices(id, withDescriptors: true);
      await _subscribeTemperature(id);
      await _readDeviceInfo(id);
      _set(AkvaConnState.connected);
    } catch (e) {
      _set(AkvaConnState.error, error: 'Connect failed: $e');
    }
  }

  Future<void> _subscribeTemperature(String id) async {
    await _tempSub?.cancel();
    _tempSub = UniversalBle.characteristicValueStream(
      id,
      AkvaUuids.tempChar,
    ).listen(_onTemperature);

    // Try NOTIFY subscription first; fall back to polling if the platform
    // (notably Windows) rejects the subscription (e.g. serviceNotFound on
    // WinRT when the CCCD write is rejected or the cache is stale).
    var subscribed = false;
    try {
      await UniversalBle.subscribeNotifications(
        id,
        AkvaUuids.essService,
        AkvaUuids.tempChar,
      );
      subscribed = true;
    } catch (e) {
      // Subscription failed — fall through to poll mode below.
      debugPrint('BLE notify unavailable ($e), falling back to polling');
    }

    // Prime with an initial read regardless of subscription success.
    try {
      final v = await UniversalBle.read(
        id,
        AkvaUuids.essService,
        AkvaUuids.tempChar,
      );
      _onTemperature(v);
    } catch (_) {}

    // Poll mode: if subscription failed, read every 5 s until disconnected.
    if (!subscribed) {
      _startPolling(id);
    }
  }

  Timer? _pollTimer;

  void _startPolling(String id) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!isConnected) {
        _pollTimer?.cancel();
        return;
      }
      try {
        final v = await UniversalBle.read(
          id,
          AkvaUuids.essService,
          AkvaUuids.tempChar,
        );
        _onTemperature(v);
      } catch (_) {}
    });
  }

  void _onTemperature(Uint8List value) {
    if (value.length < 2) return;
    // sint16, little-endian, 0.01 °C.
    final raw = value[0] | (value[1] << 8);
    final signed = raw >= 0x8000 ? raw - 0x10000 : raw;
    _temperatureC = signed / 100.0;
    _lastUpdate = DateTime.now();
    notifyListeners();
  }

  Future<void> _readDeviceInfo(String id) async {
    try {
      final fw = await UniversalBle.read(
        id,
        AkvaUuids.disService,
        AkvaUuids.fwChar,
      );
      _firmware = String.fromCharCodes(fw).trim();
    } catch (_) {}
    try {
      final bat = await UniversalBle.read(
        id,
        AkvaUuids.basService,
        AkvaUuids.batteryChar,
      );
      if (bat.isNotEmpty) _batteryPercent = bat[0];
    } catch (_) {}
    notifyListeners();
  }

  void _onDisconnected() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _temperatureC = null;
    _batteryPercent = null;
    _set(AkvaConnState.idle);
  }

  Future<void> disconnect() async {
    final id = _deviceId;
    _pollTimer?.cancel();
    _pollTimer = null;
    await _stopScan();
    await _tempSub?.cancel();
    _tempSub = null;
    await _connSub?.cancel();
    _connSub = null;
    if (id != null) {
      try {
        await UniversalBle.disconnect(id);
      } catch (_) {}
    }
    _onDisconnected();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _stopScan();
    _tempSub?.cancel();
    _connSub?.cancel();
    super.dispose();
  }
}
