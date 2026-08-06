// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:akvalink/app_version.dart';

void main() {
  test('kAppVersion matches pubspec.yaml version (catches drift)', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'could not find version: in pubspec.yaml');
    final pubspecVersion = match!.group(1)!.split('+').first;
    expect(
      kAppVersion,
      pubspecVersion,
      reason:
          'lib/app_version.dart kAppVersion is out of sync with pubspec.yaml — '
          'update both when bumping the app version.',
    );
  });
}
