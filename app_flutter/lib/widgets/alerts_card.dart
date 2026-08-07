// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../ble/akvalink_controller.dart';
import '../strings.dart';
import '../theme.dart';

/// High/low temperature thresholds, stored in the sensor's own NVS over the
/// custom AkvaLink GATT service. Hidden unless the connected device exposes
/// them (non-BLE variants and firmware older than v0.3.6 don't).
class AlertsCard extends StatefulWidget {
  const AlertsCard({super.key});

  @override
  State<AlertsCard> createState() => _AlertsCardState();
}

class _AlertsCardState extends State<AlertsCard> {
  final _highCtrl = TextEditingController();
  final _lowCtrl = TextEditingController();

  /// Thresholds last pushed into the fields, so a rebuild (or a temperature
  /// notification) doesn't clobber what the user is part-way through typing.
  double? _syncedHigh;
  double? _syncedLow;
  bool _synced = false;

  String? _message;
  bool _failed = false;
  bool _saving = false;

  @override
  void dispose() {
    _highCtrl.dispose();
    _lowCtrl.dispose();
    super.dispose();
  }

  static String _fmt(double? c) => c == null ? '' : _trim(c);

  /// 30.0 -> "30", 29.5 -> "29.5", -2.5 -> "-2.5" (the device stores 0.01 °C).
  static String _trim(double c) {
    var s = c.toStringAsFixed(2);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '');
      s = s.replaceAll(RegExp(r'\.$'), '');
    }
    return s;
  }

  void _syncFromDevice(AkvaLinkController ble) {
    if (_synced &&
        _syncedHigh == ble.alertHighC &&
        _syncedLow == ble.alertLowC) {
      return;
    }
    _syncedHigh = ble.alertHighC;
    _syncedLow = ble.alertLowC;
    _synced = true;
    _highCtrl.text = _fmt(_syncedHigh);
    _lowCtrl.text = _fmt(_syncedLow);
  }

  /// Empty field = threshold disabled. Returns a (ok, value) pair because
  /// "valid and disabled" and "invalid" both need to be distinguishable.
  static (bool, double?) _parse(String raw) {
    final t = raw.trim().replaceAll(',', '.');
    if (t.isEmpty) return (true, null);
    final v = double.tryParse(t);
    if (v == null || v < -55 || v > 125) return (false, null);
    return (true, v);
  }

  Future<void> _save(AkvaLinkController ble, Strings s) async {
    final (highOk, high) = _parse(_highCtrl.text);
    final (lowOk, low) = _parse(_lowCtrl.text);
    if (!highOk || !lowOk) {
      setState(() {
        _failed = true;
        _message = s.alertRangeError;
      });
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    final ok = await ble.setAlerts(highC: high, lowC: low);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _failed = !ok;
      _message = ok ? s.alertSaved : s.alertSaveFailed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<AkvaLinkController>();
    final s = context.watch<Strings>();

    if (!ble.isConnected || !ble.alertsSupported) {
      return const SizedBox.shrink();
    }
    _syncFromDevice(ble);

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
                  const Icon(
                    Icons.notifications_active,
                    color: AkvaColors.deep,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    s.alertsTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(s.alertsHint, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: _field(_highCtrl, s.alertHighLabel)),
                  const SizedBox(width: 12),
                  Expanded(child: _field(_lowCtrl, s.alertLowLabel)),
                ],
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _saving ? null : () => _save(ble, s),
                  child: Text(s.alertSave),
                ),
              ),
              if (_message != null) ...[
                const SizedBox(height: 10),
                Text(
                  _message!,
                  style: TextStyle(
                    color: _failed ? Colors.redAccent : AkvaColors.ok,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label) => TextField(
    controller: ctrl,
    keyboardType: const TextInputType.numberWithOptions(
      decimal: true,
      signed: true,
    ),
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-]'))],
    decoration: InputDecoration(
      labelText: label,
      suffixText: '°C',
      border: const OutlineInputBorder(),
      isDense: true,
    ),
  );
}
