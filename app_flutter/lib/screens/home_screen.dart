// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ota/ota_controller.dart';
import '../strings.dart';
import '../theme.dart';
import '../widgets/hero_header.dart';
import '../widgets/ota_card.dart';
import '../widgets/temperature_card.dart';

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
  @override
  void initState() {
    super.initState();
    // Fetch the newest release tag once so the OTA button is labelled.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<OtaController>().refreshLatestTag();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const HeroHeader(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    children: const [
                      TemperatureCard(),
                      SizedBox(height: 16),
                      OtaCard(),
                      SizedBox(height: 20),
                      _FooterNote(),
                      SizedBox(height: 10),
                      _FooterLinks(),
                    ],
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
