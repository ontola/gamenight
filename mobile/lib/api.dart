// HTTP client for the GameNight local web server.
//
// The app talks to exactly the endpoints the phone studio (web/studio.js and
// web/storage.js) uses, so it needs no host changes. The daemon's control
// port is never contacted: it is loopback-only and trusts every client.
import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiError implements Exception {
  final String message;
  final int? status;
  const ApiError(this.message, [this.status]);
  @override
  String toString() => message;
}

class Profile {
  final String id;
  final String username;
  final String skinColor;
  final String avatar;

  const Profile(
      {required this.id,
      required this.username,
      required this.skinColor,
      required this.avatar});

  Map<String, dynamic> toJson() =>
      {'id': id, 'username': username, 'skin_color': skinColor, 'avatar': avatar};

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
      id: j['id'] as String,
      username: j['username'] as String? ?? '',
      skinColor: j['skin_color'] as String? ?? '#f5e9be',
      avatar: j['avatar'] as String? ?? '');
}

/// `GET /api/profiles/:id/session`: where this phone stands in the party.
class SessionInfo {
  final bool linked;
  final String? playerId;
  final int linkRevision;
  final bool waiting;
  final bool remembered;
  final bool mainPlayer;
  final String? playerName;
  final int? seat;
  final int players;
  final String? currentTitle;
  final String? currentPhase;
  final String? next;

  const SessionInfo({
    this.linked = false,
    this.playerId,
    this.linkRevision = 0,
    this.waiting = false,
    this.remembered = false,
    this.mainPlayer = false,
    this.playerName,
    this.seat,
    this.players = 0,
    this.currentTitle,
    this.currentPhase,
    this.next,
  });

  factory SessionInfo.fromJson(Map<String, dynamic> j) {
    final current = j['current'] as Map<String, dynamic>?;
    return SessionInfo(
      linked: j['linked'] == true,
      playerId: j['player_id'] as String?,
      linkRevision: (j['link_revision'] as num?)?.toInt() ?? 0,
      waiting: j['waiting'] == true,
      remembered: j['remembered'] == true,
      mainPlayer: j['main_player'] == true,
      playerName: j['player_name'] as String?,
      seat: (j['seat'] as num?)?.toInt(),
      players: (j['players'] as num?)?.toInt() ?? 0,
      currentTitle: current?['title'] as String?,
      currentPhase: current?['phase']?.toString(),
      next: j['next'] as String?,
    );
  }
}

/// A game's own phone screen, offered while that game is being played.
/// A game's own phone app, offered next to or instead of its phone page.
class CompanionApp {
  final String name;

  /// Android package name, to see whether it is installed and open it.
  final String? android;

  /// Where to get the app: an APK on the GameNight computer or a store page.
  final String? download;
  const CompanionApp({required this.name, this.android, this.download});

  static CompanionApp? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = j['name'];
    if (name is! String) return null;
    return CompanionApp(
        name: name, android: j['android'] as String?, download: j['download'] as String?);
  }
}

class Companion {
  final String game;
  final String title;

  /// The phone page, when the game has one.
  final String? url;
  final CompanionApp? app;
  const Companion({required this.game, required this.title, this.url, this.app});

  static Companion? fromJson(Map<String, dynamic> j) {
    final game = j['game'] as String?;
    final url = j['url'] as String?;
    final app = CompanionApp.fromJson(j['app']);
    if (game == null || (url == null && app == null)) return null;
    return Companion(game: game, title: j['title'] as String? ?? game, url: url, app: app);
  }
}

class PlaylistEntry {
  final String game;
  final String title;
  final Map<String, dynamic> raw;
  PlaylistEntry(this.raw)
      : game = raw['game'] as String,
        title = raw['title'] as String? ?? raw['game'] as String;
}

/// `GET /api/playlist`. [snapshot] is sent back verbatim as `expected` so the
/// host can refuse an edit made against a stale queue.
class PlaylistView {
  final Map<String, dynamic> snapshot;
  final List<PlaylistEntry> entries;
  final int? current;
  final String? playing;
  final String? next;

  PlaylistView(Map<String, dynamic> j)
      : snapshot = j['playlist'] as Map<String, dynamic>,
        entries = ((j['playlist'] as Map)['entries'] as List)
            .map((e) => PlaylistEntry(e as Map<String, dynamic>))
            .toList(),
        current = ((j['playlist'] as Map)['current'] as num?)?.toInt(),
        playing = j['playing'] as String?,
        next = j['next'] as String?;
}

/// Result of `POST /api/profiles/:id/join`.
class JoinResult {
  final String status;
  final String? playerId;
  final int? seat;
  final String? message;
  JoinResult(Map<String, dynamic> j)
      : status = j['status'] as String,
        playerId = j['player_id'] as String?,
        seat = (j['seat'] as num?)?.toInt(),
        message = j['message'] as String?;
}

class GameNightApi {
  final Uri base;
  final http.Client _client;
  static const _timeout = Duration(seconds: 10);

  GameNightApi(this.base, {http.Client? client})
      : _client = client ?? http.Client();

  Uri _u(String path) {
    final relative = Uri.parse(path);
    return base.replace(path: relative.path, query: relative.hasQuery ? relative.query : null);
  }

