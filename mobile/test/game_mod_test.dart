import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/storage/phone_store.dart';

void main() {
  test('a mod reads back from the phone store with its changes', () {
    final mod = GameMod.fromJson({
      'id': 'neon-siege-warp-mod-1a2b3c4d',
      'title': 'Splitting bosses',
      'base': 'neon-siege-warp',
      'game': 'project-neon-siege-warp-mod-1a2b3c4d-865370577',
      'changes': [
        {'at': 1790000000, 'asked': 'bosses split', 'answer': 'Done', 'ok': true}
      ],
    });
    expect(mod.base, 'neon-siege-warp');
    expect(mod.changes.single.ok, isTrue);
    expect(mod.changes.single.at.toUtc().year, 2026);
  });
}
