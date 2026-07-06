// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ota/ota_controller.dart';
import '../strings.dart';
import '../widgets/hero_header.dart';
import '../widgets/ota_card.dart';
import '../widgets/temperature_card.dart';

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
