import 'dart:async';
import 'dart:convert';
// What a player in a room can do from the Game and Playlist tabs: queue a
// game the room's host can play, play or start one next, and change the
// match settings of the current (or loaded next) game.
//
// [RoomControls] is the seam between the screen and where the room lives.
// [LocalRoomControls] talks to a GameNight computer on the same Wi-Fi; a
// hosted (online) room can implement the same interface.
import 'dart:math';

import 'account.dart';
import 'api.dart';
import 'app_state.dart';

/// A game the room's host has, and whether the party can play it now.
class HostGame {
  final String id;
  final String? title;

  /// Whether it can be queued: installed (or installing) and fits the party.
  final bool playable;

  /// What the host says about it: "available", "playing", "downloading"…
  final String state;

  const HostGame(
      {required this.id, this.title, this.playable = false, this.state = ''});

  static HostGame? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String) return null;
    return HostGame(
      id: j['id'] as String,
      title: j['title'] as String?,
      playable: j['selectable'] == true,
      state: j['state']?.toString() ?? '',
    );
  }
}

enum SettingKind { toggle, number, choice }

/// One knob the current game lets the party turn.
class Setting {
  final String key;
  final String label;
  final String description;
  final SettingKind kind;

  /// bool for a toggle, int for a number, String for a choice.
  final Object value;
  final int? min;
  final int? max;
  final List<String> options;

  const Setting({
    required this.key,
    required this.label,
    required this.kind,
    required this.value,
    this.description = '',
    this.min,
    this.max,
    this.options = const [],
  });

  static Setting? fromJson(String key, Object? j) {
    if (j is! Map) return null;
    final kind = switch (j['kind']) {
      'toggle' => SettingKind.toggle,
      'number' => SettingKind.number,
      'choice' => SettingKind.choice,
      _ => null,
    };
    final value = j['value'];
    final ok = switch (kind) {
      SettingKind.toggle => value is bool,
      SettingKind.number => value is num,
      SettingKind.choice => value is String,
      null => false,
    };
    if (!ok) return null;
    return Setting(
      key: key,
      label: j['label'] is String ? j['label'] as String : key,
      description: j['description'] is String ? j['description'] as String : '',
      kind: kind!,
      value: value is num ? value.toInt() : value as Object,
      min: (j['min'] as num?)?.toInt(),
      max: (j['max'] as num?)?.toInt(),
      options: j['options'] is List
          ? [for (final o in j['options'] as List) o.toString()]
          : const [],
    );
  }
}

/// The current game's settings, at one revision. Changes are made against
/// that revision, so two phones changing things at once cannot overwrite
/// each other unseen.
class GameSettings {
  final String game;
  final String instance;
  final int revision;
  final bool canUndo;
  final List<Setting> settings;

  const GameSettings({
    required this.game,
    required this.instance,
    required this.revision,
    this.canUndo = false,
    required this.settings,
  });

  static GameSettings? fromJson(Object? j) {
    if (j is! Map || j['game'] is! String || j['instance'] is! String) {
      return null;
    }
    final raw = j['settings'] is Map ? j['settings'] as Map : const {};
    final settings = [
      for (final MapEntry(:key, :value) in raw.entries)
        if (Setting.fromJson(key.toString(), value) case final s?) s,
    ];
    if (settings.isEmpty) return null;
    return GameSettings(
      game: j['game'] as String,
      instance: j['instance'] as String,
      revision: (j['revision'] as num?)?.toInt() ?? 0,
      canUndo: j['can_undo'] == true,
      settings: settings,
    );
  }
}

enum SettingsAction { set, undo, keep }

/// This player's own settings for one game (their character, their stick
/// sensitivity). Nobody else's change, and no revision to race.
class PlayerSettings {
  final String game;
  final String? title;
  final List<Setting> settings;

  const PlayerSettings(
      {required this.game, this.title, required this.settings});

