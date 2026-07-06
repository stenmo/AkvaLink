// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/akvalink_controller.dart';
import '../ota/ota_controller.dart';
import '../strings.dart';
import '../theme.dart';

/// Firmware update card. When connected, offers a one-click "flash latest"
/// that auto-selects the GitHub release asset matching the device's variant.
class OtaCard extends StatelessWidget {
  const OtaCard({super.key});

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<AkvaLinkController>();
    final ota = context.watch<OtaController>();
    final s = context.watch<Strings>();
    final connected = ble.isConnected;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.system_update, color: AkvaColors.deep),
                const SizedBox(width: 8),
                Text(
                  s.firmwareUpdate,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              connected ? _deviceLine(s, ble, ota) : s.otaConnectFirst,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),

            // Progress bar (only during / after an update).
            if (ota.phase != OtaPhase.idle) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value:
                      ota.phase == OtaPhase.uploading ||
                          ota.phase == OtaPhase.done
                      ? ota.progress
                      : null,
                  minHeight: 8,
                  backgroundColor: AkvaColors.foam,
                  valueColor: const AlwaysStoppedAnimation(AkvaColors.water),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                ota.message,
                style: TextStyle(
                  color: ota.phase == OtaPhase.failed
                      ? Colors.redAccent
                      : ota.phase == OtaPhase.done
                      ? AkvaColors.ok
                      : AkvaColors.muted,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (ota.throughputKbps != null && ota.phase == OtaPhase.uploading)
                Text(
                  '${ota.throughputKbps!.toStringAsFixed(0)} kB/s',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 12),
            ],

            // Flash-latest button.
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AkvaColors.water,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: (!connected || ota.isBusy || ble.variant == null)
                    ? null
                    : () => ota.flashLatest(
                        deviceId: ble.deviceId!,
                        variant: ble.variant!,
                      ),
                icon: ota.isBusy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.cloud_download),
                label: Text(_buttonLabel(s, ble, ota)),
              ),
            ),
            if (ota.phase == OtaPhase.done || ota.phase == OtaPhase.failed)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: ota.reset, child: Text(s.dismiss)),
              ),
          ],
        ),
      ),
    );
  }

  String _deviceLine(Strings s, AkvaLinkController ble, OtaController ota) {
    final onDevice = ble.firmwareVersion != null
        ? s.onDevice(ble.firmwareVersion!)
        : '';
    final latest = ota.latestTag != null
        ? '  ·  ${s.latestLabel(ota.latestTag!)}'
        : '';
    final variant = ble.variant != null ? ' (${ble.variant})' : '';
    return '$onDevice$variant$latest';
  }

  String _buttonLabel(Strings s, AkvaLinkController ble, OtaController ota) {
    if (ota.isBusy) return s.updating;
    if (!ble.isConnected) return s.connectFirst;
    final tag = ota.latestTag;
    return tag != null ? s.flashLatestTag(tag) : s.flashLatest;
  }
}
