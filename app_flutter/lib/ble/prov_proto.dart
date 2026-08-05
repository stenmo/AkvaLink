// SPDX-License-Identifier: Apache-2.0
//
// Minimal hand-written protobuf wire codec for the handful of tiny messages
// ESP-IDF's `protocomm`/`wifi_provisioning` components exchange over BLE
// during Wi-Fi provisioning (see docs/CONNECTIVITY.md). No protoc/codegen
// dependency: these six .proto files (session.proto, sec0.proto,
// constants.proto, wifi_scan.proto, wifi_config.proto, wifi_constants.proto
// in espressif/esp-idf v5.5) are small and effectively frozen, so a compact,
// purpose-built reader/writer is simpler than pulling in the full `protobuf`
// package plus a build-time codegen step.
//
// Only proto3 field kinds actually used here are supported: varint (bool,
// uint32, int32, enum) and length-delimited (bytes, string, embedded
// message). Field numbers below are copied verbatim from the upstream
// .proto files — see the comment above each function.
//
// NOTE: relies on Dart's native `int` being a real 64-bit two's-complement
// value (true on the Dart VM/AOT — this app doesn't target Flutter web), so
// that a negative int32 field (e.g. `rssi`), which proto3 always encodes as
// a sign-extended 10-byte varint, round-trips correctly without extra
// bit-twiddling.

import 'dart:convert';
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Low-level writer/reader
// ---------------------------------------------------------------------------

class _ProtoWriter {
  final BytesBuilder _b = BytesBuilder();

  Uint8List toBytes() => _b.toBytes();

  void _varint(int value) {
    var v = value;
    for (var i = 0; i < 10; i++) {
      final byte = v & 0x7F;
      v = v >>> 7;
      if (v == 0) {
        _b.addByte(byte);
        return;
      }
      _b.addByte(byte | 0x80);
    }
  }

  void _tag(int field, int wireType) => _varint((field << 3) | wireType);

  void varintField(int field, int value) {
    _tag(field, 0);
    _varint(value);
  }

  void boolField(int field, bool value) => varintField(field, value ? 1 : 0);

  void bytesField(int field, List<int> bytes) {
    _tag(field, 2);
    _varint(bytes.length);
    _b.add(bytes);
  }

  void stringField(int field, String s) => bytesField(field, utf8.encode(s));

  void messageField(int field, Uint8List encoded) => bytesField(field, encoded);
}

class _Field {
  _Field(this.number, this.wireType, this.value);
  final int number;
  final int wireType; // 0 = varint, 2 = length-delimited
  final int value; // for wireType 0: the varint value; for 2: unused
}

class _ProtoReader {
  _ProtoReader(this._data) : _pos = 0;
  final Uint8List _data;
  int _pos;

  bool get isAtEnd => _pos >= _data.length;

  int _readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = _data[_pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) break;
      shift += 7;
    }
    return result;
  }

  Uint8List _readLengthDelimited() {
    final len = _readVarint();
    final out = Uint8List.sublistView(_data, _pos, _pos + len);
    _pos += len;
    return out;
  }

  /// Reads one field, returning its number/wire-type plus either the
  /// decoded varint (wireType 0) or the raw length-delimited bytes stashed
  /// via [lastBytes] (wireType 2).
  Uint8List? lastBytes;

  _Field readField() {
    final tag = _readVarint();
    final number = tag >>> 3;
    final wireType = tag & 0x7;
    switch (wireType) {
      case 0:
        return _Field(number, wireType, _readVarint());
      case 2:
        lastBytes = _readLengthDelimited();
        return _Field(number, wireType, 0);
      case 1:
        _pos += 8;
        return _Field(number, wireType, 0);
      case 5:
        _pos += 4;
        return _Field(number, wireType, 0);
      default:
        throw FormatException('Unsupported protobuf wire type $wireType');
    }
  }
}

// ---------------------------------------------------------------------------
// constants.proto — enum Status
// ---------------------------------------------------------------------------

/// Mirrors `enum Status` in constants.proto. Only `success` is checked for
/// meaning today; the rest are kept so failures can be logged precisely.
enum ProvStatus {
  success,
  invalidSecScheme,
  invalidProto,
  tooManySessions,
  invalidArgument,
  internalError,
  cryptoError,
  invalidSession,
  unknown,
}

