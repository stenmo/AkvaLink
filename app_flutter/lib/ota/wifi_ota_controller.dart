// SPDX-License-Identifier: Apache-2.0
//
// WifiOtaController — drives a firmware update over plain HTTP to a
// `--station` AkvaLink found via mDNS (net/station_discovery.dart). Mirrors
// ota/ota_controller.dart's GitHub-fetch-latest flow, but uploads the raw
// image with a streamed POST instead of BLE GATT writes.
//
// Protocol (mirrors main/web_page.cpp's ota_post handler):
//   POST http://<ip>/ota, Content-Type: application/octet-stream,
//   raw firmware bytes as the body. 200 on success, device reboots itself.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../strings.dart';
import 'ota_controller.dart' show OtaPhase;

class WifiOtaController extends ChangeNotifier {
  WifiOtaController({
    http.Client? httpClient,
    String repo = 'stenmo/AkvaLink',
    Strings strings = Strings.en,
  }) : _client = httpClient ?? http.Client(),
       _repo = repo,
       _s = strings;

  final http.Client _client;
  final String _repo;
  final Strings _s;

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

  void _set(OtaPhase p, String msg, {double? progress}) {
    _phase = p;
    _message = msg;
    if (progress != null) _progress = progress;
    notifyListeners();
  }

  /// Query the newest release tag so the UI can label the button.
  Future<void> refreshLatestTag() async {
    try {
      final r = await _client.get(
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

  /// Fetch the app-partition OTA image for the `station` variant — the only
  /// variant the app's mDNS discovery targets (see station_discovery.dart).
  Future<Uint8List> _fetchLatestAsset() async {
    final r = await _client.get(
      Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json'},
    );
    if (r.statusCode != 200) {
      throw Exception('GitHub API ${r.statusCode}');
    }
    final json = jsonDecode(r.body) as Map<String, dynamic>;
    _latestTag = json['tag_name'] as String?;
    final assets = (json['assets'] as List).cast<Map<String, dynamic>>();
    final re = RegExp(r'akvalink-station-app-v.*\.bin$');
    final match = assets.firstWhere(
      (a) => re.hasMatch(a['name'] as String),
      orElse: () => throw Exception('No OTA asset for variant "station"'),
    );
    final url = match['browser_download_url'] as String;
    final img = await _client.get(Uri.parse(url));
    if (img.statusCode != 200) {
      throw Exception('Download failed (HTTP ${img.statusCode})');
    }
    return img.bodyBytes;
  }

  /// Fetch the newest release image and POST it to the device at [ip].
  Future<void> flashLatestOverWifi({required String ip}) async {
    if (isBusy) return;
    _progress = 0;
    _throughputKbps = null;
    try {
      _set(OtaPhase.fetching, _s.otaFetchingFor('station'));
      final bytes = await _fetchLatestAsset();
      await _upload(ip, bytes);
    } catch (e) {
      _set(OtaPhase.failed, '${_s.otaFailedPrefix}: $e');
    }
  }

  Future<void> _upload(String ip, Uint8List bytes) async {
    _set(OtaPhase.uploading, _s.otaUploading(0), progress: 0);
    final request = http.StreamedRequest('POST', Uri.parse('http://$ip/ota'))
      ..headers['Content-Type'] = 'application/octet-stream'
      ..contentLength = bytes.length;

    final started = DateTime.now();
    final feed = _feedBody(request, bytes, started);
    final responseFuture = _client.send(request);
    await feed;
    final streamed = await responseFuture;
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) {
      throw Exception(
        'HTTP ${streamed.statusCode}${body.isNotEmpty ? ": $body" : ""}',
      );
    }
    _set(OtaPhase.done, _s.otaDone, progress: 1);
  }

  Future<void> _feedBody(
    http.StreamedRequest request,
    Uint8List bytes,
    DateTime started,
  ) async {
    const chunkSize = 4096;
    final total = bytes.length;
    for (var off = 0; off < total; off += chunkSize) {
      final end = (off + chunkSize < total) ? off + chunkSize : total;
      request.sink.add(Uint8List.sublistView(bytes, off, end));
      final elapsedMs = DateTime.now().difference(started).inMilliseconds;
      _throughputKbps = elapsedMs > 0
          ? (end / 1024) / (elapsedMs / 1000)
          : null;
      _set(
        OtaPhase.uploading,
        _s.otaUploading((100 * end / total).round()),
        progress: end / total,
      );
      // Yield so each chunk actually flushes instead of piling up in one
      // synchronous loop.
      await Future<void>.delayed(Duration.zero);
    }
    await request.sink.close();
  }

  void reset() {
    if (isBusy) return;
    _set(OtaPhase.idle, '', progress: 0);
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}
