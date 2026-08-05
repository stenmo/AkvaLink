// SPDX-License-Identifier: Apache-2.0
//
// WifiSetupScreen — provisions a fresh `--station` AkvaLink over BLE (see
// ble/prov_controller.dart), then locates it on the Wi-Fi network via mDNS
// (see net/station_discovery.dart) so the user can jump straight to its
// live temperature page.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ble/prov_controller.dart';
import '../net/station_discovery.dart';
import '../strings.dart';
import '../theme.dart';

class WifiSetupScreen extends StatelessWidget {
  const WifiSetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ProvController()),
        ChangeNotifierProvider(create: (_) => StationDiscoveryController()),
      ],
      child: const _WifiSetupView(),
    );
  }
}

class _WifiSetupView extends StatelessWidget {
  const _WifiSetupView();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Scaffold(
      appBar: AppBar(title: Text(s.wifiSetupTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: const _WifiSetupBody(),
            ),
          ),
        ),
      ),
    );
  }
}

class _WifiSetupBody extends StatelessWidget {
  const _WifiSetupBody();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final prov = context.watch<ProvController>();

    switch (prov.state) {
      case ProvConnState.idle:
        return _StartCard(s: s, prov: prov);
      case ProvConnState.scanning:
      case ProvConnState.connecting:
      case ProvConnState.sessionEstablishing:
        return _BusyCard(message: _statusText(s, prov.state));
      case ProvConnState.ready:
        return _NetworksCard(s: s, prov: prov);
      case ProvConnState.wifiScanning:
        return _BusyCard(message: s.provScanningNetworks);
      case ProvConnState.settingConfig:
        return _BusyCard(message: s.provSettingConfig);
      case ProvConnState.waitingResult:
        return _BusyCard(message: s.provWaitingResult);
      case ProvConnState.connectedToWifi:
        return const _ConnectedCard();
      case ProvConnState.error:
        return _ErrorCard(s: s, prov: prov);
    }
  }

  String _statusText(Strings s, ProvConnState state) => switch (state) {
    ProvConnState.scanning => s.scanning,
    ProvConnState.connecting => s.connecting,
    ProvConnState.sessionEstablishing => s.provSessionEstablishing,
    _ => '',
  };
}

class _StartCard extends StatelessWidget {
  const _StartCard({required this.s, required this.prov});
  final Strings s;
  final ProvController prov;

  // Connect, then roll straight into a Wi-Fi scan so the user lands on a
  // populated network list instead of an empty one needing a manual refresh.
  Future<void> _findAndScan() async {
    await prov.scanAndConnect();
    if (prov.state == ProvConnState.ready) {
      await prov.scanWifiNetworks();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              s.wifiSetupIntro,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AkvaColors.water,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _findAndScan,
                icon: const Icon(Icons.bluetooth_searching),
                label: Text(s.findSetupDevice),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BusyCard extends StatelessWidget {
  const _BusyCard({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Row(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 16),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

class _NetworksCard extends StatelessWidget {
  const _NetworksCard({required this.s, required this.prov});
  final Strings s;
  final ProvController prov;

  Future<void> _promptPassword(BuildContext context, String ssid) async {
    final controller = TextEditingController();
    var obscure = true;
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(s.passwordPromptFor(ssid)),
          content: TextField(
            controller: controller,
            obscureText: obscure,
            autofocus: true,
            decoration: InputDecoration(
              labelText: s.provPasswordLabel,
              suffixIcon: IconButton(
                icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => obscure = !obscure),
              ),
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(s.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: Text(s.provJoin),
            ),
          ],
        ),
      ),
    );
    if (password != null && context.mounted) {
      await prov.provision(ssid, password);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    s.provSelectNetwork,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: prov.scanWifiNetworks,
                ),
              ],
            ),
            if (prov.networks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(s.provNoNetworks),
              )
            else
              ...prov.networks.map(
                (n) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.wifi),
                  title: Text(n.ssid),
                  trailing: n.secure ? const Icon(Icons.lock, size: 16) : null,
                  onTap: () => _promptPassword(context, n.ssid),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ConnectedCard extends StatefulWidget {
  const _ConnectedCard();

  @override
  State<_ConnectedCard> createState() => _ConnectedCardState();
}

class _ConnectedCardState extends State<_ConnectedCard> {
  Timer? _pollTimer;
  double? _celsius;

  @override
  void initState() {
    super.initState();
    // Firmware's mDNS records need a moment to publish after joining — kick
    // off the browse in the background while the BLE-reported IP is shown.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<StationDiscoveryController>().discover();
    });
    // Read the live temperature straight from the device's own /temp JSON
    // endpoint (main/web_page.cpp) — no browser needed.
    _pollTemperature();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _pollTemperature(),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _pollTemperature() async {
    final ip = context.read<ProvController>().connectedIp;
    if (ip == null) return;
    try {
      final r = await http.get(Uri.parse('http://$ip/temp'));
      if (r.statusCode == 200 && mounted) {
        setState(() => _celsius = parseTempJson(r.body));
      }
    } catch (_) {
      // Transient (device still settling on the network) — next poll retries.
    }
  }

  Future<void> _open(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final prov = context.watch<ProvController>();
    final discovery = context.watch<StationDiscoveryController>();
    final ip = prov.connectedIp;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle, color: AkvaColors.ok),
                const SizedBox(width: 8),
                Text(
                  s.provJoined,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_celsius != null)
              Text(
                s.liveTemperature(_celsius!.toStringAsFixed(1)),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            const SizedBox(height: 4),
            if (ip != null)
              InkWell(
                onTap: () => _open('http://$ip/'),
                child: Text(
                  s.reachableAt('http://$ip/'),
                  style: const TextStyle(
                    color: AkvaColors.water,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            switch (discovery.phase) {
              DiscoveryPhase.idle ||
              DiscoveryPhase.resolving ||
              DiscoveryPhase.browsing => Text(
                s.provFindingOnLan,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              DiscoveryPhase.found => Text(
                s.foundOnLan(discovery.hostname ?? discovery.ip ?? ''),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              DiscoveryPhase.notFound || DiscoveryPhase.error => Text(
                s.provNotFoundOnLan,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            },
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  context.read<ProvController>().disconnect();
                  Navigator.of(context).pop();
                },
                child: Text(s.done),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.s, required this.prov});
  final Strings s;
  final ProvController prov;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${s.setupFailedPrefix}: ${prov.error}',
              style: const TextStyle(color: Colors.redAccent),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () async {
                  await prov.disconnect();
                },
                child: Text(s.tryAgain),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
