// SPDX-License-Identifier: Apache-2.0
//
// AkvaLink companion app — iOS, Android, Windows, Linux, macOS.
// Same look & feel as the web landing page, focused on the two things that
// matter in the hand: live temperature and firmware updates over BLE.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'ble/akvalink_controller.dart';
import 'ota/ota_controller.dart';
import 'screens/home_screen.dart';
import 'strings.dart';
import 'theme.dart';

void main() {
  runApp(const AkvaLinkApp());
}

class AkvaLinkApp extends StatelessWidget {
  const AkvaLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Pick English or Swedish from the platform locale (matches the web page's
    // EN/SV split). Fixed at launch — no in-app language switcher by design.
    final strings = Strings.forLocale(
      WidgetsBinding.instance.platformDispatcher.locale,
    );

    return MultiProvider(
      providers: [
        Provider<Strings>.value(value: strings),
        ChangeNotifierProvider(
          create: (_) => AkvaLinkController(strings: strings),
        ),
        ChangeNotifierProvider(create: (_) => OtaController(strings: strings)),
      ],
      child: MaterialApp(
        title: 'AkvaLink',
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.system,
        home: const HomeScreen(),
      ),
    );
  }
}