ProvStatus _statusFromInt(int v) => v >= 0 && v < ProvStatus.values.length - 1
    ? ProvStatus.values[v]
    : ProvStatus.unknown;

// ---------------------------------------------------------------------------
// session.proto + sec0.proto — the (trivial, unencrypted) Security0 handshake
// ---------------------------------------------------------------------------

/// Builds the `SessionData{sec_ver=SecScheme0, sec0{msg=S0_Session_Command,
/// sc={}}}` request written to the `prov-session` characteristic to open a
/// Security0 session. Field numbers: SessionData.sec_ver=2, SessionData.sec0
/// (oneof)=10; Sec0Payload.msg=1, Sec0Payload.sc (oneof)=20.
Uint8List buildSec0SessionCmd() {
  final sec0 = _ProtoWriter()
    ..varintField(1, 0) // msg = S0_Session_Command
    ..messageField(20, Uint8List(0)); // sc = S0SessionCmd{} (empty)
  final session = _ProtoWriter()
    ..varintField(2, 0) // sec_ver = SecScheme0
    ..messageField(10, sec0.toBytes()); // sec0 payload
  return session.toBytes();
}

/// Parses the device's `SessionData{sec0{sr{status}}}` reply. Throws
/// [FormatException] if the reply isn't a Sec0 session response.
ProvStatus parseSec0SessionResp(Uint8List data) {
  final r = _ProtoReader(data);
  Uint8List? sec0Bytes;
  while (!r.isAtEnd) {
    final f = r.readField();
    if (f.number == 10 && f.wireType == 2) sec0Bytes = r.lastBytes;
  }
  if (sec0Bytes == null) {
    throw const FormatException('SessionData missing sec0 payload');
  }
  final sr = _ProtoReader(sec0Bytes);
  Uint8List? srBytes;
  while (!sr.isAtEnd) {
    final f = sr.readField();
    if (f.number == 21 && f.wireType == 2) srBytes = sr.lastBytes;
  }
  if (srBytes == null) {
    throw const FormatException('Sec0Payload missing sr (session response)');
  }
  final resp = _ProtoReader(srBytes);
  var status = 0;
  while (!resp.isAtEnd) {
    final f = resp.readField();
    if (f.number == 1 && f.wireType == 0) status = f.value;
  }
  return _statusFromInt(status);
}

// ---------------------------------------------------------------------------
// wifi_scan.proto
// ---------------------------------------------------------------------------

/// WiFiScanPayload.msg enum values (WiFiScanMsgType).
class _ScanMsg {
  static const cmdScanStart = 0;
  static const cmdScanStatus = 2;
  static const cmdScanResult = 4;
}

/// Builds a `WiFiScanPayload{msg=TypeCmdScanStart, cmd_scan_start{...}}`
/// request for the `prov-scan` characteristic. `groupChannels=0` scans every
/// channel in one pass (no channel grouping delay); `periodMs=0` lets the
/// device apply its own default dwell time.
Uint8List buildScanStart({
  bool blocking = false,
  bool passive = false,
  int groupChannels = 0,
  int periodMs = 0,
}) {
  final cmd = _ProtoWriter()
    ..boolField(1, blocking)
    ..boolField(2, passive)
    ..varintField(3, groupChannels)
    ..varintField(4, periodMs);
  final payload = _ProtoWriter()
    ..varintField(1, _ScanMsg.cmdScanStart)
    ..messageField(10, cmd.toBytes());
  return payload.toBytes();
}

/// Builds a `WiFiScanPayload{msg=TypeCmdScanStatus, cmd_scan_status={}}`
/// request — poll this until [ScanStatus.finished] is true.
Uint8List buildScanStatus() {
  final payload = _ProtoWriter()
    ..varintField(1, _ScanMsg.cmdScanStatus)
    ..messageField(12, Uint8List(0));
  return payload.toBytes();
}

/// Builds a `WiFiScanPayload{msg=TypeCmdScanResult, cmd_scan_result{...}}`
/// request to fetch up to [count] results starting at [startIndex].
Uint8List buildScanResult(int startIndex, int count) {
  final cmd = _ProtoWriter()
    ..varintField(1, startIndex)
    ..varintField(2, count);
  final payload = _ProtoWriter()
    ..varintField(1, _ScanMsg.cmdScanResult)
    ..messageField(14, cmd.toBytes());
  return payload.toBytes();
}

