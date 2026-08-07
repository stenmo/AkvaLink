// SPDX-License-Identifier: Apache-2.0
//
// AkvaLinkController tests — scanning, connection, temperature parsing,
// device info, link drops and error paths, driven by a FakeBlePlatform.

import 'dart:typed_data';

import 'package:akvalink/ble/akvalink_controller.dart';
import 'package:akvalink/ble/akvalink_uuids.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_ble/universal_ble.dart';

import 'fakes/fake_ble_platform.dart';

void main() {
  late FakeBlePlatform fake;

  // A short scan settle so tests don't wait the production 4 s.
  AkvaLinkController newController() =>
      AkvaLinkController(scanSettle: const Duration(milliseconds: 20));

  setUp(() {
    fake = FakeBlePlatform();
    UniversalBle.setInstance(fake);
  });

  /// sint16 little-endian encoder for temperature (0.01 °C units).
  Uint8List centi(int value) {
    final v = value < 0 ? value + 0x10000 : value;
    return Uint8List.fromList([v & 0xFF, (v >> 8) & 0xFF]);
  }

  void seedDevice(String id, {String name = 'AkvaLink-1234'}) {
    fake.scanResults = [
      fakeDevice(
        id: id,
        name: name,
        rssi: -50,
        services: [AkvaUuids.essService],
      ),
    ];
    fake.setRead(AkvaUuids.essService, AkvaUuids.tempChar, centi(2840));
    fake.setRead(
      AkvaUuids.disService,
      AkvaUuids.fwChar,
      '0.3.1-thread'.codeUnits,
    );
    fake.setRead(AkvaUuids.basService, AkvaUuids.batteryChar, [87]);
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 120));

  group('preflight', () {
    test('unsupported Bluetooth → error state', () async {
      fake.availability = AvailabilityState.unsupported;
      final c = newController();
      await c.scanAndConnect();
      expect(c.state, AkvaConnState.error);
      expect(c.error, contains('not supported'));
      c.dispose();
    });

    test('powered-off Bluetooth → error state', () async {
      fake.availability = AvailabilityState.poweredOff;
      final c = newController();
      await c.scanAndConnect();
      expect(c.state, AkvaConnState.error);
      expect(c.error, contains('turned off'));
      c.dispose();
    });
  });

  group('scanning', () {
    test('finds AkvaLink by service and connects', () async {
      seedDevice('dev-1');
      final c = newController();
      await c.scanAndConnect();
      await settle();
      expect(c.state, AkvaConnState.connected);
      expect(c.deviceId, 'dev-1');
      c.dispose();
    });

    test('matches by name prefix even without service UUID', () async {
      fake.scanResults = [fakeDevice(id: 'dev-2', name: 'AkvaLink-pool')];
      fake.setRead(AkvaUuids.essService, AkvaUuids.tempChar, centi(2000));
      final c = newController();
      await c.scanAndConnect();
      await settle();
      expect(c.state, AkvaConnState.connected);
      expect(c.deviceId, 'dev-2');
      c.dispose();
    });

    test('picks the strongest RSSI among several', () async {
      fake.scanResults = [
        fakeDevice(id: 'weak', name: 'AkvaLink-a', rssi: -80),
        fakeDevice(id: 'strong', name: 'AkvaLink-b', rssi: -40),
        fakeDevice(id: 'mid', name: 'AkvaLink-c', rssi: -60),
      ];
      fake.setRead(AkvaUuids.essService, AkvaUuids.tempChar, centi(2500));
      final c = newController();
      await c.scanAndConnect();
      await settle();
      expect(c.deviceId, 'strong');
      c.dispose();
    });

    test('no device at all nearby → error', () async {
      fake.scanResults = [];
      final c = newController();
      await c.scanAndConnect();
      await settle();
      expect(c.state, AkvaConnState.error);
      expect(c.error, contains('No AkvaLink'));
      c.dispose();
    });

    test(
      'no exact name/service match → offers nearby devices to pick',
      () async {
        fake.scanResults = [fakeDevice(id: 'other', name: 'SomeSpeaker')];
        final c = newController();
        await c.scanAndConnect();
        await settle();
        expect(c.state, AkvaConnState.selecting);
        expect(c.discoveredDevices.map((d) => d.name), contains('SomeSpeaker'));
        c.dispose();
      },
    );

    test('picking a discovered device connects to it', () async {
      fake.scanResults = [fakeDevice(id: 'other', name: 'SomeSpeaker')];
      fake.setRead(AkvaUuids.essService, AkvaUuids.tempChar, centi(2500));
      final c = newController();
      await c.scanAndConnect();
      await settle();
      expect(c.state, AkvaConnState.selecting);

      await c.connectToDiscovered(c.discoveredDevices.first);
      await settle();
      expect(c.state, AkvaConnState.connected);
      expect(c.deviceId, 'other');
      c.dispose();
    });

    test('cancelSelecting returns to idle', () async {
      fake.scanResults = [fakeDevice(id: 'other', name: 'SomeSpeaker')];
      final c = newController();
      await c.scanAndConnect();
      await settle();
      expect(c.state, AkvaConnState.selecting);

      await c.cancelSelecting();
      expect(c.state, AkvaConnState.idle);
      c.dispose();
    });

    test('re-entrant scanAndConnect is ignored while scanning', () async {
      seedDevice('dev-1');
      final c = newController();
      final first = c.scanAndConnect();
      // Immediate second call should early-return without throwing.
      await c.scanAndConnect();
      await first;
      await settle();
      expect(c.state, AkvaConnState.connected);
      c.dispose();
    });
  });

  group('temperature', () {
    test('primes from initial read then updates on notify', () async {
      seedDevice('dev-1');
      final c = newController();
      await c.scanAndConnect();
      await settle();
      expect(c.temperatureC, closeTo(28.40, 0.001));

      fake.pushNotification('dev-1', AkvaUuids.tempChar, centi(3012));
      await settle();
      expect(c.temperatureC, closeTo(30.12, 0.001));
      c.dispose();
    });

    test('decodes negative temperatures (sint16)', () async {
      seedDevice('dev-1');
      fake.setRead(AkvaUuids.essService, AkvaUuids.tempChar, centi(-550));
      final c = newController();
      await c.scanAndConnect();
      await settle();
      expect(c.temperatureC, closeTo(-5.50, 0.001));
      c.dispose();
    });

    test('ignores a short (malformed) notification', () async {
      seedDevice('dev-1');
      final c = newController();
      await c.scanAndConnect();
      await settle();
      final before = c.temperatureC;
      fake.pushNotification('dev-1', AkvaUuids.tempChar, [0x01]); // 1 byte
      await settle();
      expect(c.temperatureC, before);
      c.dispose();
    });
  });

  group('device info', () {
    test('reads firmware revision + battery, parses variant/version', () async {
      seedDevice('dev-1');
      final c = newController();
      await c.scanAndConnect();
      await settle();
      expect(c.firmware, '0.3.1-thread');
      expect(c.firmwareVersion, '0.3.1');
      expect(c.variant, 'thread');
      expect(c.batteryPercent, 87);
      c.dispose();
    });

    test('survives a firmware read failure (stays connected)', () async {
      fake.scanResults = [
        fakeDevice(
          id: 'dev-1',
          name: 'AkvaLink-x',
          services: [AkvaUuids.essService],
        ),
      ];
      fake.setRead(AkvaUuids.essService, AkvaUuids.tempChar, centi(2200));
      // No DIS/BAS reads seeded → those reads throw, but connect must succeed.
      final c = newController();
      await c.scanAndConnect();
      await settle();
      expect(c.state, AkvaConnState.connected);
      expect(c.firmware, isNull);
      expect(c.batteryPercent, isNull);
      c.dispose();
    });
  });

  group('alert thresholds', () {
    test('reads both thresholds from the custom service', () async {
      seedDevice('dev-1');
      fake.setRead(AkvaUuids.akvaService, AkvaUuids.alertHighChar, centi(3000));
      fake.setRead(AkvaUuids.akvaService, AkvaUuids.alertLowChar, centi(500));
      final c = newController();
      await c.scanAndConnect();
      await settle();
      expect(c.alertsSupported, isTrue);
      expect(c.alertHighC, 30.0);
      expect(c.alertLowC, 5.0);
      c.dispose();
    });

    test('0 reads back as "disabled" (null), not 0 °C', () async {
      seedDevice('dev-1');
      fake.setRead(AkvaUuids.akvaService, AkvaUuids.alertHighChar, centi(0));
      fake.setRead(AkvaUuids.akvaService, AkvaUuids.alertLowChar, centi(-250));
      final c = newController();
      await c.scanAndConnect();
      await settle();
      expect(c.alertsSupported, isTrue);
      expect(c.alertHighC, isNull);
      expect(c.alertLowC, -2.5); // negative thresholds must survive sign-extension
      c.dispose();
    });

    test('unsupported when the custom service is absent', () async {
      seedDevice('dev-1'); // no alert characteristics seeded → reads throw
      final c = newController();
      await c.scanAndConnect();
      await settle();
      expect(c.state, AkvaConnState.connected);
      expect(c.alertsSupported, isFalse);
      c.dispose();
    });

    test('setAlerts writes little-endian sint16, null = 0 = disabled', () async {
      seedDevice('dev-1');
      fake.setRead(AkvaUuids.akvaService, AkvaUuids.alertHighChar, centi(0));
      fake.setRead(AkvaUuids.akvaService, AkvaUuids.alertLowChar, centi(0));
      final c = newController();
      await c.scanAndConnect();
      await settle();
      fake.writes.clear();

      expect(await c.setAlerts(highC: 29.5, lowC: null), isTrue);
      final writes = fake.writes
          .where((w) => w.characteristic.toLowerCase().contains('6c000'))
          .toList();
      expect(writes.length, 2);
      expect(writes[0].value, centi(2950)); // 29.50 °C → 0x0B86 → 86 0b
      expect(writes[1].value, centi(0)); // null → disabled
      expect(c.alertHighC, 29.5);
      expect(c.alertLowC, isNull);
      c.dispose();
    });

    test('setAlerts is a no-op when the device has no custom service', () async {
      seedDevice('dev-1');
      final c = newController();
      await c.scanAndConnect();
      await settle();
      fake.writes.clear();
      expect(await c.setAlerts(highC: 30), isFalse);
      expect(fake.writes, isEmpty);
      c.dispose();
    });
  });

  group('connection lifecycle', () {
    test('link dropped by peripheral → returns to idle, clears data', () async {
      seedDevice('dev-1');
      final c = newController();
      await c.scanAndConnect();
      await settle();
      expect(c.state, AkvaConnState.connected);

      fake.dropConnection('dev-1');
      await settle();
      expect(c.state, AkvaConnState.idle);
      expect(c.temperatureC, isNull);
      expect(c.batteryPercent, isNull);
      c.dispose();
    });

    test('connect() failure surfaces as error state', () async {
      seedDevice('dev-1');
      fake.connectShouldThrow = true;
      final c = newController();
      await c.scanAndConnect();
      await settle();
      expect(c.state, AkvaConnState.error);
      expect(c.error, contains('Connect failed'));
      c.dispose();
    });

    test('explicit disconnect() returns to idle', () async {
      seedDevice('dev-1');
      final c = newController();
      await c.scanAndConnect();
      await settle();
      await c.disconnect();
      expect(c.state, AkvaConnState.idle);
      expect(c.isConnected, isFalse);
      c.dispose();
    });
  });
}
