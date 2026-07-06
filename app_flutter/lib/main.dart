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
import 'theme.dart';

void main() {
  runApp(const AkvaLinkApp());
}

class AkvaLinkApp extends StatelessWidget {
  const AkvaLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AkvaLinkController()),
        ChangeNotifierProvider(create: (_) => OtaController()),
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
