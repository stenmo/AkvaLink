// SPDX-License-Identifier: Apache-2.0
//
// OtaController — drives a BLE firmware update over the AkvaLink OTA service.
// It can flash a picked .bin OR fetch the matching variant asset from the
// latest GitHub release automatically (using the variant reported by DIS).
//
// Protocol (mirrors main/ble_gatt.cpp + web/index.html):
//   otaCtrl  write 0x01 = BEGIN | 0x02 = END | 0x03 = ABORT; notify [op,result]
//   otaData  write firmware bytes in order (MTU-safe chunks)

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:universal_ble/universal_ble.dart';

import '../ble/akvalink_uuids.dart';

enum OtaPhase { idle, fetching, connecting, erasing, uploading, done, failed }

class OtaController extends ChangeNotifier {
  static const _repo = 'stenmo/AkvaLink';

  OtaPhase _phase = OtaPhase.idle;
  OtaPhase get phase => _phase;

  double _progress = 0; // 0..1
  double get progress => _progress;

  String _message = '';
  String get message => _message;

  String? _latestTag;
  String? get latestTag => _latestTag;

  double? _throughputKbps;
  double? get throughputKbps => _throughputKbps;

  bool get isBusy =>
      _phase != OtaPhase.idle &&
      _phase != OtaPhase.done &&
      _phase != OtaPhase.failed;

  StreamSubscription<Uint8List>? _ctrlSub;
  bool _deviceError = false;

  void _set(OtaPhase p, String msg, {double? progress}) {
    _phase = p;
    _message = msg;
    if (progress != null) _progress = progress;
    notifyListeners();
  }

  /// Query the newest release tag so the UI can label the button.
  Future<void> refreshLatestTag() async {
    try {
      final r = await http.get(
        Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
        headers: {'Accept': 'application/vnd.github+json'},
      );
      if (r.statusCode == 200) {
        final json = jsonDecode(r.body) as Map<String, dynamic>;
        _latestTag = json['tag_name'] as String?;
        notifyListeners();
      }
    } catch (_) {
      /* offline / rate-limited — feature still works manually */
    }
  }

  /// Fetch the app-partition OTA image for [variant] from the latest release.
  /// Asset name convention: `akvalink-{variant}-app-v{ver}.bin`
  Future<Uint8List> _fetchLatestAsset(String variant) async {
    final r = await http.get(
      Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json'},
    );
    if (r.statusCode != 200) {
      throw Exception('GitHub API ${r.statusCode}');
    }
    final json = jsonDecode(r.body) as Map<String, dynamic>;
    _latestTag = json['tag_name'] as String?;
    final assets = (json['assets'] as List).cast<Map<String, dynamic>>();
    // Match "akvalink-<variant>-app-v...bin" (the OTA/app image, not the
    // merged 0x0 esptool image, and not a .sha256 sidecar).
    final re = RegExp('akvalink-$variant-app-v.*\\.bin\$');
    final match = assets.firstWhere(
      (a) => re.hasMatch(a['name'] as String),
      orElse: () => throw Exception('No OTA asset for variant "$variant"'),
    );
    final url = match['browser_download_url'] as String;
    final img = await http.get(Uri.parse(url));
    if (img.statusCode != 200) {
      throw Exception('Download failed (HTTP ${img.statusCode})');
    }
    return img.bodyBytes;
  }

  /// Flash the newest release image matching the device's own variant.
  Future<void> flashLatest({
    required String deviceId,
    required String variant,
  }) async {
    await _run(deviceId, () async {
      _set(OtaPhase.fetching, 'Fetching latest $variant firmware…');
      return _fetchLatestAsset(variant);
    });
  }

  /// Flash a locally-picked image.
  Future<void> flashBytes({
    required String deviceId,
    required Uint8List bytes,
  }) async {
    await _run(deviceId, () async => bytes);
  }

  Future<void> _run(
    String deviceId,
    Future<Uint8List> Function() getBytes,
  ) async {
    if (isBusy) return;
    _deviceError = false;
    _progress = 0;
    _throughputKbps = null;
    try {
      final bytes = await getBytes(); // fetch first — don't erase on a bad DL

      _set(OtaPhase.connecting, 'Connecting…');
      // Subscribe to status notifications so a device-side error aborts us.
      await _ctrlSub?.cancel();
      _ctrlSub =
          UniversalBle.characteristicValueStream(
            deviceId,
            AkvaUuids.otaCtrl,
          ).listen((v) {
            if (v.length >= 2 && v[1] != 0) {
              _deviceError = true;
              _set(OtaPhase.failed, 'Device reported error (code ${v[1]})');
            }
          });
      try {
        await UniversalBle.subscribeNotifications(
          deviceId,
          AkvaUuids.otaService,
          AkvaUuids.otaCtrl,
        );
      } catch (_) {}

      // BEGIN — device erases the passive slot (a few seconds).
      _set(OtaPhase.erasing, 'Preparing device (erasing slot)…');
      await UniversalBle.write(
        deviceId,
        AkvaUuids.otaService,
        AkvaUuids.otaCtrl,
        Uint8List.fromList([AkvaUuids.otaBegin]),
      );
      await Future.delayed(const Duration(milliseconds: 400));
      if (_deviceError) throw Exception('device rejected BEGIN');

      // Stream in MTU-safe chunks (240 B is safe even at the 247 MTU we ask for).
      const chunk = 240;
      final t0 = DateTime.now();
      for (var off = 0; off < bytes.length; off += chunk) {
        if (_deviceError) throw Exception('aborted by device');
        final end = (off + chunk < bytes.length) ? off + chunk : bytes.length;
        await UniversalBle.write(
          deviceId,
          AkvaUuids.otaService,
          AkvaUuids.otaData,
          Uint8List.sublistView(bytes, off, end),
          withoutResponse: true,
        );
        if (off % (chunk * 16) < chunk) {
          final dt = DateTime.now().difference(t0).inMilliseconds / 1000.0;
          _throughputKbps = dt > 0 ? (off / 1024) / dt : null;
          _set(
            OtaPhase.uploading,
            'Uploading ${(100 * off / bytes.length).round()}%',
            progress: off / bytes.length,
          );
        }
      }
      _set(OtaPhase.uploading, 'Uploading 100%', progress: 1);

      // END — device finalises, sets the boot slot and reboots.
      _set(OtaPhase.uploading, 'Finalising…', progress: 1);
      await UniversalBle.write(
        deviceId,
        AkvaUuids.otaService,
        AkvaUuids.otaCtrl,
        Uint8List.fromList([AkvaUuids.otaEnd]),
      );
      _set(
        OtaPhase.done,
        'Update sent — device rebooting into new firmware ✓',
        progress: 1,
      );
    } catch (e) {
      if (_phase != OtaPhase.failed) {
        _set(OtaPhase.failed, 'Update failed: $e');
      }
      // Best-effort abort.
      try {
        await UniversalBle.write(
          deviceId,
          AkvaUuids.otaService,
          AkvaUuids.otaCtrl,
          Uint8List.fromList([AkvaUuids.otaAbort]),
        );
      } catch (_) {}
    } finally {
      await _ctrlSub?.cancel();
      _ctrlSub = null;
    }
  }

  void reset() {
    if (isBusy) return;
    _set(OtaPhase.idle, '', progress: 0);
  }

  @override
  void dispose() {
    _ctrlSub?.cancel();
    super.dispose();
  }
}
