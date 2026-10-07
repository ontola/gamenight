import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/avatar.dart';

void main() {
  test('encodes the v1 wire format the protocol crate reads', () {
    final face = emptyFace()..[0] = '#ff0000';
    final json = jsonDecode(encodeAvatar(face)) as Map;
    expect(json['v'], 1);
    expect(json['w'], 48);
    expect(json['h'], 48);
    expect((json['px'] as List).length, 48 * 48);
    expect(decodeAvatar(encodeAvatar(face)), face);
  });

  test('centres legacy 16px drawings like the web studio', () {
    final legacy = List<String?>.filled(256, '#0f172a')..[0] = '#123456';
    final face = decodeAvatar(jsonEncode(legacy))!;
    expect(face[23 * 48 + 22], '#123456');
    expect(face.where((c) => c != null).length, 1);
  });

  test('rejects malformed avatars', () {
    expect(decodeAvatar('nope'), isNull);
    expect(decodeAvatar(jsonEncode({'v': 1, 'w': 300, 'h': 1, 'px': []})), isNull);
  });

  test('random faces have features and differ from the last one', () {
    final rng = Random(4);
    final a = randomFace(rng), b = randomFace(rng);
    expect(a.where((c) => c != null), isNotEmpty);
    expect(a, isNot(equals(b)));
  });

  test('flood fill stops at other colours', () {
    final face = emptyFace();
    for (var x = 0; x < 48; x++) {
      face[10 * 48 + x] = '#000000';
    }
    floodFill(face, 0, '#ffffff');
    expect(face[9 * 48 + 47], '#ffffff');
    expect(face[11 * 48], isNull);
  });
}