  /// Absolute address of a page the host serves, such as a phone screen.
  /// Addresses elsewhere (a store page) are kept as they are.
  Uri resolve(String path) {
    final uri = Uri.parse(path);
    return uri.hasScheme ? uri : _u(path);
  }

  Future<dynamic> _send(String method, String path,
      {Object? body, String? failure}) async {
    final request = http.Request(method, _u(path));
    request.headers['Content-Type'] = 'application/json';
    request.headers['Cache-Control'] = 'no-store';
    if (body != null) request.body = jsonEncode(body);
    final http.Response response;
    try {
      response = await http.Response.fromStream(
          await _client.send(request).timeout(_timeout));
    } catch (_) {
      throw const ApiError(
          'GameNight is unreachable. Join the same Wi-Fi as the GameNight PC.');
    }
    if (response.statusCode == 429) {
      throw const ApiError('Too many attempts. Wait a minute before trying again.', 429);
    }
    if (response.statusCode >= 300) {
      throw ApiError(failure ?? 'GameNight refused the request.', response.statusCode);
    }
    if (response.statusCode == 204 || response.body.isEmpty) return null;
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  /// A JSON request to this host, for features that keep their calls in their
  /// own file (see room_controls.dart).
  Future<dynamic> request(String method, String path, {Object? body, String? failure}) =>
      _send(method, path, body: body, failure: failure);

  /// Cheap reachability check used by the connect screen.
  Future<void> ping() => _send('GET', '/api/player-links',
      failure: 'This address answered, but it is not a GameNight.');

  Future<Profile?> loadProfile(String id) async {
    try {
      final j = await _send('GET', '/api/profiles/${Uri.encodeComponent(id)}');
      return Profile.fromJson(j as Map<String, dynamic>);
    } on ApiError catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  Future<void> saveProfile(Profile p) =>
      _send('POST', '/api/profiles', body: p.toJson(), failure: 'Could not save your player.');

  Future<SessionInfo> session(String id) async => SessionInfo.fromJson(
      await _send('GET', '/api/profiles/${Uri.encodeComponent(id)}/session')
          as Map<String, dynamic>);

  /// Applies the profile to a character: the one [claim] or [seat] names, or a
  /// new party member when both are null.
  /// The phone screen of the game being played, if it has one. Hosts from
  /// before phone screens answer 404, which reads as "none".
  Future<Companion?> companion(String profile) async {
    try {
      final j = await _send('GET', '/api/companion?profile=${Uri.encodeQueryComponent(profile)}');
      return j is Map<String, dynamic> ? Companion.fromJson(j) : null;
    } on ApiError catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  Future<JoinResult> join(String id,
          {String? claim, int? seat, int linkRevision = 0}) async =>
      JoinResult(await _send('POST', '/api/profiles/${Uri.encodeComponent(id)}/join',
          body: {'claim': claim, 'seat': seat, 'link_revision': linkRevision},
          failure: 'Saved on your phone. Is GameNight still running?') as Map<String, dynamic>);

  /// Asks to be picked up in the lobby: walk your character to your door.
  Future<void> joinRoom(String code, String profile, {bool remember = false}) =>
      _send('POST', '/api/local-room/join',
          body: {'code': code, 'profile': profile, if (remember) 'remember': true},
          failure:
              'Could not join this room. Check the code and that you are not already connected.');

  /// Hand a character back: the controller stays in the game as a fresh,
  /// unnamed player, and this phone is no longer bound to it.
  Future<void> unlink(String player) => _send(
      'POST', '/api/player-links/${Uri.encodeComponent(player)}/unlink',
      failure: 'Could not leave this character. Try again.');

  Future<void> cancelPickup(String profile) => _send(
      'POST', '/api/local-room/cancel/${Uri.encodeComponent(profile)}',
      body: {});

  Future<void> remember(String profile, bool remember) => _send(
      'POST', '/api/profiles/${Uri.encodeComponent(profile)}/remember',
      body: {'remember': remember});

  Future<void> mainPlayer(String profile, bool enabled) => _send(
      'POST', '/api/profiles/${Uri.encodeComponent(profile)}/main-player',
      body: {'enabled': enabled});

  Future<PlaylistView> playlist() async => PlaylistView(
      await _send('GET', '/api/playlist', failure: 'Playlist unavailable.')
          as Map<String, dynamic>);

  Future<PlaylistView> movePlaylistEntry(PlaylistView view, int from, int to) async =>
      PlaylistView(await _send('POST', '/api/playlist',
          body: {'expected': view.snapshot, 'from': from, 'to': to},
          failure: 'Playlist changed. Refresh and try again.') as Map<String, dynamic>);

  Future<PlaylistView> removePlaylistEntry(PlaylistView view, int index) async =>
      PlaylistView(await _send('POST', '/api/playlist',
          body: {'expected': view.snapshot, 'from': index, 'remove': true},
          failure: 'Playlist changed. Refresh and try again.') as Map<String, dynamic>);

  /// Body sprite the lobby uses, for the character preview.
  Uri get characterSprite => _u('/assets/characters/living-room');

  void close() => _client.close();
}
