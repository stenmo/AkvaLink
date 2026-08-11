// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../net/demo_controller.dart';
import '../net/station_discovery.dart';
import '../strings.dart';
import '../theme.dart';

/// 24 h / 7 d temperature history from a discovered Wi-Fi station, mirroring
/// the sparkline main/web_page.cpp already draws on the device's own page.
///
/// Painted by hand rather than pulling in a charting package: a single
/// polyline plus two labels doesn't justify a dependency (see the KISS note
/// in .github/copilot-instructions.md). BLE exposes no history, so this card
/// only appears on the LAN path.
class HistoryChartCard extends StatefulWidget {
  const HistoryChartCard({super.key});

  @override
  State<HistoryChartCard> createState() => _HistoryChartCardState();
}

class _HistoryChartCardState extends State<HistoryChartCard> {
  Timer? _timer;
  StationDiscoveryController? _discovery;
  TempHistory? _history;
  bool _weekView = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final discovery = context.read<StationDiscoveryController>();
    if (discovery.phase == DiscoveryPhase.found) {
      _start(discovery);
    } else {
      _stop();
    }
  }

  void _start(StationDiscoveryController discovery) {
    if (_timer != null) return;
    _discovery = discovery;
    _refresh();
    // The device aggregates into 5-minute buckets, so anything faster than
    // this is just re-fetching the same array.
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final h = await _discovery?.fetchHistory();
    if (mounted && h != null) setState(() => _history = h);
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _discovery = null;
    _history = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final discovery = context.watch<StationDiscoveryController>();
    final demo = context.watch<DemoController>();
    final s = context.watch<Strings>();

    final h = demo.enabled ? demo.history : _history;
    final available = demo.enabled || discovery.phase == DiscoveryPhase.found;
    if (!available || h == null || h.isEmpty) {
      return const SizedBox.shrink();
    }
    final series = _weekView ? h.hourly : h.minute;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.show_chart, color: AkvaColors.deep),
                  const SizedBox(width: 8),
                  Text(
                    s.historyTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  SegmentedButton<bool>(
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: [
                      ButtonSegment<bool>(
                        value: false,
                        label: Text(s.history24h),
                      ),
                      ButtonSegment<bool>(
                        value: true,
                        label: Text(s.history7d),
                      ),
                    ],
                    selected: {_weekView},
                    showSelectedIcon: false,
                    onSelectionChanged: (v) =>
                        setState(() => _weekView = v.first),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (series.length < 2)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    s.historyBuilding,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              else ...[
                SizedBox(
                  height: 120,
                  width: double.infinity,
                  child: CustomPaint(painter: _SparklinePainter(series)),
                ),
                const SizedBox(height: 8),
                Text(
                  s.historyRange(
                    _fmt(series.reduce((a, b) => a < b ? a : b)),
                    _fmt(series.reduce((a, b) => a > b ? a : b)),
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(double c) => c.toStringAsFixed(1);
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.values);

  final List<double> values;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;

    var min = values.first;
    var max = values.first;
    for (final v in values) {
      if (v < min) min = v;
      if (v > max) max = v;
    }
    // A dead-flat series would divide by zero; give it a small band so the
    // line lands mid-height instead of collapsing onto the baseline.
    if (max - min < 0.1) {
      final mid = (max + min) / 2;
      min = mid - 0.05;
      max = mid + 0.05;
    }

    double x(int i) => size.width * i / (values.length - 1);
    double y(double v) => size.height * (1 - (v - min) / (max - min));

    final path = Path()..moveTo(x(0), y(values.first));
    for (var i = 1; i < values.length; i++) {
      path.lineTo(x(i), y(values[i]));
    }

    final fill = Path.from(path)
      ..lineTo(x(values.length - 1), size.height)
      ..lineTo(x(0), size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x330AA2C0), Color(0x000AA2C0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)),
    );

    canvas.drawPath(
      path,
      Paint()
        ..color = AkvaColors.water
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => old.values != values;
}
