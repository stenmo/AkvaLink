// SPDX-License-Identifier: Apache-2.0
//
// ProvController tests — scanning/connect, Security0 session handshake,
// Wi-Fi scan polling and provisioning success/failure paths, driven by a
// scripted FakeBlePlatform that returns a different (hand-crafted, wire
// format verified in prov_proto_test.dart) response bytes on each successive
// read of a characteristic — mirroring the real write-then-read protocol.

import 'dart:typed_data';

import 'package:akvalink/ble/prov_controller.dart';
import 'package:akvalink/ble/prov_proto.dart';
import 'package:akvalink/ble/prov_uuids.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'fakes/fake_ble_platform.dart';

/// A [FakeBlePlatform] that serves a scripted sequence of read responses per
/// characteristic — each successive read pops the next entry (staying on
/// the last one once exhausted), matching the request/response ping-pong the
/// real device does over a single write-then-read characteristic.
class ScriptedFakePlatform extends FakeBlePlatform {
  final Map<String, List<Uint8List>> _script = {};
  final Map<String, int> _readIndex = {};

  void script(String characteristic, List<Uint8List> responses) {
    _script[BleUuidParser.string(characteristic)] = responses;
  }

  @override
  Future<Uint8List> readValue(
    String deviceId,
    String service,
    String characteristic, {
    Duration? timeout,
  }) async {
    final key = BleUuidParser.string(characteristic);
    final list = _script[key];
    if (list == null) {
      return super.readValue(
        deviceId,
        service,
        characteristic,
        timeout: timeout,
      );
    }
    final idx = _readIndex[key] ?? 0;
    final value = list[idx < list.length ? idx : list.length - 1];
    _readIndex[key] = idx + 1;
    return value;
  }
}

// ---- Hand-crafted device-side response bytes (independent of prov_proto's
// own encoders, mirroring the manual construction in prov_proto_test.dart) --

List<int> _varint(int value) {
  final out = <int>[];
  var v = value;
  for (var i = 0; i < 10; i++) {
    final b = v & 0x7F;
    v = v >>> 7;
    if (v == 0) {
      out.add(b);
      return out;
    }
    out.add(b | 0x80);
  }
  return out;
}

Uint8List _sessionResp(ProvStatus status) {
  final sr = [0x08, ...(_varint(status.index))];
  final sec0 = [0x08, 0x01, 0xAA, 0x01, sr.length, ...sr];
  return Uint8List.fromList([0x10, 0x00, 0x52, sec0.length, ...sec0]);
}

Uint8List _scanStatusResp({required bool finished, required int count}) {
  final inner = [0x08, finished ? 1 : 0, 0x10, ..._varint(count)];
  return Uint8List.fromList([0x08, 0x03, 0x6A, inner.length, ...inner]);
}

Uint8List _scanResultResp(
  List<({String ssid, int channel, int rssi, int auth})> nets,
) {
  final entries = <int>[];
  for (final n in nets) {
    final ssidBytes = n.ssid.codeUnits;
    final entry = [
      0x0A,
      ssidBytes.length,
      ...ssidBytes,
      0x10,
      ...(_varint(n.channel)),
      0x18,
      ..._varint(n.rssi),
      0x28,
      ..._varint(n.auth),
    ];
    entries.addAll([0x0A, entry.length, ...entry]);
  }
  return Uint8List.fromList([0x08, 0x05, 0x7A, entries.length, ...entries]);
}

Uint8List _simpleStatusResp(int msg, int replyField, ProvStatus status) {
  final inner = [0x08, ..._varint(status.index)];
  final tag = (replyField << 3) | 2;
  return Uint8List.fromList([
    0x08,
    msg,
    ..._varint(tag),
    inner.length,
    ...inner,
  ]);
}

Uint8List _getStatusResp({
  required ProvStaState staState,
  String? ip,
  bool authFailed = false,
  bool networkNotFound = false,
}) {
  final inner = <int>[0x08, 0x00, 0x10, staState.index];
  if (ip != null) {
    final ipBytes = ip.codeUnits;
    final connected = [0x0A, ipBytes.length, ...ipBytes];
    inner.addAll([0x5A, connected.length, ...connected]);
  } else if (authFailed || networkNotFound) {
    inner.addAll([0x50, authFailed ? 0 : 1]);
  }
  return Uint8List.fromList([0x08, 0x01, 0x5A, inner.length, ...inner]);
}

