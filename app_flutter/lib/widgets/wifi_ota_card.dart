// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../net/station_discovery.dart';
import '../ota/ota_controller.dart' show OtaPhase;
import '../ota/wifi_ota_controller.dart';
import '../strings.dart';
import '../theme.dart';

/// Firmware update card for a `--station` AkvaLink found on the LAN
/// (net/station_discovery.dart). Same "flash latest" flow as ota_card.dart's
/// BLE version, but the image is POSTed to the device's own `/ota` endpoint.
class WifiOtaCard extends StatelessWidget {
  const WifiOtaCard({super.key});

  @override
  Widget build(BuildContext context) {
    final discovery = context.watch<StationDiscoveryController>();
    final ota = context.watch<WifiOtaController>();
    final s = context.watch<Strings>();
    final found =
        discovery.phase == DiscoveryPhase.found && discovery.ip != null;

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
              found ? _deviceLine(s, ota) : s.otaFindFirst,
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
                onPressed: (!found || ota.isBusy)
                    ? null
                    : () => ota.flashLatestOverWifi(ip: discovery.ip!),
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
                label: Text(_buttonLabel(s, found, ota)),
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

  String _deviceLine(Strings s, WifiOtaController ota) {
    final latest = ota.latestTag != null ? s.latestLabel(ota.latestTag!) : '';
    return latest;
  }

  String _buttonLabel(Strings s, bool found, WifiOtaController ota) {
    if (ota.isBusy) return s.updating;
    if (!found) return s.findOnNetwork;
    final tag = ota.latestTag;
    return tag != null ? s.flashLatestTag(tag) : s.flashLatest;
  }
}
