// What a player in a room can do from the Game tab: queue a game the room's
// host can play, and change the current game's match settings.
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

  const HostGame({required this.id, this.title, this.playable = false, this.state = ''});

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
      options:
          j['options'] is List ? [for (final o in j['options'] as List) o.toString()] : const [],
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
    if (j is! Map || j['game'] is! String || j['instance'] is! String) return null;
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

abstract class RoomControls {
  /// The games this room's host has. Empty when it cannot say.
  Future<List<HostGame>> games();

  /// Adds [game] to the end of the room's queue. Never interrupts play.
  Future<void> addToQueue(String game);

  /// The settings of the game being played or warmed up, or null when it
  /// has none.
  Future<GameSettings?> settings();

  /// Changes settings (or undoes the last change) as this player, against
  /// [current]'s revision. Returns the settings afterwards.
  Future<GameSettings?> applySettings(GameSettings current,
      {Map<String, Object> values = const {}, SettingsAction action = SettingsAction.set});
}

/// The room on a GameNight computer on this Wi-Fi. The host knows this phone
/// by its profile, which it bound to a character when the phone joined.
class LocalRoomControls implements RoomControls {
  final GameNightApi api;
  final String profile;
  LocalRoomControls(this.api, this.profile);

  String get _query => 'profile=${Uri.encodeQueryComponent(profile)}';

  @override
  Future<List<HostGame>> games() async {
    try {
      final j = await api.request('GET', '/api/games?$_query');
      final list = j is Map && j['games'] is List ? j['games'] as List : const [];
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
  Future<void> addToQueue(String game) => api.request('POST', '/api/playlist/queue',
      body: {'profile': profile, 'game': game}, failure: 'Could not add that game to the queue.');

  @override
  Future<GameSettings?> settings() async {
    try {
      return GameSettings.fromJson(await api.request('GET', '/api/settings?$_query'));
    } on ApiError catch (e) {
      if (e.status == 404 || e.status == 403) return null;
      rethrow;
    }
  }

  @override
  Future<GameSettings?> applySettings(GameSettings current,
      {Map<String, Object> values = const {}, SettingsAction action = SettingsAction.set}) async {
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
        failure: 'The game did not take that change. It may have changed meanwhile.');
    return GameSettings.fromJson(j);
  }
}

/// An online room joined by code. The website relays to the GameNight
/// computer, which reports its games and settings every few seconds.
class CloudRoomControls implements RoomControls {
  final CloudApi cloud;
  CloudRoomControls(this.cloud);

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
  Future<void> addToQueue(String game) => cloud.request('POST', '/v1/rooms/next', body: {
        'game': game,
        'request_id': _requestId()
      }, errors: {
        503: 'The GameNight computer is not answering. Try again in a moment.',
        403: 'Join the room first.',
      });

  @override
  Future<GameSettings?> settings() async =>
      GameSettings.fromJson((await _discovery())?['controls']);

  @override
  Future<GameSettings?> applySettings(GameSettings current,
      {Map<String, Object> values = const {}, SettingsAction action = SettingsAction.set}) async {
    await cloud.request('POST', '/v1/rooms/agent/control', body: {
      'request_id': _requestId(),
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
    // The host picks the change up on its next check-in.
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final next = await settings();
      if (next == null || next.revision != current.revision) return next;
    }
    return settings();
  }
}

/// The controls for the room this phone is playing in, if it is in one.
RoomControls? roomControlsFor(AppState state) {
  if (state.inHostedRoom && (state.hostedRoom?.connected ?? false)) {
    return CloudRoomControls(state.cloud);
  }
  final api = state.api;
  if (api == null || !(state.session?.linked ?? false)) return null;
  return LocalRoomControls(api, state.profileId);
}
