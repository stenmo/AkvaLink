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

  group('parseTrendJson', () {
    test('parses rising', () {
      expect(
        parseTrendJson('{"direction":"rising","delta_c_per_min":0.12}'),
        TrendDirection.rising,
      );
    });

    test('parses falling', () {
      expect(
        parseTrendJson('{"direction":"falling","delta_c_per_min":-0.08}'),
        TrendDirection.falling,
      );
    });

    test('parses stable', () {
      expect(
        parseTrendJson('{"direction":"stable","delta_c_per_min":0.00}'),
        TrendDirection.stable,
      );
    });

    test('returns null for an unknown direction', () {
      expect(parseTrendJson('{"direction":"sideways"}'), isNull);
    });

    test('returns null for malformed body', () {
      expect(parseTrendJson('not json'), isNull);
    });
  });

  group('parseTrendInfoJson', () {
    test('parses direction + rate, converts to °C/h', () {
      final info = parseTrendInfoJson(
        '{"direction":"rising","delta_c_per_min":0.02}',
      );
      expect(info!.direction, TrendDirection.rising);
      expect(info.deltaCPerMin, closeTo(0.02, 1e-9));
      expect(info.deltaCPerHour, closeTo(1.2, 1e-9));
    });

    test('missing rate leaves deltaCPerMin null', () {
      final info = parseTrendInfoJson('{"direction":"stable"}');
      expect(info!.direction, TrendDirection.stable);
      expect(info.deltaCPerMin, isNull);
      expect(info.deltaCPerHour, isNull);
    });

    test('returns null for malformed body', () {
      expect(parseTrendInfoJson('not json'), isNull);
    });
  });

  group('parseStatsJson', () {
    test('parses min and max', () {
      final stats = parseStatsJson('{"min":26.10,"max":29.80,"since_s":3600}');
      expect(stats!.min, closeTo(26.10, 1e-9));
      expect(stats.max, closeTo(29.80, 1e-9));
    });

    test('returns null for malformed body', () {
      expect(parseStatsJson('not json'), isNull);
    });
  });

  group('parseHistoryJson', () {
    test('parses both series, oldest first', () {
      final h = parseHistoryJson(
        '{"minute":[26.1,26.2,26.4],"hourly":[25.0,27.5]}',
      );
      expect(h!.minute, [26.1, 26.2, 26.4]);
      expect(h.hourly, [25.0, 27.5]);
      expect(h.isEmpty, isFalse);
    });

    test('a fresh device with no history yet is empty, not an error', () {
      final h = parseHistoryJson('{"minute":[],"hourly":[]}');
      expect(h!.isEmpty, isTrue);
    });

    test('drops null slots rather than charting them as 0 °C', () {
      final h = parseHistoryJson('{"minute":[26.1,null,26.3],"hourly":[]}');
      expect(h!.minute, [26.1, 26.3]);
    });

    test('handles integer-valued samples', () {
      expect(parseHistoryJson('{"minute":[26,27],"hourly":[]}')!.minute, [
        26.0,
        27.0,
      ]);
    });

    test('missing keys give empty series', () {
      final h = parseHistoryJson('{}');
      expect(h!.minute, isEmpty);
      expect(h.hourly, isEmpty);
    });

    test('returns null for malformed body', () {
      expect(parseHistoryJson('not json'), isNull);
    });
  });
}
