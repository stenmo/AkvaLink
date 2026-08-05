// SPDX-License-Identifier: Apache-2.0
//
// Unit tests for the pure helpers in station_discovery.dart. The full
// discover() flow depends on real mDNS UDP I/O (MDnsClient has no fake
// transport), so it isn't exercised here — these cover the two decision
// points that are actual bugs waiting to happen if firmware and app drift:
// which PTR record is "ours", and how the /temp JSON body is parsed.

import 'package:akvalink/net/station_discovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('matchesStationInstance', () {
    test('matches the exact firmware instance name', () {
      expect(
        matchesStationInstance('AkvaLink temperature._http._tcp.local'),
        isTrue,
      );
    });

    test('rejects unrelated services', () {
      expect(matchesStationInstance('Some Printer._http._tcp.local'), isFalse);
    });

    test('rejects a name that merely contains the instance name', () {
      expect(
        matchesStationInstance('Not AkvaLink temperature._http._tcp.local'),
        isFalse,
      );
    });
  });

  group('parseTempJson', () {
    test('parses a normal reading', () {
      expect(parseTempJson('{"celsius":28.37}'), closeTo(28.37, 1e-9));
    });

    test('returns null for no reading yet', () {
      expect(parseTempJson('{"celsius":null}'), isNull);
    });

    test('returns null for malformed body', () {
      expect(parseTempJson('not json'), isNull);
    });

    test('returns null for missing field', () {
      expect(parseTempJson('{}'), isNull);
    });
  });
}
