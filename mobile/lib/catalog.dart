// The GameNight store catalog: every game the store lists, for browsing on
// the phone. Each game's full page lives on the website.
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:http/http.dart' as http;

/// Where the store and its game pages live.
final storeBase = Uri.parse('https://gamenight.ontola.io');

class CatalogGame {
  final String id;
  final String title;
  final String tagline;
  final String developer;
  final int? minPlayers;
  final int? maxPlayers;
  final int? bestPlayers;
  final String? price;
  final List<String> tags;

  /// The game's own colour, for a tile when it has no cover.
  final Color? color;

  /// A cover image on the web, when the catalog links one.
  final Uri? coverUrl;

  /// A cover image the catalog embeds as a `data:` URI, decoded once.
  final Uint8List? coverBytes;

  const CatalogGame({
    required this.id,
    required this.title,
    this.tagline = '',
    this.developer = '',
    this.minPlayers,
    this.maxPlayers,
    this.bestPlayers,
    this.price,
    this.tags = const [],
    this.color,
    this.coverUrl,
    this.coverBytes,
  });

  /// The game's page on the website.
  Uri get page => storeBase.replace(path: '/games/${Uri.encodeComponent(id)}');

  /// "2–4 players", "2 players", or "" when the catalog does not say.
  String get players {
    final min = minPlayers, max = maxPlayers;
    if (min == null && max == null) return '';
    if (min == null || max == null || min == max) {
      final n = max ?? min!;
      return n == 1 ? '1 player' : '$n players';
    }
    return '$min–$max players';
  }

  static CatalogGame? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], title = j['title'];
    if (id is! String || id.isEmpty || title is! String) return null;
    final players = j['players'] is Map ? j['players'] as Map : const {};
    int? count(Object? v) => v is num ? v.toInt() : null;
    final cover = j['cover'];
    Uri? coverUrl;
    Uint8List? coverBytes;
    if (cover is String && cover.isNotEmpty) {
      final uri = Uri.tryParse(cover);
      if (uri != null && uri.scheme == 'data') {
        try {
          coverBytes = uri.data?.contentAsBytes();
        } on FormatException {
          coverBytes = null;
        }
      } else if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
        coverUrl = uri;
      } else if (uri != null && !uri.hasScheme) {
        coverUrl = storeBase.resolveUri(uri);
      }
    }
    return CatalogGame(
      id: id,
      title: title,
      tagline: j['tagline'] is String ? j['tagline'] as String : '',
      developer: j['developer'] is String ? j['developer'] as String : '',
      minPlayers: count(players['min']),
      maxPlayers: count(players['max']),
      bestPlayers: count(players['best']),
      price: j['price']?.toString(),
      tags: j['tags'] is List ? [for (final t in j['tags'] as List) t.toString()] : const [],
      color: _color(j['color']),
      coverUrl: coverUrl,
      coverBytes: coverBytes,
    );
  }

  static Color? _color(Object? hex) {
    if (hex is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
    return Color(int.parse(hex.substring(1), radix: 16) | 0xFF000000);
  }
}

/// The games in a `GET /v1/catalog` answer, skipping entries that are not
/// games a party can pick (the lobby itself).
List<CatalogGame> parseCatalog(Object? json) {
  if (json is! List) throw const FormatException('The catalog is not a list.');
  return [
    for (final entry in json)
      if (CatalogGame.fromJson(entry) case final game? when !game.tags.contains('lobby')) game,
  ];
}

class CatalogError implements Exception {
  final String message;
  const CatalogError(this.message);
  @override
  String toString() => message;
}

/// Loads the store catalog once per app run.
class Catalog {
  /// The one the app uses; tests swap it for one with a fake client.
  static Catalog instance = Catalog();

  final Uri url;
  final http.Client? _client;
  Future<List<CatalogGame>>? _games;

  Catalog({Uri? url, http.Client? client})
      : url = url ?? storeBase.replace(path: '/v1/catalog'),
        _client = client;

  /// The catalog, from memory after the first successful load.
  /// A failed load is forgotten, so the next call tries again.
  Future<List<CatalogGame>> games() async {
    final pending = _games ??= _fetch();
    try {
      return await pending;
    } catch (_) {
      if (identical(_games, pending)) _games = null;
      rethrow;
    }
  }

  Future<List<CatalogGame>> _fetch() async {
    final client = _client ?? http.Client();
    try {
      final response = await client.get(url).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw const CatalogError('The store did not answer. Try again later.');
      }
      return parseCatalog(jsonDecode(utf8.decode(response.bodyBytes)));
    } on CatalogError {
      rethrow;
    } on FormatException {
      throw const CatalogError('The store sent something unexpected.');
    } catch (_) {
      throw const CatalogError('Could not reach the store. Check your internet connection.');
    } finally {
      if (_client == null) client.close();
    }
  }
}
