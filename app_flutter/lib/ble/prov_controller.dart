// SPDX-License-Identifier: Apache-2.0
//
// ProvController — drives Espressif's "Unified Provisioning" BLE flow so the
// app can set up a fresh, unprovisioned `--station` AkvaLink without the
// separate "ESP BLE Provisioning" app. See docs/CONNECTIVITY.md for the full
// protocol write-up and prov_uuids.dart for where the UUIDs come from.
//
// Flow: scan for the provisioning service → connect → open a (plaintext,
// Security0) session on `prov-session` → scan Wi-Fi on `prov-scan` → send
// SSID/password + apply on `prov-config` → poll `prov-config` for the
// resulting connection state.
//
// Every exchange is the same shape: write a serialized request to a
// characteristic, then read that same characteristic back to get the
// device's response — `protocomm`'s BLE transport has no notify path for
// this by default, so there's no separate response channel to subscribe to.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import 'prov_proto.dart';
import 'prov_uuids.dart';

enum ProvConnState {
  idle,
  scanning,
  connecting,
  sessionEstablishing,
  ready,
  wifiScanning,
  settingConfig,
  waitingResult,
  connectedToWifi,
  error,
}

class ProvController extends ChangeNotifier {
  ProvController({
    Duration scanSettle = const Duration(seconds: 4),
    Duration pollInterval = const Duration(milliseconds: 700),
    Duration scanTimeout = const Duration(seconds: 15),
    Duration provisionTimeout = const Duration(seconds: 20),
  }) : _scanSettle = scanSettle,
       _pollInterval = pollInterval,
       _scanTimeout = scanTimeout,
       _provisionTimeout = provisionTimeout;

  final Duration _scanSettle;
  final Duration _pollInterval;
  final Duration _scanTimeout;
  final Duration _provisionTimeout;

  ProvConnState _state = ProvConnState.idle;
  ProvConnState get state => _state;

  String? _error;
  String? get error => _error;

  String? _deviceId;
  String? get deviceId => _deviceId;

  List<WifiScanEntry> _networks = [];
  List<WifiScanEntry> get networks => List.unmodifiable(_networks);

  String? _connectedIp;
  String? get connectedIp => _connectedIp;

  bool get isBusy =>
      _state != ProvConnState.idle &&
      _state != ProvConnState.ready &&
      _state != ProvConnState.connectedToWifi &&
      _state != ProvConnState.error;

  StreamSubscription<BleDevice>? _scanSub;
  StreamSubscription<bool>? _connSub;
  Timer? _scanTimer;

  void _set(ProvConnState s, {String? error}) {
    _state = s;
    _error = error;
    notifyListeners();
  }

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

  /// Scan for an AkvaLink currently in BLE setup mode (unprovisioned) and
  /// connect + open a Security0 session.
  Future<void> scanAndConnect() async {
    if (_state == ProvConnState.scanning ||
        _state == ProvConnState.connecting) {
      return;
    }
    _set(ProvConnState.scanning);

    final preflightErr = await _preflight();
    if (preflightErr != null) {
      _set(ProvConnState.error, error: preflightErr);
      return;
    }

    BleDevice? best;
    await _scanSub?.cancel();
    _scanSub = UniversalBle.scanStream.listen((d) {
      final name = d.name ?? '';
      final advertisesProv = d.services
          .map((s) => s.toLowerCase())
          .any((s) => s.contains(ProvUuids.service));
      if (name.startsWith('AkvaLink') || advertisesProv) {
        if (best == null || (d.rssi ?? -999) > (best!.rssi ?? -999)) {
          best = d;
        }
      }
    });

    try {
      await UniversalBle.startScan(
        scanFilter: ScanFilter(withServices: [ProvUuids.service]),
      );
    } catch (e) {
      await _stopScan();
      _set(ProvConnState.error, error: 'Scan failed: $e');
      return;
    }

    _scanTimer = Timer(_scanSettle, () async {
      await _stopScan();
      final target = best;
      if (target == null) {
        _set(
          ProvConnState.error,
          error: 'No AkvaLink in setup mode found nearby',
        );
        return;
      }
      await _connect(target.deviceId);
    });
  }

