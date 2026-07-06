// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import '../theme.dart';

/// The water-gradient hero band, mirroring web/index.html's `header.hero`.
class HeroHeader extends StatelessWidget {
  const HeroHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 32),
      decoration: const BoxDecoration(gradient: kWaterGradient),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Text('🏊', style: TextStyle(fontSize: 30)),
                SizedBox(width: 8),
                Text(
                  'AkvaLink',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                SizedBox(width: 8),
                Text('🌊', style: TextStyle(fontSize: 26)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Battery-powered Matter pool & aquatic sensor',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.92),
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