  static PlayerSettings? fromJson(Object? j) {
    if (j is! Map || j['game'] is! String) return null;
    final raw = j['settings'] is Map ? j['settings'] as Map : const {};
    final settings = [
      for (final MapEntry(:key, :value) in raw.entries)
        if (Setting.fromJson(key.toString(), value) case final s?) s,
    ];
    if (settings.isEmpty) return null;
    return PlayerSettings(
        game: j['game'] as String,
        title: j['title'] as String?,
        settings: settings);
  }
}

abstract class RoomControls {
  /// Stable identity across screen rebuilds; changing rooms invalidates edits.
  Object get target;

  /// The games this room's host has. Empty when it cannot say.
  Future<List<HostGame>> games();
  Future<PlaylistView> playlist();
  Future<PlaylistView> movePlaylistEntry(PlaylistView view, int from, int to);
  Future<PlaylistView> removePlaylistEntry(PlaylistView view, int index);

  /// Adds [game] to the end of the room's queue. Never interrupts play.
  Future<void> addToQueue(String game);

  /// Makes [game] the next one up, so it starts loading. With [start] the
  /// current game ends as soon as it has loaded.
  Future<void> playNext(String game, {bool start = false});

  /// The settings of the game being played or warmed up, or null when it
  /// has none. With [game], that game's, when it is played or warmed up.
  Future<GameSettings?> settings({String? game});

  /// Changes settings (or undoes the last change) as this player, against
  /// [current]'s revision. Returns the settings afterwards.
  Future<GameSettings?> applySettings(GameSettings current,
      {Map<String, Object> values = const {},
      SettingsAction action = SettingsAction.set});

  /// This player's own settings for the game being played or warmed up (or
  /// [game]), or null when it has none or the room cannot say.
  Future<PlayerSettings?> playerSettings({String? game}) async => null;

  /// Changes one of this player's own settings. Returns them afterwards.
  Future<PlayerSettings?> setPlayerSetting(
          String game, String key, Object value) async =>
      null;
}

/// The room on a GameNight computer on this Wi-Fi. The host knows this phone
/// by its profile, which it bound to a character when the phone joined.
class LocalRoomControls implements RoomControls {
  final GameNightApi api;
  final String profile;
  LocalRoomControls(this.api, this.profile);

  @override
  Object get target => (api, profile);

  String get _query => 'profile=${Uri.encodeQueryComponent(profile)}';

  @override
  Future<PlaylistView> playlist() => api.playlist();
  @override
  Future<PlaylistView> movePlaylistEntry(PlaylistView view, int from, int to) =>
      api.movePlaylistEntry(view, from, to);
  @override
  Future<PlaylistView> removePlaylistEntry(PlaylistView view, int index) =>
      api.removePlaylistEntry(view, index);

  @override
  Future<List<HostGame>> games() async {
    try {
      final j = await api.request('GET', '/api/games?$_query');
      final list =
          j is Map && j['games'] is List ? j['games'] as List : const [];
      return [
        for (final g in list)
          if (HostGame.fromJson(g) case final game?) game
      ];
    } on ApiError catch (e) {
      // Hosts from before this feature, and phones not in the room.
      if (e.status == 404 || e.status == 403) return const [];
      rethrow;
    }
  }

  @override
  Future<void> addToQueue(String game) =>
      api.request('POST', '/api/playlist/queue',
          body: {'profile': profile, 'game': game},
          failure: 'Could not add that game to the queue.');

  @override
  Future<void> playNext(String game, {bool start = false}) => api.request(
      'POST', '/api/playlist/next',
      body: {'profile': profile, 'game': game, 'start': start},
      failure:
          start ? 'Could not start that game.' : 'Could not queue that game.');

  @override
  Future<GameSettings?> settings({String? game}) async {
    final only = game == null ? '' : '&game=${Uri.encodeQueryComponent(game)}';
    try {
      return GameSettings.fromJson(
          await api.request('GET', '/api/settings?$_query$only'));
    } on ApiError catch (e) {
      if (e.status == 404 || e.status == 403) return null;
      rethrow;
    }
  }