  Future<void> _stopScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    await _scanSub?.cancel();
    _scanSub = null;
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
  }

  Future<void> _connect(String id) async {
    _deviceId = id;
    _set(ProvConnState.connecting);

    await _connSub?.cancel();
    _connSub = UniversalBle.connectionStream(id).listen((connected) {
      // Once we've reached success, the firmware itself tears down BLE
      // (wifi_prov_mgr_stop_provisioning() after a successful join) — that
      // expected disconnect must not overwrite an already-successful state.
      if (!connected &&
          _state != ProvConnState.idle &&
          _state != ProvConnState.connectedToWifi &&
          _state != ProvConnState.error) {
        _set(ProvConnState.error, error: 'Device disconnected');
      }
    });

    try {
      await UniversalBle.connect(id);
      try {
        await UniversalBle.requestMtu(id, 247);
      } catch (_) {}
      // withDescriptors: true — required on Windows/WinRT, see
      // akvalink_controller.dart for the same fix.
      await UniversalBle.discoverServices(id, withDescriptors: true);

      _set(ProvConnState.sessionEstablishing);
      final resp = await _exchange(
        ProvUuids.sessionChar,
        buildSec0SessionCmd(),
      );
      final status = parseSec0SessionResp(resp);
      if (status != ProvStatus.success) {
        throw Exception('Session handshake failed: $status');
      }
      _set(ProvConnState.ready);
    } catch (e) {
      _set(ProvConnState.error, error: 'Connect failed: $e');
    }
  }

  /// Write [request] to [characteristic], then read the same characteristic
  /// back for the response — see the file doc comment above.
  Future<Uint8List> _exchange(String characteristic, Uint8List request) async {
    final id = _deviceId;
    if (id == null) throw StateError('Not connected');
    await UniversalBle.write(id, ProvUuids.service, characteristic, request);
    return UniversalBle.read(id, ProvUuids.service, characteristic);
  }

  /// Kick off a Wi-Fi scan on the device and collect the results into
  /// [networks].
  Future<void> scanWifiNetworks() async {
    if (_deviceId == null) return;
    _networks = [];
    _set(ProvConnState.wifiScanning);
    try {
      await _exchange(ProvUuids.scanChar, buildScanStart());

      final deadline = DateTime.now().add(_scanTimeout);
      ScanStatus status;
      do {
        await Future.delayed(_pollInterval);
        if (DateTime.now().isAfter(deadline)) {
          throw Exception('Wi-Fi scan timed out');
        }
        final resp = await _exchange(ProvUuids.scanChar, buildScanStatus());
        status = parseScanStatus(resp);
      } while (!status.finished);

      final resultResp = await _exchange(
        ProvUuids.scanChar,
        buildScanResult(0, status.resultCount),
      );
      // Mesh/repeater APs broadcast the same SSID from multiple BSSIDs —
      // collapse to one entry per SSID, keeping the strongest signal.
      final bestBySsid = <String, WifiScanEntry>{};
      for (final entry in parseScanResult(resultResp)) {
        final existing = bestBySsid[entry.ssid];
        if (existing == null || entry.rssi > existing.rssi) {
          bestBySsid[entry.ssid] = entry;
        }
      }
      _networks = bestBySsid.values.toList()
        ..sort((a, b) => b.rssi.compareTo(a.rssi));
      _set(ProvConnState.ready);
    } catch (e) {
      _set(ProvConnState.error, error: 'Wi-Fi scan failed: $e');
    }
  }

  /// Send Wi-Fi credentials, apply them, and wait for the device to report
  /// it joined (or failed to join) the network.
  Future<void> provision(String ssid, String password) async {
    if (_deviceId == null) return;
    _set(ProvConnState.settingConfig);
    try {
      final setResp = await _exchange(
        ProvUuids.configChar,
        buildSetConfig(ssid, password),
      );
      final setStatus = parseSetConfigStatus(setResp);
      if (setStatus != ProvStatus.success) {
        throw Exception('Device rejected credentials: $setStatus');
      }

      await _exchange(ProvUuids.configChar, buildApplyConfig());

      _set(ProvConnState.waitingResult);
      final deadline = DateTime.now().add(_provisionTimeout);
      while (true) {
        await Future.delayed(_pollInterval);
        final resp = await _exchange(ProvUuids.configChar, buildGetStatus());
        final result = parseGetStatus(resp);
        if (result.staState == ProvStaState.connected) {
          _connectedIp = result.ip4Addr;
          _set(ProvConnState.connectedToWifi);
          return;
        }
        if (result.staState == ProvStaState.connectionFailed) {
          final reason = result.authFailed
              ? 'wrong Wi-Fi password'
              : result.networkNotFound
              ? 'network not found'
              : 'connection failed';
          throw Exception(reason);
        }
        if (DateTime.now().isAfter(deadline)) {
          throw Exception('Timed out waiting to join Wi-Fi');
        }
      }
    } catch (e) {
      _set(ProvConnState.error, error: '$e');
    }
  }

  Future<void> disconnect() async {
    final id = _deviceId;
    await _stopScan();
    await _connSub?.cancel();
    _connSub = null;
    if (id != null) {
      try {
        await UniversalBle.disconnect(id);
      } catch (_) {}
    }
    _deviceId = null;
    _networks = [];
    _connectedIp = null;
    _set(ProvConnState.idle);
  }

  @override
  void dispose() {
    _stopScan();
    _connSub?.cancel();
    super.dispose();
  }
}
