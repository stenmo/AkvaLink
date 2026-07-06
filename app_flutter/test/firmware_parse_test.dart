// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:akvalink/ble/akvalink_controller.dart';

void main() {
  group('firmware revision parsing', () {
    test('splits "0.3.1-thread" into version + variant', () {
      expect(AkvaLinkController.parseVersion('0.3.1-thread'), '0.3.1');
      expect(AkvaLinkController.parseVariant('0.3.1-thread'), 'thread');
    });

    test('handles the ble variant', () {
      expect(AkvaLinkController.parseVersion('0.3.1-ble'), '0.3.1');
      expect(AkvaLinkController.parseVariant('0.3.1-ble'), 'ble');
    });

    test('bare version (no variant suffix) returns null variant', () {
      expect(AkvaLinkController.parseVersion('0.3.1'), '0.3.1');
      expect(AkvaLinkController.parseVariant('0.3.1'), isNull);
    });

    test('null firmware yields null', () {
      expect(AkvaLinkController.parseVersion(null), isNull);
      expect(AkvaLinkController.parseVariant(null), isNull);
    });
  });
}