class ScanStatus {
  const ScanStatus({required this.finished, required this.resultCount});
  final bool finished;
  final int resultCount;
}

/// Parses a `RespScanStatus` reply (field 13 of WiFiScanPayload).
ScanStatus parseScanStatus(Uint8List data) {
  final r = _ProtoReader(data);
  Uint8List? inner;
  while (!r.isAtEnd) {
    final f = r.readField();
    if (f.number == 13 && f.wireType == 2) inner = r.lastBytes;
  }
  if (inner == null) {
    throw const FormatException('WiFiScanPayload missing resp_scan_status');
  }
  final rr = _ProtoReader(inner);
  var finished = false;
  var count = 0;
  while (!rr.isAtEnd) {
    final f = rr.readField();
    if (f.number == 1) finished = f.value != 0;
    if (f.number == 2) count = f.value;
  }
  return ScanStatus(finished: finished, resultCount: count);
}

/// One entry of a Wi-Fi scan result (mirrors `WiFiScanResult`).
class WifiScanEntry {
  const WifiScanEntry({
    required this.ssid,
    required this.channel,
    required this.rssi,
    required this.secure,
  });
  final String ssid;
  final int channel;
  final int rssi;
  final bool secure; // auth != Open (0)
}

/// Parses a `RespScanResult` reply (field 15 of WiFiScanPayload) into a list
/// of [WifiScanEntry].
List<WifiScanEntry> parseScanResult(Uint8List data) {
  final r = _ProtoReader(data);
  Uint8List? inner;
  while (!r.isAtEnd) {
    final f = r.readField();
    if (f.number == 15 && f.wireType == 2) inner = r.lastBytes;
  }
  if (inner == null) {
    throw const FormatException('WiFiScanPayload missing resp_scan_result');
  }
  final entries = <WifiScanEntry>[];
  final rr = _ProtoReader(inner);
  while (!rr.isAtEnd) {
    final f = rr.readField();
    if (f.number != 1 || f.wireType != 2) continue; // repeated `entries`
    final er = _ProtoReader(rr.lastBytes!);
    var ssid = '';
    var channel = 0;
    var rssi = 0;
    var auth = 0;
    while (!er.isAtEnd) {
      final ef = er.readField();
      switch (ef.number) {
        case 1:
          ssid = utf8.decode(er.lastBytes!, allowMalformed: true);
        case 2:
          channel = ef.value;
        case 3:
          rssi = ef.value;
        case 5:
          auth = ef.value;
      }
    }
    entries.add(
      WifiScanEntry(
        ssid: ssid,
        channel: channel,
        rssi: rssi,
        secure: auth != 0,
      ),
    );
  }
  return entries;
}

// ---------------------------------------------------------------------------
// wifi_config.proto
// ---------------------------------------------------------------------------

class _ConfigMsg {
  static const cmdGetStatus = 0;
  static const cmdSetConfig = 2;
  static const cmdApplyConfig = 4;
}

/// Builds `WiFiConfigPayload{msg=TypeCmdGetStatus, cmd_get_status={}}` for
/// the `prov-config` characteristic.
Uint8List buildGetStatus() {
  final payload = _ProtoWriter()
    ..varintField(1, _ConfigMsg.cmdGetStatus)
    ..messageField(10, Uint8List(0));
  return payload.toBytes();
}

/// Builds `WiFiConfigPayload{msg=TypeCmdSetConfig, cmd_set_config{ssid,
/// passphrase}}`. Under Security0 this crosses the air in the clear — see
/// docs/CONNECTIVITY.md.
Uint8List buildSetConfig(String ssid, String password) {
  final cmd = _ProtoWriter()
    ..bytesField(1, utf8.encode(ssid))
    ..bytesField(2, utf8.encode(password));
  final payload = _ProtoWriter()
    ..varintField(1, _ConfigMsg.cmdSetConfig)
    ..messageField(12, cmd.toBytes());
  return payload.toBytes();
}

