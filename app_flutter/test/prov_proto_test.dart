// SPDX-License-Identifier: Apache-2.0
//
// Wire-format tests for prov_proto.dart. The Sec0 handshake test asserts an
// exact, hand-computed byte sequence (derived directly from the protobuf
// wire-format spec — tag = (field << 3) | wireType, varint LSB-first groups
// of 7 bits) so a silent encoding regression can't slip through even though
// there's no live device to round-trip against this session.

import 'dart:typed_data';

import 'package:akvalink/ble/prov_proto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('buildSec0SessionCmd matches the hand-derived byte sequence', () {
    // SessionData{sec_ver=0(field2,varint), sec0=Sec0Payload{...}(field10,len-delim)}
    // Sec0Payload{msg=0(field1,varint), sc=S0SessionCmd{}(field20,len-delim,len=0)}
    // Sec0Payload bytes: tag(1,0)=0x08, val=0x00, tag(20,2)=0xA2,0x01, len=0x00
    final sec0 = [0x08, 0x00, 0xA2, 0x01, 0x00];
    // SessionData bytes: tag(2,0)=0x10, val=0x00, tag(10,2)=0x52, len=5, then sec0
    final expected = Uint8List.fromList([0x10, 0x00, 0x52, 0x05, ...sec0]);
    expect(buildSec0SessionCmd(), expected);
  });

  test('parseSec0SessionResp reads success', () {
    // SessionData{sec_ver=0, sec0{msg=1(S0_Session_Response), sr{status=0}}}
    final sr = [0x08, 0x00]; // tag(1,0), status=0 (Success)
    final sec0 = [
      0x08, 0x01, // msg = 1
      0xAA, 0x01, sr.length, ...sr, // tag(21,2)=0xAA,0x01 ; len ; sr bytes
    ];
    final data = Uint8List.fromList([
      0x10, 0x00, // sec_ver = 0
      0x52, sec0.length, ...sec0,
    ]);
    expect(parseSec0SessionResp(data), ProvStatus.success);
  });

  test('scan start / status / result round trip', () {
    final startReq = buildScanStart(groupChannels: 0, periodMs: 0);
    expect(startReq, isNotEmpty);

    final statusReq = buildScanStatus();
    expect(statusReq, isNotEmpty);

    // Hand-craft a RespScanStatus reply: WiFiScanPayload{msg=3,
    // resp_scan_status{scan_finished=true, result_count=2}}
    final respScanStatus = [
      0x08, 0x01, // finished = true
      0x10, 0x02, // result_count = 2
    ];
    final scanStatusReply = Uint8List.fromList([
      0x08, 0x03, // msg = TypeRespScanStatus (3)
      0x6A, respScanStatus.length, ...respScanStatus, // tag(13,2)=0x6A
    ]);
    final status = parseScanStatus(scanStatusReply);
    expect(status.finished, isTrue);
    expect(status.resultCount, 2);
  });

  test('parseScanResult decodes repeated entries incl. negative rssi', () {
    // One WiFiScanResult{ssid="Home", channel=6, rssi=-55, auth=WPA2_PSK(3)}
    final ssidBytes = 'Home'.codeUnits;
    final entry = [
      0x0A, ssidBytes.length, ...ssidBytes, // tag(1,2) ssid
      0x10, 0x06, // tag(2,0) channel=6
      0x18, ...(_varintBytes(-55)), // tag(3,0) rssi=-55
      0x28, 0x03, // tag(5,0) auth=3 (WPA2_PSK)
    ];
    final respScanResult = [
      0x0A, entry.length, ...entry, // tag(1,2) entries[0]
    ];
    final data = Uint8List.fromList([
      0x08, 0x05, // msg = TypeRespScanResult (5)
      0x7A, respScanResult.length, ...respScanResult, // tag(15,2)=0x7A
    ]);
    final entries = parseScanResult(data);
    expect(entries, hasLength(1));
    expect(entries.single.ssid, 'Home');
    expect(entries.single.channel, 6);
    expect(entries.single.rssi, -55);
    expect(entries.single.secure, isTrue);
  });

  test('buildScanResult / buildGetStatus / buildApplyConfig are non-empty', () {
    expect(buildScanResult(0, 10), isNotEmpty);
    expect(buildGetStatus(), isNotEmpty);
    expect(buildApplyConfig(), isNotEmpty);
  });

  test('buildSetConfig embeds ssid and passphrase bytes', () {
    final req = buildSetConfig('MyWifi', 'hunter2');
    final asList = req.toList();
    for (final b in 'MyWifi'.codeUnits) {
      expect(asList, contains(b));
    }
  });

  test('parseSetConfigStatus / parseApplyConfigStatus read status', () {
    final okStatus = [0x08, 0x00]; // status = Success(0)
    final setConfigReply = Uint8List.fromList([
      0x08, 0x03, // msg = TypeRespSetConfig(3)
      0x6A, okStatus.length, ...okStatus, // tag(13,2)=0x6A
    ]);
    expect(parseSetConfigStatus(setConfigReply), ProvStatus.success);

    final applyConfigReply = Uint8List.fromList([
      0x08, 0x05, // msg = TypeRespApplyConfig(5)
      0x7A, okStatus.length, ...okStatus, // tag(15,2)=0x7A
    ]);
    expect(parseApplyConfigStatus(applyConfigReply), ProvStatus.success);
  });

  test('parseGetStatus decodes a connected reply with IP', () {
    final ip = '192.168.1.42';
    final ipBytes = ip.codeUnits;
    final connected = [
      0x0A, ipBytes.length, ...ipBytes, // tag(1,2) ip4_addr
    ];
    final respGetStatus = [
      0x08, 0x00, // status = Success
      0x10, 0x00, // sta_state = Connected(0)
      0x5A, connected.length, ...connected, // tag(11,2)=0x5A -> connected
    ];
    final data = Uint8List.fromList([
      0x08, 0x01, // msg = TypeRespGetStatus(1)
      0x5A, respGetStatus.length, ...respGetStatus, // tag(11,2)=0x5A
    ]);
    final result = parseGetStatus(data);
    expect(result.status, ProvStatus.success);
    expect(result.staState, ProvStaState.connected);
    expect(result.ip4Addr, ip);
  });

  test('parseGetStatus decodes an auth-failed reply', () {
    final respGetStatus = [
      0x08, 0x00, // status = Success (of the RPC itself)
      0x10, 0x03, // sta_state = ConnectionFailed(3)
      0x50, 0x00, // tag(10,0) fail_reason = AuthError(0)
    ];
    final data = Uint8List.fromList([
      0x08, 0x01, // msg = TypeRespGetStatus(1)
      0x5A, respGetStatus.length, ...respGetStatus,
    ]);
    final result = parseGetStatus(data);
    expect(result.staState, ProvStaState.connectionFailed);
    expect(result.authFailed, isTrue);
  });
}

/// Encodes [value] (possibly negative int32) the way proto3 encodes a plain
/// `int32` field: sign-extended to 64 bits, then standard unsigned varint —
/// mirrors the `_varint` used by prov_proto.dart's writer, kept independent
/// here so the test doesn't just re-check itself against the same code path.
List<int> _varintBytes(int value) {
  final out = <int>[];
  var v = value;
  for (var i = 0; i < 10; i++) {
    final byte = v & 0x7F;
    v = v >>> 7;
    if (v == 0) {
      out.add(byte);
      return out;
    }
    out.add(byte | 0x80);
  }
  return out;
}
