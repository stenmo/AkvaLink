// SPDX-License-Identifier: Apache-2.0
//
// AkvaLinkController — a ChangeNotifier that owns the BLE lifecycle:
// scan → connect → subscribe temperature → read firmware/battery. The UI
// (provider) just listens; all BLE detail lives here.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import 'akvalink_uuids.dart';

enum AkvaConnState { idle, scanning, connecting, connected, error }

class AkvaLinkController extends ChangeNotifier {
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
        return 'Bluetooth not supported on this device';
      }
      if (avail == AvailabilityState.poweredOff) {
        return 'Bluetooth is turned off';
      }
      final ok = await UniversalBle.hasPermissions();
      if (!ok) await UniversalBle.requestPermissions();
      return null;
    } catch (e) {
      return 'Bluetooth unavailable: $e';
    }
  }

  /// Scan for the nearest AkvaLink and connect to it. If [deviceId] is given,
  /// connect straight to that (a previously-seen device).
  Future<void> scanAndConnect() async {
    if (_state == AkvaConnState.scanning ||
        _state == AkvaConnState.connecting) {
      return;
    }
    final err = await _preflight();
    if (err != null) {
      _set(AkvaConnState.error, error: err);
      return;
    }

    _set(AkvaConnState.scanning);
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
      await UniversalBle.startScan(
        scanFilter: ScanFilter(
          withServices: [AkvaUuids.essService],
          withNamePrefix: [AkvaUuids.namePrefix],
        ),
      );
    } catch (e) {
      await _stopScan();
      _set(AkvaConnState.error, error: 'Scan failed: $e');
      return;
    }

    // Give it a few seconds to find the strongest advertiser, then connect.
    _scanTimeout = Timer(const Duration(seconds: 4), () async {
      await _stopScan();
      final target = best;
      if (target == null) {
        _set(AkvaConnState.error, error: 'No AkvaLink found nearby');
        return;
      }
      await _connect(target.deviceId, target.name ?? AkvaUuids.namePrefix);
    });
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
      await UniversalBle.discoverServices(id);
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
    await UniversalBle.subscribeNotifications(
      id,
      AkvaUuids.essService,
      AkvaUuids.tempChar,
    );
    // Prime with an initial read so the UI isn't blank until the next notify.
    try {
      final v = await UniversalBle.read(
        id,
        AkvaUuids.essService,
        AkvaUuids.tempChar,
      );
      _onTemperature(v);
    } catch (_) {}
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
    _temperatureC = null;
    _batteryPercent = null;
    _set(AkvaConnState.idle);
  }

  Future<void> disconnect() async {
    final id = _deviceId;
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
    _stopScan();
    _tempSub?.cancel();
    _connSub?.cancel();
    super.dispose();
  }
}
