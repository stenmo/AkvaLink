// SPDX-License-Identifier: Apache-2.0
//
// AkvaLink colour palette + theme — mirrors web/index.html exactly so the
// native app and the landing page feel like one product.
import 'package:flutter/material.dart';

/// Brand colours lifted verbatim from `web/index.html` `:root`.
class AkvaColors {
  static const deep = Color(0xFF033F63); // headings, primary text on light
  static const water = Color(0xFF0AA2C0); // accent / buttons
  static const water2 = Color(0xFF28C2D6); // gradient partner
  static const foam = Color(0xFFEAF7FB); // light background
  static const ink = Color(0xFF16323F); // body text
  static const muted = Color(0xFF5B7280); // secondary text
  static const card = Color(0xFFFFFFFF); // card surface (light)
  static const line = Color(0xFFD9E6EC); // borders (light)
  static const ok = Color(0xFF1A9E6A); // connected / success

  // Dark theme partners (from the page's dark theme-color meta + tuned).
  static const deepDark = Color(0xFF061E29); // dark background
  static const cardDark = Color(0xFF0C2C3A); // dark card surface
  static const lineDark = Color(0xFF1C3D4C); // dark borders
  static const inkDark = Color(0xFFE7F3F8); // dark body text
}

/// Water gradient used on the hero + primary buttons.
const kWaterGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [AkvaColors.deep, AkvaColors.water],
);

ThemeData buildLightTheme() {
  final base = ThemeData.light(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AkvaColors.foam,
    colorScheme: base.colorScheme.copyWith(
      primary: AkvaColors.water,
      secondary: AkvaColors.water2,
      surface: AkvaColors.card,
      onSurface: AkvaColors.ink,
    ),
    cardTheme: const CardThemeData(
      color: AkvaColors.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: AkvaColors.line),
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
    textTheme: _textTheme(AkvaColors.ink, AkvaColors.muted),
    dividerColor: AkvaColors.line,
  );
}

ThemeData buildDarkTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AkvaColors.deepDark,
    colorScheme: base.colorScheme.copyWith(
      primary: AkvaColors.water2,
      secondary: AkvaColors.water,
      surface: AkvaColors.cardDark,
      onSurface: AkvaColors.inkDark,
    ),
    cardTheme: const CardThemeData(
      color: AkvaColors.cardDark,
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: AkvaColors.lineDark),
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
    textTheme: _textTheme(AkvaColors.inkDark, const Color(0xFF8FB0BE)),
    dividerColor: AkvaColors.lineDark,
  );
}

TextTheme _textTheme(Color ink, Color muted) {
  const family = 'system'; // uses the platform default (SF/Roboto/Segoe)
  return TextTheme(
    displayLarge: TextStyle(
      fontFamily: family,
      color: ink,
      fontWeight: FontWeight.w800,
      letterSpacing: -1,
    ),
    titleLarge: TextStyle(color: ink, fontWeight: FontWeight.w700),
    titleMedium: TextStyle(color: ink, fontWeight: FontWeight.w600),
    bodyMedium: TextStyle(color: ink),
    bodySmall: TextStyle(color: muted),
    labelLarge: const TextStyle(fontWeight: FontWeight.w600),
  );
}
