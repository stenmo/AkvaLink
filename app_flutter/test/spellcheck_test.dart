// SPDX-License-Identifier: Apache-2.0
//
// Spell-check for every user-facing string, in English and Swedish.
//
// Strategy: tokenise all strings from `Strings.debugAllStrings()` and assert
// each word appears in a hand-curated dictionary of correctly-spelled words.
// The dictionary is deliberately maintained BY HAND (not derived from the
// strings), so a typo introduced later — "Firware", "Ansltu" — produces an
// unknown word and fails the test. Brand tokens, numbers and one-letter tokens
// are skipped.

import 'package:akvalink/strings.dart';
import 'package:flutter_test/flutter_test.dart';

/// Brand / technical tokens that are intentionally not "real words".
const _brand = {
  'akvalink',
  'matter',
  'bluetooth',
  'firmware',
  'ota',
  'ble',
  'wifi',
  'thread',
  'station',
  'espnow',
  'blox',
  'ublox',
  'nora',
  'esp',
};

/// Correctly-spelled English words appearing in the UI.
const _englishDict = {
  'battery',
  'powered',
  'pool',
  'aquatic',
  'sensor',
  'connect',
  'over',
  'disconnect',
  'scanning',
  'connecting',
  'looking',
  'for',
  'an',
  'nearby',
  'not',
  'connected',
  'is',
  'turned',
  'off',
  'supported',
  'on',
  'this',
  'device',
  'unavailable',
  'no',
  'found',
  'just',
  'now',
  'update',
  'to',
  'its',
  'flash',
  'latest',
  'updating',
  'first',
  'dismiss',
  'local',
  'only',
  'cloud',
  'ever',
  'preparing',
  'erasing',
  'slot',
  'finalising',
  'sent',
  'rebooting',
  'into',
  'new',
  'failed',
  'reported',
  'error',
  'fetching',
  'updated',
  'ago',
  'uploading',
};

/// Correctly-spelled Swedish words appearing in the UI.
const _swedishDict = {
  'batteridriven',
  'för',
  'pool',
  'och',
  'akvarium',
  'sensor',
  'anslut',
  'via',
  'koppla',
  'från',
  'söker',
  'ansluter',
  'letar',
  'efter',
  'en',
  'närheten',
  'inte',
  'ansluten',
  'är',
  'avstängt',
  'stöds',
  'på',
  'den',
  'här',
  'enheten',
  'tillgängligt',
  'ingen',
  'hittades',
  'just',
  'nu',
  'uppdatera',
  'till',
  'att',
  'dess',
  'installera',
  'senaste',
  'uppdaterar',
  'först',
  'stäng',
  'endast',
  'lokal',
  'aldrig',
  'något',
  'moln',
  'förbereder',
  'raderar',
  'minnesbank',
  'slutför',
  'uppdatering',
  'skickad',
  'startar',
  'om',
  'med',
  'ny',
  'uppdateringen',
  'misslyckades',
  'rapporterade',
  'ett',
  'fel',
  'hämtar',
  'uppdaterad',
  'min',
  'sedan',
  'laddar',
  'upp',
};

/// Split a UI string into lowercase word tokens, dropping punctuation, digits,
/// symbols, emoji and one-letter tokens.
Iterable<String> _tokens(String s) {
  return s
      .toLowerCase()
      .split(RegExp(r'[\s\-·—…(),.:%&/]+'))
      .map((w) => w.replaceAll(RegExp(r'[^a-zåäö]'), ''))
      .where((w) => w.length >= 2);
}

void main() {
  test('English strings contain only correctly-spelled words', () {
    final dict = {..._englishDict, ..._brand};
    final unknown = <String>{};
    for (final line in Strings.en.debugAllStrings()) {
      for (final w in _tokens(line)) {
        if (!dict.contains(w)) unknown.add(w);
      }
    }
    expect(
      unknown,
      isEmpty,
      reason: 'Unknown English words (typo or add to dictionary): $unknown',
    );
  });

  test('Swedish strings contain only correctly-spelled words', () {
    final dict = {..._swedishDict, ..._brand};
    final unknown = <String>{};
    for (final line in Strings.sv.debugAllStrings()) {
      for (final w in _tokens(line)) {
        if (!dict.contains(w)) unknown.add(w);
      }
    }
    expect(
      unknown,
      isEmpty,
      reason: 'Unknown Swedish words (typo or add to dictionary): $unknown',
    );
  });

  test('EN and SV expose the same number of strings (key parity)', () {
    expect(
      Strings.en.debugAllStrings().length,
      Strings.sv.debugAllStrings().length,
    );
  });

  test('no string is empty, or has leading/trailing/double whitespace', () {
    for (final s in [Strings.en, Strings.sv]) {
      for (final line in s.debugAllStrings()) {
        expect(line.trim(), line, reason: 'stray edge whitespace: "$line"');
        expect(line.contains('  '), isFalse, reason: 'double space: "$line"');
        expect(line.isNotEmpty, isTrue);
      }
    }
  });

  test('common misspellings never appear (defense in depth)', () {
    const badFragments = [
      // English
      'recieve', 'seperate', 'occured', 'untill', 'sucess', 'conenct',
      'firware', 'availabe', 'temperatur ', 'bluetooh', 'updat ', 'plesae',
      // Swedish
      'ansltu', 'anslutna fel', 'firmvare', 'uppdatera ra', 'batteri driven',
    ];
    for (final s in [Strings.en, Strings.sv]) {
      final blob = s.debugAllStrings().join(' ').toLowerCase();
      for (final bad in badFragments) {
        expect(blob.contains(bad), isFalse, reason: 'found misspelling "$bad"');
      }
    }
  });

  test('parameterised helpers embed their argument', () {
    for (final s in [Strings.en, Strings.sv]) {
      expect(s.connectedTo('MyPool'), contains('MyPool'));
      expect(s.flashLatestTag('v9.9.9'), contains('v9.9.9'));
      expect(s.onDevice('9.9.9'), contains('9.9.9'));
      expect(s.otaFetchingFor('station'), contains('station'));
      expect(s.otaUploading(42), contains('42'));
    }
  });
}
