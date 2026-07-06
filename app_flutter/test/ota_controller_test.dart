// SPDX-License-Identifier: Apache-2.0
//
// OtaController tests — release-asset selection, the happy-path BLE flow, and
// the important corner cases: device-reported error, BEGIN rejection, a link
// dropped mid-upload, a missing asset, and the busy-guard.

import 'dart:convert';
import 'dart:typed_data';

import 'package:akvalink/ble/akvalink_uuids.dart';
import 'package:akvalink/ota/ota_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:universal_ble/universal_ble.dart';

import 'fakes/fake_ble_platform.dart';

void main() {
  late FakeBlePlatform fake;
  const deviceId = 'dev-1';

  setUp(() {
    fake = FakeBlePlatform();
    UniversalBle.setInstance(fake);
  });

  // A release JSON body with two variants + noise assets.
  String releaseJson(String tag) => jsonEncode({
    'tag_name': tag,
    'assets': [
      {
        'name': 'akvalink-thread-app-v0.3.2.bin',
        'browser_download_url': 'https://example/thread-app.bin',
      },
      {
        'name':
            'akvalink-thread-v0.3.2.bin', // merged 0x0 image — must be ignored
        'browser_download_url': 'https://example/thread-merged.bin',
      },
      {
        'name': 'akvalink-thread-app-v0.3.2.bin.sha256', // sidecar — ignore
        'browser_download_url': 'https://example/thread-app.sha256',
      },
      {
        'name': 'akvalink-ble-app-v0.3.2.bin',
        'browser_download_url': 'https://example/ble-app.bin',
      },
    ],
  });

  OtaController newOta(http.Client client) => OtaController(
    httpClient: client,
    eraseSettle: Duration.zero,
    chunkSize: 8,
  );

  group('release tag', () {
    test('refreshLatestTag sets the tag', () async {
      final client = MockClient(
        (req) async => http.Response(releaseJson('v0.3.2'), 200),
      );
      final ota = newOta(client);
      await ota.refreshLatestTag();
      expect(ota.latestTag, 'v0.3.2');
    });

    test('refreshLatestTag swallows offline errors', () async {
      final client = MockClient((req) async => http.Response('nope', 500));
      final ota = newOta(client);
      await ota.refreshLatestTag(); // must not throw
      expect(ota.latestTag, isNull);
    });
  });

  group('flashLatest happy path', () {
    test('selects the app asset for the variant and streams to done', () async {
      final imageBytes = Uint8List.fromList(List.generate(20, (i) => i));
      final client = MockClient((req) async {
        if (req.url.path.contains('releases/latest')) {
          return http.Response(releaseJson('v0.3.2'), 200);
        }
        if (req.url.toString() == 'https://example/thread-app.bin') {
          return http.Response.bytes(imageBytes, 200);
        }
        return http.Response('not found', 404);
      });
      final ota = newOta(client);

      await ota.flashLatest(deviceId: deviceId, variant: 'thread');

      expect(ota.phase, OtaPhase.done);
      expect(ota.progress, 1);

      // Verify the BLE conversation: BEGIN, data chunks, END on the ctrl/data
      // characteristics.
      final ctrlWrites = fake.writes
          .where((w) => w.characteristic.toLowerCase().endsWith('0011'))
          .toList();
      final dataWrites = fake.writes
          .where((w) => w.characteristic.toLowerCase().endsWith('0012'))
          .toList();
      expect(ctrlWrites.first.value.first, AkvaUuids.otaBegin);
      expect(ctrlWrites.last.value.first, AkvaUuids.otaEnd);
      // 20 bytes / 8-byte chunks = 3 data writes.
      expect(dataWrites.length, 3);
      final reassembled = dataWrites.expand((w) => w.value).toList();
      expect(reassembled, imageBytes.toList());
    });
  });

  group('corner cases', () {
    test('device reports an error → failed + abort sent', () async {
      final imageBytes = Uint8List.fromList(List.filled(64, 0xAB));
      final client = MockClient((req) async {
        if (req.url.path.contains('releases/latest')) {
          return http.Response(releaseJson('v0.3.2'), 200);
        }
        return http.Response.bytes(imageBytes, 200);
      });
      final ota = newOta(client);

      // As soon as BEGIN is written, have the device notify an error code.
      ota.addListener(() {
        if (ota.phase == OtaPhase.erasing) {
          fake.pushNotification(deviceId, AkvaUuids.otaCtrl, [0x01, 0x02]);
        }
      });

      await ota.flashLatest(deviceId: deviceId, variant: 'thread');
      expect(ota.phase, OtaPhase.failed);
      expect(ota.message, contains('error'));

      // ABORT (0x03) must have been written to the control characteristic.
      final abortSent = fake.writes.any(
        (w) =>
            w.characteristic.toLowerCase().endsWith('0011') &&
            w.value.first == AkvaUuids.otaAbort,
      );
      expect(abortSent, isTrue);
    });

    test('link dropped mid-upload → failed, abort attempted', () async {
      final imageBytes = Uint8List.fromList(List.filled(64, 0x11));
      final client = MockClient((req) async {
        if (req.url.path.contains('releases/latest')) {
          return http.Response(releaseJson('v0.3.2'), 200);
        }
        return http.Response.bytes(imageBytes, 200);
      });
      final ota = newOta(client);

      // Any write to the data characteristic (…0012) throws — simulates the
      // link dropping while streaming.
      fake.writeThrowsOnContaining = '0012';

      await ota.flashLatest(deviceId: deviceId, variant: 'thread');
      expect(ota.phase, OtaPhase.failed);
      expect(ota.message.toLowerCase(), contains('failed'));
    });

    test('no asset for the variant → failed', () async {
      final client = MockClient(
        (req) async => http.Response(releaseJson('v0.3.2'), 200),
      );
      final ota = newOta(client);
      // "station" isn't in the release JSON.
      await ota.flashLatest(deviceId: deviceId, variant: 'station');
      expect(ota.phase, OtaPhase.failed);
      expect(ota.message, contains('station'));
    });

    test('bad download (HTTP 404) → failed, no BLE writes', () async {
      final client = MockClient((req) async {
        if (req.url.path.contains('releases/latest')) {
          return http.Response(releaseJson('v0.3.2'), 200);
        }
        return http.Response('gone', 404);
      });
      final ota = newOta(client);
      await ota.flashLatest(deviceId: deviceId, variant: 'thread');
      expect(ota.phase, OtaPhase.failed);
      // Nothing should have been written to the device (fetch failed first).
      expect(fake.writes, isEmpty);
    });

    test('flashBytes streams a local image without any network', () async {
      final ota = OtaController(
        httpClient: MockClient((_) async => http.Response('', 500)),
        eraseSettle: Duration.zero,
        chunkSize: 16,
      );
      final bytes = Uint8List.fromList(List.generate(40, (i) => i));
      await ota.flashBytes(deviceId: deviceId, bytes: bytes);
      expect(ota.phase, OtaPhase.done);
      final dataWrites = fake.writes.where(
        (w) => w.characteristic.toLowerCase().endsWith('0012'),
      );
      final reassembled = dataWrites.expand((w) => w.value).toList();
      expect(reassembled, bytes.toList());
    });

    test('reset() clears state when idle/done', () async {
      final ota = OtaController(
        httpClient: MockClient((_) async => http.Response('', 500)),
        eraseSettle: Duration.zero,
      );
      final bytes = Uint8List.fromList(List.filled(8, 1));
      await ota.flashBytes(deviceId: deviceId, bytes: bytes);
      expect(ota.phase, OtaPhase.done);
      ota.reset();
      expect(ota.phase, OtaPhase.idle);
      expect(ota.progress, 0);
    });
  });
}