  @override
  Future<GameSettings?> applySettings(GameSettings current,
      {Map<String, Object> values = const {},
      SettingsAction action = SettingsAction.set}) async {
    final j = await api.request('POST', '/api/settings',
        body: {
          'profile': profile,
          'command': {
            'action': action.name,
            'instance': current.instance,
            'expected_revision': current.revision,
            'values': values,
          },
        },
        failure:
            'The game did not take that change. It may have changed meanwhile.');
    return GameSettings.fromJson(j);
  }

  @override
  Future<PlayerSettings?> playerSettings({String? game}) async {
    final only = game == null ? '' : '&game=${Uri.encodeQueryComponent(game)}';
    try {
      return PlayerSettings.fromJson(
          await api.request('GET', '/api/player-settings?$_query$only'));
    } on ApiError catch (e) {
      // Hosts from before this feature, and phones not in the room.
      if (e.status == 404 || e.status == 403 || e.status == 405) return null;
      rethrow;
    }
  }

  @override
  Future<PlayerSettings?> setPlayerSetting(
          String game, String key, Object value) async =>
      PlayerSettings.fromJson(await api.request('POST', '/api/player-settings',
          body: {'profile': profile, 'game': game, 'key': key, 'value': value},
          failure: 'The game did not take that change.'));
}

/// An online room joined by code. The website relays to the GameNight
/// computer, which reports its games and settings every few seconds.
class CloudRoomControls implements RoomControls {
  final CloudApi cloud;
  final Duration confirmationTimeout;
  @override
  final Object target;
  CloudRoomControls(this.cloud,
      {String? roomCode,
      this.confirmationTimeout = const Duration(seconds: 20)})
      : target = (cloud, cloud.roomIdentity, roomCode);

  static String _requestId() {
    final r = Random.secure();
    final b = List.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  Future<Map?> _discovery() async {
    final room = await cloud.roomStatus();
    if (!room.connected) return null;
    final d = room.raw['discovery'];
    return d is Map ? d : null;
  }

  @override
  Future<PlaylistView> playlist() async {
    final d = await _discovery();
    if (d == null || d['playlist'] is! Map) {
      throw const ApiError('The room playlist is not available yet.');
    }
    return PlaylistView(Map<String, dynamic>.from(d));
  }

  Future<PlaylistView> _editPlaylist(
      PlaylistView view, Map<String, Object> edit) async {
    final id = _requestId();
    final desired = view.entries.map((e) => e.raw).toList();
    final entry = desired.removeAt(edit['from'] as int);
    if (edit['remove'] != true) desired.insert(edit['to'] as int, entry);
    await cloud.request('POST', '/v1/rooms/next', body: {
      'request_id': id,
      'edit': {'expected': view.snapshot, ...edit},
    }, errors: {
      409: 'Playlist changed. Refresh and try again.',
      503: 'The GameNight computer is not answering.'
    });
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final next = await playlist();
      if (jsonEncode(next.entries.map((e) => e.raw).toList()) ==
          jsonEncode(desired)) {
        return next;
      }
    }
    throw const ApiError(
        'The room has not confirmed the playlist change. Check the queue before retrying.');
  }

  @override
  Future<PlaylistView> movePlaylistEntry(PlaylistView view, int from, int to) =>
      _editPlaylist(view, {'from': from, 'to': to});
  @override
  Future<PlaylistView> removePlaylistEntry(PlaylistView view, int index) =>
      _editPlaylist(view, {'from': index, 'remove': true});

  @override
  Future<List<HostGame>> games() async {
    final list = (await _discovery())?['games'];
    return [
      if (list is List)
        for (final g in list)
          if (HostGame.fromJson(g) case final game?) game
    ];
  }

