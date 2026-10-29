import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../diagnostics.dart';
import '../src/rust/api/store.dart' as atomic;
import '../src/rust/frb_generated.dart';

/// The phone's own Atomic Data store (Rust `gamenight-store`, the same one
/// the GameNight host uses), holding this phone's player's settings and
/// progress per game. Phones only: the web app has none and keeps using
/// browser storage.
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
      instance = store;
    } catch (error) {
      Diagnostics.failure('Could not open the phone store: $error');
    }
  }

  /// Keep this player's settings for `game`.
  Future<void> saveSettings(String game, Map values) =>
      _store.setSettings(game: game, json: jsonEncode(values));

  /// This player's saved progress in `game`, with its revision.
  Future<({Object? data, int revision})?> progress(String game) async {
    final saved = await _store.progress(game: game);
    if (saved == null) return null;
    return (data: jsonDecode(saved.json), revision: saved.revision.toInt());
  }

  /// Keep this player's progress in `game`.
  Future<void> saveProgress(String game, Object? data, int revision) =>
      _store.setProgress(
          game: game, json: jsonEncode(data), revision: BigInt.from(revision));

  /// The phone's Atomic agent, which signs its changes.
  Future<String?> agent() => _store.agent();
}