void main() {
  late ScriptedFakePlatform fake;

  ProvController newController() => ProvController(
    scanSettle: const Duration(milliseconds: 20),
    pollInterval: const Duration(milliseconds: 5),
    scanTimeout: const Duration(seconds: 2),
    provisionTimeout: const Duration(seconds: 2),
  );

  setUp(() {
    fake = ScriptedFakePlatform();
    UniversalBle.setInstance(fake);
  });

  void seedDevice(String id) {
    fake.scanResults = [
      fakeDevice(id: id, name: 'AkvaLink', services: [ProvUuids.service]),
    ];
    fake.script(ProvUuids.sessionChar, [_sessionResp(ProvStatus.success)]);
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 100));

  group('scan + connect + session', () {
    test('finds the provisioning service and opens a session', () async {
      seedDevice('dev-1');
      final c = newController();
      await c.scanAndConnect();
      await settle();
      expect(c.state, ProvConnState.ready);
      expect(c.deviceId, 'dev-1');
      c.dispose();
    });

    test('no device found → error', () async {
      fake.scanResults = [];
      final c = newController();
      await c.scanAndConnect();
      await settle();
      expect(c.state, ProvConnState.error);
      expect(c.error, contains('No AkvaLink'));
      c.dispose();
    });

    test('session handshake failure surfaces as error', () async {
      fake.scanResults = [
        fakeDevice(
          id: 'dev-1',
          name: 'AkvaLink',
          services: [ProvUuids.service],
        ),
      ];
      fake.script(ProvUuids.sessionChar, [
        _sessionResp(ProvStatus.invalidSecScheme),
      ]);
      final c = newController();
      await c.scanAndConnect();
      await settle();
      expect(c.state, ProvConnState.error);
      expect(c.error, contains('Session handshake failed'));
      c.dispose();
    });
  });

  group('wifi scan', () {
    test('polls status until finished then fetches results', () async {
      seedDevice('dev-1');
      fake.script(ProvUuids.scanChar, [
        Uint8List(0), // response to CmdScanStart (ignored by controller)
        _scanStatusResp(finished: false, count: 0),
        _scanStatusResp(finished: true, count: 2),
        _scanResultResp([
          (ssid: 'HomeNet', channel: 6, rssi: -55, auth: 3),
          (ssid: 'OpenGuest', channel: 11, rssi: -70, auth: 0),
        ]),
      ]);
      final c = newController();
      await c.scanAndConnect();
      await settle();
      await c.scanWifiNetworks();
      await settle();

      expect(c.state, ProvConnState.ready);
      expect(c.networks, hasLength(2));
      expect(c.networks[0].ssid, 'HomeNet');
      expect(c.networks[0].secure, isTrue);
      expect(c.networks[1].ssid, 'OpenGuest');
      expect(c.networks[1].secure, isFalse);
      c.dispose();
    });

    test('scan timeout surfaces as error', () async {
      seedDevice('dev-1');
      fake.script(ProvUuids.scanChar, [
        Uint8List(0),
        _scanStatusResp(finished: false, count: 0),
      ]);
      final c = newController(); // 2 s scan timeout, 5 ms poll interval
      await c.scanAndConnect();
      await settle();
      await c.scanWifiNetworks();
      // Wait past the 2 s scan timeout.
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      expect(c.state, ProvConnState.error);
      expect(c.error, contains('timed out'));
      c.dispose();
    });
  });

  group('provisioning', () {
    test('set config + apply + poll to connected', () async {
      seedDevice('dev-1');
      fake.script(ProvUuids.configChar, [
        _simpleStatusResp(3, 13, ProvStatus.success), // RespSetConfig
        _simpleStatusResp(5, 15, ProvStatus.success), // RespApplyConfig
        _getStatusResp(staState: ProvStaState.connecting),
        _getStatusResp(staState: ProvStaState.connected, ip: '192.168.1.50'),
      ]);
      final c = newController();
      await c.scanAndConnect();
      await settle();
      await c.provision('HomeNet', 'hunter2');
      await settle();

      expect(c.state, ProvConnState.connectedToWifi);
      expect(c.connectedIp, '192.168.1.50');
      c.dispose();
    });

    test('wrong password → auth failed error', () async {
      seedDevice('dev-1');
      fake.script(ProvUuids.configChar, [
        _simpleStatusResp(3, 13, ProvStatus.success),
        _simpleStatusResp(5, 15, ProvStatus.success),
        _getStatusResp(
          staState: ProvStaState.connectionFailed,
          authFailed: true,
        ),
      ]);
      final c = newController();
      await c.scanAndConnect();
      await settle();
      await c.provision('HomeNet', 'wrongpass');
      await settle();

      expect(c.state, ProvConnState.error);
      expect(c.error, contains('wrong Wi-Fi password'));
      c.dispose();
    });

    test('device rejects credentials outright', () async {
      seedDevice('dev-1');
      fake.script(ProvUuids.configChar, [
        _simpleStatusResp(3, 13, ProvStatus.invalidArgument),
      ]);
      final c = newController();
      await c.scanAndConnect();
      await settle();
      await c.provision('', 'x');
      await settle();

      expect(c.state, ProvConnState.error);
      expect(c.error, contains('rejected credentials'));
      c.dispose();
    });
  });

  group('lifecycle', () {
    test('disconnect() returns to idle', () async {
      seedDevice('dev-1');
      final c = newController();
      await c.scanAndConnect();
      await settle();
      await c.disconnect();
      expect(c.state, ProvConnState.idle);
      expect(c.deviceId, isNull);
      c.dispose();
    });
  });
}
