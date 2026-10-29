import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account.dart';
import '../diagnostics.dart';
import '../src/rust/api/store.dart' as atomic;
import '../src/rust/frb_generated.dart';

/// The phone's own Atomic Data store (Rust `gamenight-store`, the same one
/// the GameNight host uses), holding this phone's player's settings and
/// progress per game. Phones only: the web app has none and keeps using
/// browser storage.
///
/// Signed in, the records live in the account's drive on the cloud's Atomic
/// hub ([connect]) and sync with it: after each save and when the app opens,
/// so values changed on a host show up here and the other way round.
///
/// The app still reads settings synchronously from SharedPreferences; this
/// store is where they are kept for good. At startup its values replace the
/// preferences copy (or, the first time, the preferences move in), and every
/// save goes to both.
class PhoneStore {
  PhoneStore._(this._store);
  final atomic.PhoneStore _store;

  static PhoneStore? instance;
  static const settingsKey = 'my_game_settings';

  /// The account drive this phone syncs: owner, drive and hub URL.
  static const accountKey = 'atomic_account';
  SharedPreferences? _prefs;
  Timer? _soon;

  /// Open the store and line the preferences copy up with it. Never throws:
  /// without a store the app works as before.
  static Future<void> start(SharedPreferences prefs) async {
    if (kIsWeb) return;
    try {
      await RustLib.init();
      final dir = await getApplicationSupportDirectory();
      final store = PhoneStore._(
          await atomic.PhoneStore.open(dir: '${dir.path}/gamenight-store'));
      final saved = jsonDecode(await store._store.allSettings());
      if (saved is Map && saved.isNotEmpty) {
        await prefs.setString(settingsKey, jsonEncode(saved));
      } else {
        final cached = jsonDecode(prefs.getString(settingsKey) ?? '{}');
        if (cached is Map) {
          for (final MapEntry(:key, :value) in cached.entries) {
            if (value is Map) await store.saveSettings('$key', value);
          }
        }
      }
      store._prefs = prefs;
      final account = store._account;
      if (account != null) {
        await store._store.useAccount(owner: account['owner']);
        await store._copySettings();
        unawaited(store.syncNow());
      }
      instance = store;
    } catch (error) {
      Diagnostics.failure('Could not open the phone store: $error');
    }
  }

  Map<String, String>? get _account {
    final raw = _prefs?.getString(accountKey);
    if (raw == null) return null;
    final value = jsonDecode(raw);
    return value is Map ? value.cast<String, String>() : null;
  }

  /// The preferences copy the app reads settings from follows the store.
  Future<void> _copySettings() async {
    final saved = jsonDecode(await _store.allSettings());
    if (saved is Map) await _prefs?.setString(settingsKey, jsonEncode(saved));
  }

  /// After signing in: register this phone's agent with the account and
  /// keep the player's records in the account's drive from now on.
  Future<void> connect(CloudApi cloud) async {
    if (!cloud.signedIn) return;
    try {
      final agent = await _store.agent();
      if (agent == null) return;
      final reply =
          await cloud.request('POST', '/v1/me/atomic-device', body: {
        'agent': agent,
      }) as Map;
      final base = cloud.base;
      final url = base
          .replace(
              scheme: base.scheme == 'http' ? 'ws' : 'wss',
              path: reply['path'] as String)
          .toString();
      final owner = reply['owner'] as String;
      final drive = reply['drive'] as String;
      await _store.linkAccount(url: url, owner: owner, drive: drive);
      await _prefs?.setString(
          accountKey, jsonEncode({'owner': owner, 'drive': drive, 'url': url}));
      await _copySettings();
    } catch (error) {
      Diagnostics.failure('Could not connect the phone store: $error');
    }
  }

  /// Signed out: the phone's own player again, nothing syncs.
  Future<void> signOut() async {
    _soon?.cancel();
    await _prefs?.remove(accountKey);
    await _store.useAccount(owner: null);
    await _copySettings();
  }

  /// Sync with the account's drive now. True when something came in.
  Future<bool> syncNow() async {
    final account = _account;
    if (account == null) return false;
    try {
      final changed = await _store.sync_(url: account['url']!);
      if (changed) await _copySettings();
      return changed;
    } catch (error) {
      debugPrint('Phone store sync failed: $error');
      return false;
    }
  }

  void _syncSoon() {
    _soon?.cancel();
    _soon = Timer(const Duration(seconds: 2), () => unawaited(syncNow()));
  }

  /// Keep this player's settings for `game`.
  Future<void> saveSettings(String game, Map values) async {
    await _store.setSettings(game: game, json: jsonEncode(values));
    _syncSoon();
  }

  /// This player's saved progress in `game`, with its revision.
  Future<({Object? data, int revision})?> progress(String game) async {
    final saved = await _store.progress(game: game);
    if (saved == null) return null;
    return (data: jsonDecode(saved.json), revision: saved.revision.toInt());
  }

  /// Keep this player's progress in `game`.
  Future<void> saveProgress(String game, Object? data, int revision) async {
    await _store.setProgress(
        game: game, json: jsonEncode(data), revision: BigInt.from(revision));
    _syncSoon();
  }

  /// The phone's Atomic agent, which signs its changes.
  Future<String?> agent() => _store.agent();
}
