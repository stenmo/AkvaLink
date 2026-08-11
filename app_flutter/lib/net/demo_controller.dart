// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'station_discovery.dart';

/// "Try without hardware" mode: synthesizes a plausible pool day — a warm
/// afternoon peak, a cool early morning — through the exact same UI the real
/// device feeds. Time is compressed (1 real second = 2 demo minutes) so the
/// trend arrow, rate line and sparkline all visibly move within a minute of
/// switching it on. Deterministic, no network, no permissions.
class DemoController extends ChangeNotifier {
  Timer? _timer;
  bool _enabled = false;
  DateTime _started = DateTime.now();
  double? _minSeen;
  double? _maxSeen;

  static const _baseC = 27.5;
  static const _amplitudeC = 1.6;
  // 1 real second = 2 demo minutes → a full day sweeps by in 12 minutes.
  static const _demoMinutesPerRealSecond = 2.0;

  bool get enabled => _enabled;

  void setEnabled(bool v) {
    if (v == _enabled) return;
    _enabled = v;
    if (v) {
      _started = DateTime.now();
      _minSeen = _maxSeen = null;
      _tick();
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _tick());
    } else {
      _timer?.cancel();
      _timer = null;
    }
    notifyListeners();
  }

  void _tick() {
    final c = celsius;
    if (c != null) {
      if (_minSeen == null || c < _minSeen!) _minSeen = c;
      if (_maxSeen == null || c > _maxSeen!) _maxSeen = c;
    }
    notifyListeners();
  }

  /// Demo-clock hours elapsed since the toggle went on, starting mid-morning
  /// (09:00) so the first thing the user sees is the temperature rising.
  double get _demoHours =>
      9.0 +
      DateTime.now().difference(_started).inMilliseconds /
          1000.0 *
          _demoMinutesPerRealSecond /
          60.0;

  /// The day curve: sinusoid peaking at 15:00, dipping at 03:00.
  double _curve(double hours) =>
      _baseC + _amplitudeC * sin((hours - 9.0) * pi / 12.0);

  /// °C per hour — analytic derivative of the day curve.
  double _slope(double hours) =>
      _amplitudeC * pi / 12.0 * cos((hours - 9.0) * pi / 12.0);

  double? get celsius {
    if (!_enabled) return null;
    final h = _demoHours;
    // Sensor-noise shimmer, well under the DS18B20's 0.0625 °C LSB story.
    final noise = 0.02 * sin(h * 97.0);
    return _curve(h) + noise;
  }

  TrendInfo? get trend {
    if (!_enabled) return null;
    final perHour = _slope(_demoHours);
    final dir = perHour > 0.15
        ? TrendDirection.rising
        : perHour < -0.15
        ? TrendDirection.falling
        : TrendDirection.stable;
    return TrendInfo(direction: dir, deltaCPerMin: perHour / 60.0);
  }

  TempStats? get stats {
    if (!_enabled || _minSeen == null) return null;
    return TempStats(min: _minSeen, max: _maxSeen);
  }

  TempHistory? get history {
    if (!_enabled) return null;
    final h = _demoHours;
    // 24 h of 5-min buckets and 7 d of 1-h buckets ending "now", same shapes
    // main/web_page.cpp serves. The weekly series adds a slow drift so the
    // 7 d tab doesn't look like a copy of the 24 h one.
    final minute = List<double>.generate(
      288,
      (i) => _curve(h - (287 - i) * 5.0 / 60.0),
    );
    final hourly = List<double>.generate(168, (i) {
      final t = h - (167 - i).toDouble();
      return _curve(t) + 0.5 * sin(t * pi / 84.0);
    });
    return TempHistory(minute: minute, hourly: hourly);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
