// SPDX-License-Identifier: Apache-2.0
//
// StationDiscoveryController — finds a `--station`/`--ap` AkvaLink's HTTP
// temperature page on the LAN via mDNS (Bonjour/Avahi). A station's IP can
// change on DHCP renewal but its mDNS hostname does not, so this is the
// stable way to reconnect after the very first session (see ProvController,
// whose BLE-reported IP is only good for that first connection).
//
// Matches main/station_web.cpp: hostname "akvalink-<last4ofmac>.local",
// mDNS instance name "AkvaLink temperature", service `_http._tcp`.
//
// Flow: try resolving a remembered hostname directly (fast path, works after
// the very first successful discovery); if that fails, browse every
// `_http._tcp` service on the LAN and pick the one whose instance name is
// ours, remembering its hostname for next time.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';
import 'package:shared_preferences/shared_preferences.dart';

const kStationServiceType = '_http._tcp.local';
const kStationInstanceName = 'AkvaLink temperature';
const _kPrefsHostnameKey = 'station_mdns_hostname';

// Android drops incoming Wi-Fi multicast packets unless this lock is held —
// see MainActivity.kt. No-op (and safe to call) on every other platform.
const _multicastLockChannel = MethodChannel('akvalink/multicast_lock');

Future<void> _acquireMulticastLock() async {
  if (!Platform.isAndroid) return;
  try {
    await _multicastLockChannel.invokeMethod('acquire');
  } catch (_) {
    // Best-effort — discovery still runs without it, just less reliably.
  }
}

Future<void> _releaseMulticastLock() async {
  if (!Platform.isAndroid) return;
  try {
    await _multicastLockChannel.invokeMethod('release');
  } catch (_) {}
}

/// True if an mDNS PTR record's instance domain name is an AkvaLink station.
/// e.g. "AkvaLink temperature._http._tcp.local" -> true. Broken out as a pure
/// function so the matching rule can be unit-tested without real mDNS I/O.
bool matchesStationInstance(String ptrDomainName) =>
    ptrDomainName.startsWith(kStationInstanceName);

/// Parses the `{"celsius": 28.4}` (or `{"celsius": null}`) body of
/// main/web_page.cpp's `/temp` endpoint. Returns null on no reading yet or
/// on a malformed body.
double? parseTempJson(String body) {
  try {
    final json = jsonDecode(body) as Map<String, dynamic>;
    final c = json['celsius'];
    return c == null ? null : (c as num).toDouble();
  } catch (_) {
    return null;
  }
}

enum DiscoveryPhase { idle, resolving, browsing, found, notFound, error }

class StationDiscoveryController extends ChangeNotifier {
  StationDiscoveryController({http.Client? httpClient})
    : _client = httpClient ?? http.Client();

  final http.Client _client;
  SharedPreferences? _prefs;

  DiscoveryPhase _phase = DiscoveryPhase.idle;
  DiscoveryPhase get phase => _phase;

  String? _error;
  String? get error => _error;

  String? _hostname; // e.g. "akvalink-5f884c.local"
  String? get hostname => _hostname;

  String? _ip;
  String? get ip => _ip;

  void _set(DiscoveryPhase p, {String? error}) {
    _phase = p;
    _error = error;
    notifyListeners();
  }

  Future<SharedPreferences> _prefsInstance() async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Remember a hostname learned some other way (e.g. straight after BLE
  /// provisioning) so the next launch can resolve it directly.
  Future<void> rememberHostname(String hostname) async {
    final p = await _prefsInstance();
    await p.setString(_kPrefsHostnameKey, hostname);
  }

  /// Find the station's current IP on the LAN. Tries a remembered hostname
  /// first, then falls back to a full `_http._tcp` browse.
  ///
  /// Note: the firmware's mDNS instance name is fixed ("AkvaLink temperature"),
  /// not per-device, so with more than one station on the same LAN this picks
  /// whichever responds first — good enough for the common single-device case.
  Future<void> discover({Duration timeout = const Duration(seconds: 6)}) async {
    _set(DiscoveryPhase.resolving);
    final prefs = await _prefsInstance();
    final remembered = prefs.getString(_kPrefsHostnameKey);

    final client = MDnsClient();
    await _acquireMulticastLock();
    try {
      await client.start();

      if (remembered != null) {
        final ip = await _resolveHostname(client, remembered, timeout);
        if (ip != null) {
          _hostname = remembered;
          _ip = ip;
          _set(DiscoveryPhase.found);
          return;
        }
      }

      _set(DiscoveryPhase.browsing);
      final found = await _browseForStation(client, timeout);
      if (found == null) {
        _set(
          DiscoveryPhase.notFound,
          error: 'No AkvaLink found on this network',
        );
        return;
      }
      _hostname = found.hostname;
      _ip = found.ip;
      await prefs.setString(_kPrefsHostnameKey, found.hostname);
      _set(DiscoveryPhase.found);
    } catch (e) {
      _set(DiscoveryPhase.error, error: 'mDNS discovery failed: $e');
    } finally {
      client.stop();
      await _releaseMulticastLock();
    }
  }

  Future<String?> _resolveHostname(
    MDnsClient client,
    String hostname,
    Duration timeout,
  ) async {
    await for (final rec in client.lookup<IPAddressResourceRecord>(
      ResourceRecordQuery.addressIPv4(hostname),
      timeout: timeout,
    )) {
      return rec.address.address;
    }
    return null;
  }

  Future<_StationLocation?> _browseForStation(
    MDnsClient client,
    Duration timeout,
  ) async {
    await for (final ptr in client.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer(kStationServiceType),
      timeout: timeout,
    )) {
      if (!matchesStationInstance(ptr.domainName)) continue;
      await for (final srv in client.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(ptr.domainName),
        timeout: timeout,
      )) {
        await for (final ip in client.lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(srv.target),
          timeout: timeout,
        )) {
          return _StationLocation(hostname: srv.target, ip: ip.address.address);
        }
      }
    }
    return null;
  }

  /// Fetch the live reading from the discovered station's `/temp` JSON
  /// endpoint (main/web_page.cpp) — no HTML parsing needed.
  Future<double?> fetchTemperature() async {
    final ip = _ip;
    if (ip == null) return null;
    final r = await _client.get(Uri.parse('http://$ip/temp'));
    if (r.statusCode != 200) return null;
    return parseTempJson(r.body);
  }

  Future<void> forget() async {
    final p = await _prefsInstance();
    await p.remove(_kPrefsHostnameKey);
    _hostname = null;
    _ip = null;
    _set(DiscoveryPhase.idle);
  }
}

class _StationLocation {
  const _StationLocation({required this.hostname, required this.ip});
  final String hostname;
  final String ip;
}