/// Builds `WiFiConfigPayload{msg=TypeCmdApplyConfig, cmd_apply_config={}}` —
/// tells the device to actually connect with the config just set.
Uint8List buildApplyConfig() {
  final payload = _ProtoWriter()
    ..varintField(1, _ConfigMsg.cmdApplyConfig)
    ..messageField(14, Uint8List(0));
  return payload.toBytes();
}

/// Station connection state, mirroring `enum WifiStationState`.
enum ProvStaState { connected, connecting, disconnected, connectionFailed }

ProvStaState _staStateFromInt(int v) => v >= 0 && v < ProvStaState.values.length
    ? ProvStaState.values[v]
    : ProvStaState.disconnected;

/// Result of a `RespGetStatus` (also what `RespSetConfig`/`RespApplyConfig`
/// reduce to for the fields we care about).
class WifiConfigStatus {
  const WifiConfigStatus({
    required this.status,
    this.staState,
    this.ip4Addr,
    this.authFailed = false,
    this.networkNotFound = false,
    this.attemptsRemaining,
  });
  final ProvStatus status;
  final ProvStaState? staState;
  final String? ip4Addr;
  final bool authFailed;
  final bool networkNotFound;
  final int? attemptsRemaining;
}

/// Parses a plain `RespSetConfig`/`RespApplyConfig` (just a top-level
/// `status` field at message field 1 inside field 13/15).
ProvStatus _parseSimpleConfigStatus(Uint8List data, int replyField) {
  final r = _ProtoReader(data);
  Uint8List? inner;
  while (!r.isAtEnd) {
    final f = r.readField();
    if (f.number == replyField && f.wireType == 2) inner = r.lastBytes;
  }
  if (inner == null) {
    throw FormatException('WiFiConfigPayload missing reply field $replyField');
  }
  final rr = _ProtoReader(inner);
  var status = 0;
  while (!rr.isAtEnd) {
    final f = rr.readField();
    if (f.number == 1 && f.wireType == 0) status = f.value;
  }
  return _statusFromInt(status);
}

/// Parses a `RespSetConfig` reply (field 13 of WiFiConfigPayload).
ProvStatus parseSetConfigStatus(Uint8List data) =>
    _parseSimpleConfigStatus(data, 13);

/// Parses a `RespApplyConfig` reply (field 15 of WiFiConfigPayload).
ProvStatus parseApplyConfigStatus(Uint8List data) =>
    _parseSimpleConfigStatus(data, 15);

/// Parses a `RespGetStatus` reply (field 11 of WiFiConfigPayload).
WifiConfigStatus parseGetStatus(Uint8List data) {
  final r = _ProtoReader(data);
  Uint8List? inner;
  while (!r.isAtEnd) {
    final f = r.readField();
    if (f.number == 11 && f.wireType == 2) inner = r.lastBytes;
  }
  if (inner == null) {
    throw const FormatException('WiFiConfigPayload missing resp_get_status');
  }
  final rr = _ProtoReader(inner);
  var status = 0;
  var staState = 0;
  var authFailed = false;
  var networkNotFound = false;
  int? attemptsRemaining;
  String? ip;
  while (!rr.isAtEnd) {
    final f = rr.readField();
    switch (f.number) {
      case 1:
        status = f.value;
      case 2:
        staState = f.value;
      case 10: // fail_reason (WifiConnectFailedReason enum)
        if (f.value == 0) authFailed = true;
        if (f.value == 1) networkNotFound = true;
      case 11: // connected (WifiConnectedState message)
        final wr = _ProtoReader(rr.lastBytes!);
        while (!wr.isAtEnd) {
          final wf = wr.readField();
          if (wf.number == 1 && wf.wireType == 2) {
            ip = utf8.decode(wr.lastBytes!, allowMalformed: true);
          }
        }
      case 12: // attempt_failed (WifiAttemptFailed message)
        final ar = _ProtoReader(rr.lastBytes!);
        while (!ar.isAtEnd) {
          final af = ar.readField();
          if (af.number == 1 && af.wireType == 0) {
            attemptsRemaining = af.value;
          }
        }
    }
  }
  return WifiConfigStatus(
    status: _statusFromInt(status),
    staState: _staStateFromInt(staState),
    ip4Addr: ip,
    authFailed: authFailed,
    networkNotFound: networkNotFound,
    attemptsRemaining: attemptsRemaining,
  );
}
