// The GameNight store catalog: every game the store lists, with the same
// videos, screenshots and facts as its page on the website.
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:http/http.dart' as http;

/// Where the store and its game pages live.
final storeBase = Uri.parse('https://gamenight.ontola.io');

/// An image the catalog links, or embeds as a `data:` URI.
class CatalogImage {
  final Uri? url;
  final Uint8List? bytes;
  const CatalogImage({this.url, this.bytes});

  /// Accepts what the website's `safeImage` accepts: https, http, a path on
  /// the store, or an embedded image.
  static CatalogImage? parse(Object? value) {
    if (value is! String || value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    if (uri.scheme == 'data') {
      try {
        final bytes = uri.data?.contentAsBytes();
        return bytes == null ? null : CatalogImage(bytes: bytes);
      } on FormatException {
        return null;
      }
    }
    if (uri.scheme == 'https' || uri.scheme == 'http') return CatalogImage(url: uri);
    if (!uri.hasScheme && value.startsWith('/')) return CatalogImage(url: storeBase.resolveUri(uri));
    return null;
  }
}

enum MediaKind { image, video, trailer }

/// One slide of a game's gallery: a screenshot, a video or a trailer link.
class CatalogMedia {
  final MediaKind kind;
  final Uri? url;
  final CatalogImage? image;
  final CatalogImage? poster;
  final String label;

  /// A short looping gameplay clip, shown first and played muted.
  final bool preview;

  const CatalogMedia(
      {required this.kind, this.url, this.image, this.poster, this.label = '', this.preview = false});

  static CatalogMedia? fromJson(Object? j) {
    if (j is! Map) return null;
    final label = j['label'] is String ? j['label'] as String : '';
    switch (j['kind']) {
      case 'image':
        final image = CatalogImage.parse(j['url']);
        return image == null ? null : CatalogMedia(kind: MediaKind.image, image: image, label: label);
      case 'video':
      case 'trailer':
        final url = Uri.tryParse(j['url'] is String ? j['url'] as String : '');
        if (url == null || url.scheme != 'https') return null;
        return CatalogMedia(
            kind: j['kind'] == 'video' ? MediaKind.video : MediaKind.trailer,
            url: url,
            poster: CatalogImage.parse(j['poster']),
            label: label,
            preview: j['preview'] == true);
    }
    return null;
  }
}

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

  final CatalogImage? icon;

  /// Videos first, then screenshots, as on the website's game page.
  final List<CatalogMedia> media;

  /// Where the gameplay footage comes from, when it is not the game's own.
  final Uri? mediaSource;

  /// "windows", "mac", "linux"; empty when unknown.
  final List<String> platforms;

  /// Named links such as homepage, itch or steam.
  final Map<String, Uri> links;

  final int? matchMinutes;

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
    this.icon,
    this.media = const [],
    this.mediaSource,
    this.platforms = const [],
    this.links = const {},
    this.matchMinutes,
  });

  bool get free => price == null || price == 'free';

  /// "Free", or "Paid" (the store shows real prices on the seller's page).
  String get priceLabel => free ? 'Free' : 'Paid';

  String get platformLabel => platforms.isEmpty
      ? 'Platform not listed'
      : platforms
          .map((p) => const {'mac': 'macOS', 'windows': 'Windows', 'linux': 'Linux'}[p] ?? p)
          .join(' · ');

  /// Where to buy a paid game, like the website's "View price & buy".
  Uri? get storeLink => links['steam'] ?? links['itch'] ?? links['homepage'];

  /// Other games sharing the most tags, best match first.
  List<CatalogGame> similar(List<CatalogGame> all, {int count = 6}) {
    final scored = [
      for (final g in all)
        if (g.id != id) (g, g.tags.where(tags.contains).length)
    ]..removeWhere((e) => e.$2 == 0);
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final e in scored.take(count)) e.$1];
  }

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
    final mediaJson = j['media'] is Map ? j['media'] as Map : const {};
    if (coverUrl == null && coverBytes == null) {
      final fallback = CatalogImage.parse(mediaJson['cover']);
      coverUrl = fallback?.url;
      coverBytes = fallback?.bytes;
    }
    final media = <CatalogMedia>[
      if (mediaJson['items'] is List)
        for (final item in mediaJson['items'] as List)
          if (CatalogMedia.fromJson(item) case final m?) m,
    ];
    if (CatalogImage.parse(j['screenshot']) case final shot?) {
      media.add(CatalogMedia(kind: MediaKind.image, image: shot, label: 'Gameplay screenshot'));
    }
    if (media.isEmpty && (coverUrl != null || coverBytes != null)) {
      media.add(CatalogMedia(
          kind: MediaKind.image,
          image: CatalogImage(url: coverUrl, bytes: coverBytes),
          label: 'Game artwork'));
    }
    // Looping previews first, then other videos and trailers, then images.
    int rank(CatalogMedia m) => m.preview ? 0 : (m.kind == MediaKind.image ? 2 : 1);
    final seen = <String>{};
    final unique = [
      for (final m in media)
        if (m.url == null || seen.add(m.url.toString())) m
    ];
    final ordered = [
      for (final r in [0, 1, 2]) ...unique.where((m) => rank(m) == r)
    ];
    final links = <String, Uri>{};
    if (j['links'] is Map) {
      for (final MapEntry(:key, :value) in (j['links'] as Map).entries) {
        final url = value is String ? Uri.tryParse(value) : null;
        if (url != null && (url.scheme == 'https' || url.scheme == 'http')) {
          links[key.toString()] = url;
        }
      }
    }
    final source = Uri.tryParse(mediaJson['source'] is String ? mediaJson['source'] as String : '');
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
      icon: CatalogImage.parse(j['icon']),
      media: ordered,
      mediaSource: source != null && source.scheme == 'https' ? source : null,
      platforms: j['platforms'] is List
          ? [for (final p in j['platforms'] as List) p.toString()]
          : const [],
      links: links,
      matchMinutes: count(j['match_minutes']),
    );
  }

  static Color? _color(Object? hex) {
    if (hex is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
    return Color(int.parse(hex.substring(1), radix: 16) | 0xFF000000);
  }
}

/// Host implementation entries the website also hides from players.
const _hostOnly = {'lobby', 'demo-game'};

/// The games in a `GET /v1/catalog` answer, skipping entries that are not
/// games a party can pick (the lobby itself).
List<CatalogGame> parseCatalog(Object? json) {
  if (json is! List) throw const FormatException('The catalog is not a list.');
  return [
    for (final entry in json)
      if (CatalogGame.fromJson(entry) case final game?
          when !game.tags.contains('lobby') && !_hostOnly.contains(game.id))
        game,
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