  /// Online rooms queue by asking the host to play the game next.
  @override
  Future<void> addToQueue(String game) => playNext(game);

  @override
  Future<void> playNext(String game, {bool start = false}) =>
      cloud.request('POST', '/v1/rooms/next', body: {
        'game': game,
        'request_id': _requestId(),
        if (start) 'start': true,
      }, errors: {
        503: 'The GameNight computer is not answering. Try again in a moment.',
        403: 'Join the room first.',
        409: 'The GameNight computer cannot play that game right now.',
      });

  /// Online rooms only report the settings of the game on screen.
  @override
  Future<GameSettings?> settings({String? game}) async {
    if (cloud.guestToken != null) return null;
    final current = GameSettings.fromJson((await _discovery())?['controls']);
    return game == null || current?.game == game ? current : null;
  }

  @override
  Future<GameSettings?> applySettings(GameSettings current,
      {Map<String, Object> values = const {},
      SettingsAction action = SettingsAction.set}) async {
    final elapsed = Stopwatch()..start();
    const unconfirmed = ApiError(
        'The host has not confirmed this change yet. It may still arrive. Check the settings before retrying.');
    Future<dynamic> request(String method, String path,
        {Object? body, Map<int, String> errors = const {}}) async {
      final remaining = confirmationTimeout - elapsed.elapsed;
      if (remaining <= Duration.zero) throw unconfirmed;
      try {
        return await cloud
            .request(method, path, body: body, errors: errors)
            .timeout(remaining);
      } on TimeoutException {
        throw unconfirmed;
      }
    }

    final id = _requestId();
    await request('POST', '/v1/rooms/agent/control', body: {
      'request_id': id,
      'game': current.game,
      'command': {
        'action': action.name,
        'instance': current.instance,
        'expected_revision': current.revision,
        'values': values,
      },
    }, errors: {
      403: 'In an online room, only the main player can change settings.',
      409: 'The game changed meanwhile. Look again and retry.',
      400: 'The game does not take that change.',
    });
    // A revision change can belong to another phone. Confirm this request's
    // receipt, including rejection, instead of treating any change as success.
    for (var i = 0; i < 17; i++) {
      if (i > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      final status = await request('GET', '/v1/rooms/agent');
      final next =
          GameSettings.fromJson(status is Map ? status['controls'] : null);
      if (next == null ||
          next.game != current.game ||
          next.instance != current.instance) {
        throw const ApiError(
            'The game changed. These settings were not carried over.', 409);
      }
      final requests = status is Map && status['requests'] is List
          ? status['requests'] as List
          : const [];
      for (final receipt in requests) {
        if (receipt is! Map || receipt['id'] != id) continue;
        if (receipt['state'] == 'failed' ||
            receipt['state'] == 'reconciliation_needed') {
          throw ApiError(receipt['result'] is String
              ? receipt['result'] as String
              : 'The game did not accept that change.');
        }
        if (receipt['state'] == 'complete') {
          if (action == SettingsAction.set &&
              values.entries.any((entry) => !next.settings
                  .any((s) => s.key == entry.key && s.value == entry.value))) {
            throw const ApiError(
                'Settings changed on another device. Review them before retrying.',
                409);
          }
          return next;
        }
      }
    }
    throw unconfirmed;
  }

  // Online rooms do not relay players' own settings yet.
  @override
  Future<PlayerSettings?> playerSettings({String? game}) async => null;

  @override
  Future<PlayerSettings?> setPlayerSetting(
          String game, String key, Object value) async =>
      null;
}

/// The controls for the room this phone is playing in, if it is in one.
RoomControls? roomControlsFor(AppState state) {
  if (state.inHostedRoom && (state.hostedRoom?.connected ?? false)) {
    return CloudRoomControls(state.cloud, roomCode: state.hostedRoom?.code);
  }
  final api = state.api;
  if (api == null || !(state.session?.linked ?? false)) return null;
  return LocalRoomControls(api, state.profileId);
}
