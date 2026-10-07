import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/link.dart';

void main() {
  test('reads the lobby room QR', () {
    final link = parseHostLink('http://192.168.0.85:7913/?r=ABC234');
    expect(link.base.toString(), 'http://192.168.0.85:7913');
    expect(link.roomCode, 'ABC234');
  });

  test('reads a character QR', () {
    final link = parseHostLink(
        'http://192.168.0.85:7913/studio?claim=7d0c1d59-8c51-4d2e-8f4d-1f7b8b4b5a10&link_revision=3');
    expect(link.claim, '7d0c1d59-8c51-4d2e-8f4d-1f7b8b4b5a10');
    expect(link.linkRevision, 3);
    expect(link.roomCode, isNull);
  });

  test('a bare address gets the default web port', () {
    expect(parseHostLink('192.168.1.20').base.toString(), 'http://192.168.1.20:7913');
    expect(parseHostLink('192.168.1.20:8000').base.port, 8000);
  });

  test('recognises hosted rooms and refuses other links', () {
    expect(parseHostLink('https://gamenight.ontola.io/?r=ABC234').hosted, isTrue);
    expect(() => parseHostLink('http://example.com/login'), throwsA(isA<LinkError>()));
    expect(() => parseHostLink('ftp://x'), throwsA(isA<LinkError>()));
  });

  test('room codes skip the ambiguous letters', () {
    expect(isRoomCode('ABC234'), isTrue);
    expect(isRoomCode('ABCIO1'), isFalse);
  });
}
