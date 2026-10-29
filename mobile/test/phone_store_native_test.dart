import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/src/rust/api/store.dart';
import 'package:gamenight/src/rust/frb_generated.dart';

/// The phone's Atomic store, through the real Rust library. Build it first
/// (`cargo build --manifest-path rust/Cargo.toml`); skipped otherwise.
void main() {
  final library = File('rust/target/debug/libgamenight_phone.so');

  test('settings and progress survive reopening the store', () async {
    await RustLib.init(externalLibrary: ExternalLibrary.open(library.path));
    final dir = await Directory.systemTemp.createTemp('phone-store');
    var store = await PhoneStore.open(dir: dir.path);
    final agent = await store.agent();
    await store.setSettings(game: 'shooter', json: '{"sensitivity":180}');
    await store.setProgress(
        game: 'spellstorm', json: '{"spells":["fire"]}', revision: BigInt.two);
    store.dispose();

    store = await PhoneStore.open(dir: dir.path);
    expect(await store.agent(), agent);
    expect(await store.allSettings(), '{"shooter":{"sensitivity":180}}');
    final progress = await store.progress(game: 'spellstorm');
    expect(progress?.json, '{"spells":["fire"]}');
    expect(progress?.revision, BigInt.two);
    expect(await store.progress(game: 'hexstead'), isNull);
  }, skip: library.existsSync() ? false : 'native library not built');
}
