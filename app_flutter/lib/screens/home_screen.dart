// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../net/station_discovery.dart';
import '../ota/ota_controller.dart';
import '../ota/wifi_ota_controller.dart';
import '../strings.dart';
import '../theme.dart';
import '../widgets/hero_header.dart';
import '../widgets/ota_card.dart';
import '../widgets/temperature_card.dart';
import '../widgets/wifi_ota_card.dart';
import 'wifi_setup_screen.dart';

/// Same repo used everywhere else in this project (README badge, OTA update
/// checks, esphome package import) — see scripts/publish.py's REPO_SLUG.
const _websiteUrl = 'https://akvalink.com/';
const _githubUrl = 'https://github.com/stenmo/AkvaLink';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _scrollController = ScrollController();
  final _discovery = StationDiscoveryController();

  @override
  void initState() {
    super.initState();
    // Fetch the newest release tag once so the OTA buttons are labelled.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<OtaController>().refreshLatestTag();
      context.read<WifiOtaController>().refreshLatestTag();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _discovery.dispose();
    super.dispose();
  }

  Future<void> _openWifiSetup() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const WifiSetupScreen()));
    // Coming back from a scrolled-down entry point otherwise leaves the
    // temperature card half-hidden under the fixed header.
    if (mounted && _scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const HeroHeader(),
          Expanded(
            // HeroHeader already handles the top inset; this covers the
            // bottom nav bar / gesture inset so the footer isn't hidden under it.
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: ChangeNotifierProvider.value(
                      value: _discovery,
                      child: Column(
                        children: [
                          const TemperatureReadoutCard(),
                          const SizedBox(height: 16),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  children: [
                                    const BleConnectCard(),
                                    const SizedBox(height: 16),
                                    const OtaCard(),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  children: [
                                    const _LanDiscoveryCard(),
                                    const SizedBox(height: 16),
                                    const WifiOtaCard(),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _WifiSetupEntry(onTap: _openWifiSetup),
                          const SizedBox(height: 20),
                          const _FooterNote(),
                          const SizedBox(height: 10),
                          const _FooterLinks(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Entry point into BLE Wi-Fi provisioning for a fresh `--station` device
/// (ble/prov_controller.dart + net/station_discovery.dart).
class _WifiSetupEntry extends StatelessWidget {
  const _WifiSetupEntry({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Card(
      child: ListTile(
        leading: const Icon(Icons.wifi, color: AkvaColors.deep),
        title: Text(s.wifiSetupTitle),
        subtitle: Text(s.wifiSetupIntro),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// Manually re-run mDNS discovery to find an already-provisioned `--station`
/// AkvaLink on this Wi-Fi network (net/station_discovery.dart), without
/// going through BLE provisioning again.
class _LanDiscoveryCard extends StatelessWidget {
  const _LanDiscoveryCard();

  Future<void> _open(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    final discovery = context.watch<StationDiscoveryController>();
    final busy =
        discovery.phase == DiscoveryPhase.resolving ||
        discovery.phase == DiscoveryPhase.browsing;
    final notFound =
        discovery.phase == DiscoveryPhase.notFound ||
        discovery.phase == DiscoveryPhase.error;
    final found = discovery.phase == DiscoveryPhase.found;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.wifi_find, color: AkvaColors.deep),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s.findOnNetwork,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (found)
              Text(s.foundOnLan(discovery.hostname ?? discovery.ip ?? ''))
            else if (busy)
              Text(s.lanSearching)
            else if (notFound)
              Text(
                s.lanNotFoundHint,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              )
            else
              Text(s.lanDiscoverIntro),
            if (found && discovery.ip != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: InkWell(
                  onTap: () => _open('http://${discovery.ip}/'),
                  child: Text(
                    s.reachableAt('http://${discovery.ip}/'),
                    style: const TextStyle(
                      color: AkvaColors.water,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: busy ? null : () => discovery.discover(),
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_find),
                label: Text(found || notFound ? s.tryAgain : s.findOnNetwork),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FooterNote extends StatelessWidget {
  const _FooterNote();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Text(
      '${s.footerLocal}\n${s.footerHw}',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}

/// Website + GitHub links, mirroring the web page's own "View on GitHub" /
/// source links. Opens in the system browser via url_launcher.
class _FooterLinks extends StatelessWidget {
  const _FooterLinks();

  Future<void> _open(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Strings>();
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 4,
      children: [
        TextButton.icon(
          onPressed: () => _open(_websiteUrl),
          icon: const Icon(Icons.language, size: 16),
          label: Text(s.linkWebsite),
          style: TextButton.styleFrom(foregroundColor: AkvaColors.muted),
        ),
        TextButton.icon(
          onPressed: () => _open(_githubUrl),
          icon: const Icon(Icons.code, size: 16),
          label: Text(s.linkGithub),
          style: TextButton.styleFrom(foregroundColor: AkvaColors.muted),
        ),
      ],
    );
  }
}
