// SPDX-License-Identifier: Apache-2.0
//
// A scriptable in-memory UniversalBlePlatform for tests. Install it with
// `UniversalBle.setInstance(fake)` in setUp. Push scan results, notifications
// and connection drops from the test body; inspect recorded writes.

import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

class FakeBleWrite {
  FakeBleWrite(
    this.service,
    this.characteristic,
    this.value,
    this.withoutResponse,
  );
  final String service;
  final String characteristic;
  final Uint8List value;
  final bool withoutResponse;
}

class FakeBlePlatform extends UniversalBlePlatform {
  AvailabilityState availability = AvailabilityState.poweredOn;
  bool permissionsGranted = true;
  bool connectShouldThrow = false;

  /// Devices delivered on the next [startScan].
  List<BleDevice> scanResults = [];

  /// Values returned by reads, keyed by "service|characteristic" (parsed).
  final Map<String, Uint8List> readValues = {};

  /// Substring of a characteristic UUID that [writeValue] should throw on
  /// (simulates a dropped link mid-transfer). Null = never throw.
  String? writeThrowsOnContaining;

  /// Every write the code under test performed, in order.
  final List<FakeBleWrite> writes = [];

  bool _scanning = false;

  static String _key(String s, String c) =>
      '${BleUuidParser.string(s)}|${BleUuidParser.string(c)}';

  void setRead(String service, String characteristic, List<int> value) {
    readValues[_key(service, characteristic)] = Uint8List.fromList(value);
  }

  /// Push a characteristic notification to any listeners.
  void pushNotification(
    String deviceId,
    String characteristic,
    List<int> value,
  ) {
    updateCharacteristicValue(
      deviceId,
      characteristic,
      Uint8List.fromList(value),
      null,
    );
  }

  /// Simulate the peripheral dropping the link.
  void dropConnection(String deviceId) => updateConnection(deviceId, false);

  // ---- UniversalBlePlatform overrides -------------------------------------

  @override
  Future<AvailabilityState> getBluetoothAvailabilityState() async =>
      availability;

  @override
  Future<bool> enableBluetooth() async => true;

  @override
  Future<bool> disableBluetooth() async => true;

  @override
  Future<bool> hasPermissions({bool withAndroidFineLocation = false}) async =>
      permissionsGranted;

  @override
  Future<void> requestPermissions({
    bool withAndroidFineLocation = false,
  }) async {}

  @override
  Future<void> startScan({
    ScanFilter? scanFilter,
    PlatformConfig? platformConfig,
  }) async {
    _scanning = true;
    for (final d in scanResults) {
      updateScanResult(d);
    }
  }

  @override
  Future<void> stopScan() async => _scanning = false;

  @override
  Future<bool> isScanning() async => _scanning;

  @override
  Future<void> connect(
    String deviceId, {
    Duration? connectionTimeout,
    bool autoConnect = false,
  }) async {
    if (connectShouldThrow) throw Exception('connect failed');
    updateConnection(deviceId, true);
  }

  @override
  Future<void> disconnect(String deviceId) async =>
      updateConnection(deviceId, false);

  @override
  Future<List<BleService>> discoverServices(
    String deviceId,
    bool withDescriptors,
  ) async => const [];

  @override
  Future<void> setNotifiable(
    String deviceId,
    String service,
    String characteristic,
    BleInputProperty bleInputProperty,
  ) async {}

  @override
  Future<Uint8List> readValue(
    String deviceId,
    String service,
    String characteristic, {
    Duration? timeout,
  }) async {
    final v = readValues[_key(service, characteristic)];
    if (v == null) throw Exception('no value for $service/$characteristic');
    return v;
  }

  @override
  Future<void> writeValue(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value,
    BleOutputProperty bleOutputProperty,
  ) async {
    final sub = writeThrowsOnContaining;
    if (sub != null &&
        BleUuidParser.string(characteristic).contains(sub.toLowerCase())) {
      throw Exception('link dropped');
    }
    writes.add(
      FakeBleWrite(
        service,
        characteristic,
        value,
        bleOutputProperty == BleOutputProperty.withoutResponse,
      ),
    );
  }

  @override
  Future<int> requestMtu(String deviceId, int expectedMtu) async => expectedMtu;

  @override
  Future<int> readRssi(String deviceId) async => -50;

  @override
  Future<bool> isPaired(String deviceId) async => true;

  @override
  Future<bool> pair(String deviceId) async => true;

  @override
  Future<void> unpair(String deviceId) async {}

  @override
  Future<BleConnectionState> getConnectionState(String deviceId) async =>
      BleConnectionState.connected;

  @override
  Future<List<BleDevice>> getSystemDevices(List<String>? withServices) async =>
      const [];
}

/// Build a [BleDevice] as it would appear from a scan.
BleDevice fakeDevice({
  required String id,
  String? name,
  int rssi = -60,
  List<String> services = const [],
}) => BleDevice(deviceId: id, name: name, rssi: rssi, services: services);
