// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/akvalink_controller.dart';
import '../strings.dart';
import '../theme.dart';

/// The big live-temperature readout + connection controls. Mirrors the
/// `.live-card` on the web page: giant number, status line, connect button.
class TemperatureCard extends StatelessWidget {
  const TemperatureCard({super.key});

  String _ageString(BuildContext context, DateTime? t) {
    final s = context.read<Strings>();
    if (t == null) return '';
    final secs = DateTime.now().difference(t).inSeconds;
    if (secs < 2) return s.justNow;
    if (secs < 60) return s.secondsAgo(secs);
    return s.minutesAgo(secs ~/ 60);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AkvaLinkController>();
    final s = context.watch<Strings>();
    final connected = c.isConnected;
    final busy =
        c.state == AkvaConnState.scanning ||
        c.state == AkvaConnState.connecting;

    final tempText = c.temperatureC == null
        ? '––.–'
        : c.temperatureC!.toStringAsFixed(2);

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
        child: Column(
          children: [
            // --- Temperature readout ---
            RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: tempText,
                    style: TextStyle(
                      fontSize: 60,
                      fontWeight: FontWeight.w800,
                      height: 1,
                      color: connected
                          ? AkvaColors.water
                          : Theme.of(context).disabledColor,
                    ),
                  ),
                  TextSpan(
                    text: '  °C',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: AkvaColors.water2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // --- Status line ---
            _StatusLine(
              state: c.state,
              error: c.error,
              name: c.deviceName,
              scanningAll: c.isScanningAll,
            ),
            if (connected && c.lastUpdate != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  s.updatedAgo(_ageString(context, c.lastUpdate)),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),

            const SizedBox(height: 20),

            // --- Connect / disconnect button, or the fallback device picker
            // when the name/service scan found nothing exact. ---
            if (c.state == AkvaConnState.selecting)
              _DevicePicker(controller: c)
            else
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: connected
                        ? AkvaColors.muted
                        : AkvaColors.water,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: busy
                      ? null
                      : () {
                          if (connected) {
                            c.disconnect();
                          } else {
                            c.scanAndConnect();
                          }
                        },
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          connected
                              ? Icons.bluetooth_disabled
                              : Icons.bluetooth_searching,
                        ),
                  label: Text(
                    busy
                        ? (c.state == AkvaConnState.scanning
                              ? s.scanning
                              : s.connecting)
                        : connected
                        ? s.disconnect
                        : s.connect,
                  ),
                ),
              ),

            // --- Device chips (battery / firmware) ---
            if (connected) ...[
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (c.batteryPercent != null)
                    _InfoChip(
                      icon: Icons.battery_full,
                      label: '${c.batteryPercent}%',
                    ),
                  if (c.firmwareVersion != null)
                    _InfoChip(
                      icon: Icons.memory,
                      label: 'v${c.firmwareVersion}',
                    ),
                  if (c.variant != null)
                    _InfoChip(icon: Icons.hub, label: c.variant!),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.state,
    required this.error,
    required this.name,
    required this.scanningAll,
  });
  final AkvaConnState state;
  final String? error;
  final String name;
  final bool scanningAll;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    late final String text;
    late final Color color;
    switch (state) {
      case AkvaConnState.connected:
        text = s.connectedTo(name);
        color = AkvaColors.ok;
        break;
      case AkvaConnState.scanning:
        text = scanningAll ? s.lookingWider : s.lookingNearby;
        color = AkvaColors.muted;
        break;
      case AkvaConnState.connecting:
        text = s.connecting;
        color = AkvaColors.muted;
        break;
      case AkvaConnState.selecting:
        text = s.chooseDevice;
        color = AkvaColors.muted;
        break;
      case AkvaConnState.error:
        text = error ?? s.notConnected;
        color = Colors.redAccent;
        break;
      case AkvaConnState.idle:
        text = s.notConnected;
        color = AkvaColors.muted;
        break;
    }
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: color,
        fontWeight: state == AkvaConnState.connected ? FontWeight.w600 : null,
      ),
    );
  }
}

/// Shown when the name/service scan found nothing exact but other BLE
/// devices are nearby \u2014 lets the user pick one manually.
class _DevicePicker extends StatelessWidget {
  const _DevicePicker({required this.controller});
  final AkvaLinkController controller;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final devices = controller.discoveredDevices;
    return Column(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: devices.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final d = devices[i];
              return ListTile(
                dense: true,
                leading: const Icon(Icons.bluetooth, color: AkvaColors.water),
                title: Text(
                  d.name?.isNotEmpty == true ? d.name! : s.unknownDevice,
                ),
                trailing: Text(
                  '${d.rssi ?? '?'} dBm',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                onTap: () => controller.connectToDiscovered(d),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: controller.cancelSelecting,
          child: Text(s.cancel),
        ),
      ],
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AkvaColors.foam,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AkvaColors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: AkvaColors.deep),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: AkvaColors.deep,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
