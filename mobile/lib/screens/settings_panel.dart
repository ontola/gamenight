import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../room_controls.dart';
import '../storage/phone_store.dart';
import '../theme.dart';
import '../widgets/number_setting.dart';

/// The match settings of the game being played or warmed up: toggles,
/// numbers and choices the game declared. Hidden when it has none.
class SettingsSection extends StatefulWidget {
  final RoomControls? controls;

  /// The game's name, for the heading.
  final String? title;

  /// Says so instead of hiding when there is nothing to set.
  final bool showEmpty;

  /// This game's settings instead of the current game's.
  final String? game;

  /// What to say when [showEmpty] and the game has nothing to set right now.
  final String? emptyHint;

  const SettingsSection(
      {super.key,
      this.controls,
      this.title,
      this.showEmpty = false,
      this.game,
      this.emptyHint});

  @override
  State<SettingsSection> createState() => _SettingsSectionState();
}

class _SettingsSectionState extends State<SettingsSection> {
  GameSettings? _settings;
  bool _loaded = false;
  bool _saving = false;
  bool _loading = false;
  int _generation = 0;
  int _editVersion = 0;
  final Map<String, Object> _pending = {};
  Map<String, Object> _sending = {};
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _load());
  }

  @override
  void didUpdateWidget(SettingsSection old) {
    super.didUpdateWidget(old);
    if (old.controls?.target != widget.controls?.target ||
        old.game != widget.game) {
      _generation++;
      _settings = null;
      _pending.clear();
      _sending = {};
      _error = null;
      _saving = false;
      _loading = false;
      _loaded = false;
      _load();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _generation++;
    super.dispose();
  }

  Future<void> _load() async {
    final controls = widget.controls;
    if (_saving || _loading) return;
    if (controls == null) {
      if (_settings != null) setState(() => _settings = null);
      return;
    }
    final generation = _generation;
    final editVersion = _editVersion;
    _loading = true;
    try {
      final settings = await controls.settings(game: widget.game);
      if (mounted &&
          generation == _generation &&
          editVersion == _editVersion &&
          !_saving) {
        if (settings?.instance == _settings?.instance &&
            settings != null &&
            _settings != null &&
            settings.revision < _settings!.revision) {
          return;
        }
        setState(() {
          if (_settings != null && settings?.instance != _settings?.instance) {
            if (_pending.isNotEmpty) {
              _error = 'The game changed. Unsaved changes were cleared.';
            }
            _pending.clear();
          }
          _settings = settings;
          _loaded = true;
        });
      }
    } catch (_) {
      // Keep showing what we had; the next poll tries again.
    } finally {
      if (generation == _generation) _loading = false;
    }
  }

  Object _value(Setting s) => _pending[s.key] ?? _sending[s.key] ?? s.value;

  Future<void> _apply(Map<String, Object> values,
      {SettingsAction action = SettingsAction.set}) async {
    if (widget.controls == null || _settings == null) return;
    if (action == SettingsAction.set) {
      setState(() => _pending.addAll(values));
      if (_saving || _error != null) return;
    } else if (_saving || _pending.isNotEmpty || _error != null) {
      return;
    }
    final generation = _generation;
    final controls = widget.controls!;
    do {
      final current = _settings!;
      final batch = Map<String, Object>.from(_pending);
      setState(() {
        _editVersion++;
        _pending.clear();
        _sending = batch;
        _saving = true;
      });
      try {
        final next = await controls.applySettings(current,
            values: batch, action: action);
        if (!mounted || generation != _generation) return;
        if (next == null ||
            next.game != current.game ||
            next.instance != current.instance) {
          setState(() {
            _pending.clear();
            _settings = null;
            _error = 'The game changed. Unsaved changes were cleared.';
          });
          break;
        }
        setState(() => _settings = next);
      } catch (e) {
        if (!mounted || generation != _generation) return;
        setState(() {
          final newer = Map<String, Object>.from(_pending);
          _pending
            ..clear()
            ..addAll(batch)
            ..addAll(newer);
          _error = e is ApiError
              ? e.message
              : 'Could not save these settings. Please try again.';
        });
        break;
      } finally {
        if (mounted && generation == _generation) {
          setState(() {
            _saving = false;
            _sending = {};
          });
        }
      }
      action = SettingsAction.set;
    } while (_pending.isNotEmpty);
    unawaited(_load());
  }

  Future<void> _retry() async {
    final generation = _generation;
    final previous = _settings;
    final controls = widget.controls;
    if (controls == null || previous == null || _saving) return;
    try {
      final latest = await controls.settings(game: widget.game);
      if (!mounted || generation != _generation) return;
      if (_settings?.instance != previous.instance) return;
      if (latest == null ||
          latest.game != previous.game ||
          latest.instance != previous.instance) {
        setState(() {
          _settings = latest;
          _pending.clear();
          _error = 'The game changed. Unsaved changes were cleared.';
        });
        return;
      }
      if (latest.revision >= _settings!.revision) _settings = latest;
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() => _error =
            e is ApiError ? e.message : 'Could not refresh the game settings.');
      }
      return;
    }
    setState(() {
      // A delayed confirmation may have arrived after our timeout.
      _pending.removeWhere((key, value) =>
          _settings!.settings.any((s) => s.key == key && s.value == value));
      _error = null;
    });
    if (_pending.isNotEmpty) await _apply(const {});
  }

  Widget _status() {
    if (_error == null) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_error!,
          key: const ValueKey('settings-error'),
          style: TextStyle(color: Theme.of(context).colorScheme.error)),
      if (_pending.isNotEmpty)
        Row(children: [
          TextButton(onPressed: _retry, child: const Text('Retry')),
          TextButton(
              onPressed: () {
                setState(() {
                  _pending.clear();
                  _error = null;
                });
                unawaited(_load());
              },
              child: const Text('Discard changes')),
        ]),
      if (_pending.isEmpty)
        TextButton(
            onPressed: () => setState(() => _error = null),
            child: const Text('Dismiss')),
    ]);
  }

  Widget _label(Setting s) {
    return Row(children: [
      Expanded(child: Text(s.label)),
      if (_pending.containsKey(s.key) || _sending.containsKey(s.key))
        Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(_error == null ? 'Saving…' : 'Not saved',
                style: const TextStyle(color: GnColors.muted, fontSize: 12))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    if (settings == null) {
      if (!widget.showEmpty && _error == null) return const SizedBox.shrink();
      return Section(
          title: widget.title == null
              ? 'Game settings'
              : '${widget.title} settings',
          children: [
            _status(),
            Hint(_loaded || widget.controls == null
                ? widget.emptyHint ?? 'This game has no settings to change.'
                : 'Loading…'),
          ]);
    }
    return Section(
      title:
          widget.title == null ? 'Game settings' : '${widget.title} settings',
      children: [
        for (final s in settings.settings) _row(s),
        _status(),
        const SizedBox(height: 4),
        Row(children: [
          const Expanded(child: Hint('Everyone in the room shares these.')),
          if (settings.canUndo)
            TextButton.icon(
              onPressed: _saving || _pending.isNotEmpty || _error != null
                  ? null
                  : () => _apply(const {}, action: SettingsAction.undo),
              icon: const Icon(Icons.undo, size: 18),
              label: const Text('Undo'),
            ),
        ]),
      ],
    );
  }

  Widget _row(Setting s) {
    final subtitle = s.description.isEmpty
        ? null
        : Text(s.description,
            style: const TextStyle(color: GnColors.muted, fontSize: 13));
    switch (s.kind) {
      case SettingKind.toggle:
        return SwitchListTile(
          key: ValueKey('setting-${s.key}'),
          contentPadding: EdgeInsets.zero,
          title: _label(s),
          subtitle: subtitle,
          value: _value(s) as bool,
          onChanged: (v) => _apply({s.key: v}),
        );
      case SettingKind.number:
        return NumberSetting(
          key: ValueKey('setting-${s.key}'),
          title: _label(s),
          label: s.label,
          subtitle: subtitle,
          value: _value(s) as int,
          min: s.min,
          max: s.max,
          onChanged: (v) => _apply({s.key: v}),
        );
      case SettingKind.choice:
        return Padding(
          key: ValueKey('setting-${s.key}'),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _label(s),
            if (subtitle != null) subtitle,
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final option in s.options)
                ChoiceChip(
                  label: Text(option),
                  selected: option == _value(s),
                  onSelected: (_) {
                    if (option != _value(s)) _apply({s.key: option});
                  },
                ),
            ]),
          ]),
        );
    }
  }
}

/// Where this phone keeps its player's own settings, per game, so they come
/// back on any GameNight computer even without signing in. On a phone they
/// are kept in its Atomic store ([PhoneStore]); this is the readable copy.
class PhoneSettingsStore {
  final SharedPreferences prefs;
  const PhoneSettingsStore(this.prefs);
  static const _key = 'my_game_settings';

  Map<String, Object> forGame(String game) {
    try {
      final all = jsonDecode(prefs.getString(_key) ?? '{}');
      final values = all is Map ? all[game] : null;
      if (values is! Map) return {};
      return {
        for (final MapEntry(:key, :value) in values.entries)
          if (value is bool || value is num || value is String)
            key.toString(): value is num ? value.toInt() : value as Object,
      };
    } on FormatException {
      return {};
    }
  }

  Future<void> save(PlayerSettings settings) async {
    Map all;
    try {
      final decoded = jsonDecode(prefs.getString(_key) ?? '{}');
      all = decoded is Map ? decoded : {};
    } on FormatException {
      all = {};
    }
    final values = {for (final s in settings.settings) s.key: s.value};
    all[settings.game] = values;
    await prefs.setString(_key, jsonEncode(all));
    await PhoneStore.instance?.saveSettings(settings.game, values);
  }
}

/// This player's own settings for the game being played or warmed up: their
/// character, their stick sensitivity. Hidden when the game has none.
///
/// The phone remembers them too. A phone that is not signed in hands them
/// to the room when it joins, so they follow it from computer to computer.
class MySettingsSection extends StatefulWidget {
  final RoomControls? controls;
  final PhoneSettingsStore? store;

  /// Signed in: the host keeps these with the account, the phone only
  /// remembers them.
  final bool signedIn;
  final String? game;

  const MySettingsSection(
      {super.key, this.controls, this.store, this.signedIn = false, this.game});

  @override
  State<MySettingsSection> createState() => _MySettingsSectionState();
}

class _MySettingsSectionState extends State<MySettingsSection> {
  PlayerSettings? _settings;
  final Set<String> _handedOver = {};
  final Map<String, Object> _saving = {};
  String? _error;
  Timer? _poll;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _load());
  }

  @override
  void didUpdateWidget(MySettingsSection old) {
    super.didUpdateWidget(old);
    if (old.controls?.target != widget.controls?.target ||
        old.game != widget.game) {
      _generation++;
      _settings = null;
      _error = null;
      _load();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _generation++;
    super.dispose();
  }

  Future<void> _load() async {
    final controls = widget.controls;
    if (controls == null || _saving.isNotEmpty) return;
    final generation = _generation;
    PlayerSettings? settings;
    try {
      settings = await controls.playerSettings(game: widget.game);
    } catch (_) {
      return; // Keep what we had; the next poll tries again.
    }
    if (!mounted || generation != _generation || _saving.isNotEmpty) return;
    setState(() => _settings = settings);
    if (settings == null) return;
    final store = widget.store;
    if (store == null) return;
    if (!widget.signedIn && _handedOver.add(settings.game)) {
      // What this phone chose before, on this or another computer.
      final remembered = store.forGame(settings.game);
      for (final s in settings.settings) {
        final value = remembered[s.key];
        if (value != null && value != s.value) {
          await _set(s, value);
        }
      }
      return;
    }
    await store.save(settings);
  }

  Future<void> _set(Setting s, Object value) async {
    final controls = widget.controls;
    final current = _settings;
    if (controls == null || current == null) return;
    final generation = _generation;
    setState(() {
      _saving[s.key] = value;
      _error = null;
    });
    try {
      final next = await controls.setPlayerSetting(current.game, s.key, value);
      if (!mounted || generation != _generation) return;
      setState(() => _settings = next ?? current);
      if (next != null) await widget.store?.save(next);
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() => _error =
          e is ApiError ? e.message : 'Could not save that. Please try again.');
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _saving.remove(s.key));
      }
    }
  }

  Object _value(Setting s) => _saving[s.key] ?? s.value;

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    if (settings == null) return const SizedBox.shrink();
    return Section(
      title: settings.title == null
          ? 'My settings'
          : 'My settings in ${settings.title}',
      children: [
        for (final s in settings.settings) _row(s),
        if (_error case final error?)
          Text(error,
              key: const ValueKey('my-settings-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 4),
        Hint(widget.signedIn
            ? 'Only for you. Saved with your profile.'
            : 'Only for you. Saved on this phone; sign in to keep them everywhere.'),
      ],
    );
  }

  Widget _row(Setting s) {
    final subtitle = s.description.isEmpty
        ? null
        : Text(s.description,
            style: const TextStyle(color: GnColors.muted, fontSize: 13));
    final title = Row(children: [
      Expanded(child: Text(s.label)),
      if (_saving.containsKey(s.key))
        const Padding(
            padding: EdgeInsets.only(left: 8),
            child: Text('Saving…',
                style: TextStyle(color: GnColors.muted, fontSize: 12))),
    ]);
    switch (s.kind) {
      case SettingKind.toggle:
        return SwitchListTile(
          key: ValueKey('my-setting-${s.key}'),
          contentPadding: EdgeInsets.zero,
          title: title,
          subtitle: subtitle,
          value: _value(s) as bool,
          onChanged: (v) => _set(s, v),
        );
      case SettingKind.number:
        return NumberSetting(
          key: ValueKey('my-setting-${s.key}'),
          title: title,
          label: s.label,
          subtitle: subtitle,
          value: _value(s) as int,
          min: s.min,
          max: s.max,
          onChanged: (v) => _set(s, v),
        );
      case SettingKind.choice:
        return Padding(
          key: ValueKey('my-setting-${s.key}'),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            title,
            if (subtitle != null) subtitle,
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final option in s.options)
                ChoiceChip(
                  label: Text(option),
                  selected: option == _value(s),
                  onSelected: (_) {
                    if (option != _value(s)) _set(s, option);
                  },
                ),
            ]),
          ]),
        );
    }
  }
}

/// The buttons the game being played offers phones, like "New round". Each
/// press lands in the room log. Hidden when the game offers none.
class GameActionsSection extends StatefulWidget {
  final RoomControls? controls;
  const GameActionsSection({super.key, this.controls});

  @override
  State<GameActionsSection> createState() => _GameActionsSectionState();
}

class _GameActionsSectionState extends State<GameActionsSection> {
  GameActions? _actions;
  String? _busy;
  String? _status;
  bool _failed = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _load());
  }

  @override
  void didUpdateWidget(GameActionsSection old) {
    super.didUpdateWidget(old);
    if (old.controls?.target != widget.controls?.target) {
      _actions = null;
      _status = null;
      _load();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final controls = widget.controls;
    if (controls == null) return;
    try {
      final actions = await controls.actions();
      if (!mounted) return;
      setState(() {
        if (actions?.game != _actions?.game) _status = null;
        _actions = actions;
      });
    } catch (_) {
      // Keep showing what we had; the next poll tries again.
    }
  }

  Future<void> _press(GameActions actions, GameAction action) async {
    final controls = widget.controls;
    if (controls == null || _busy != null) return;
    if (action.confirm) {
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${action.label}?'),
          content: Text(action.description.isEmpty
              ? 'Everyone in ${actions.title} is affected.'
              : action.description),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                key: const ValueKey('action-confirm'),
                onPressed: () => Navigator.pop(context, true),
                child: Text(action.label)),
          ],
        ),
      );
      if (sure != true || !mounted) return;
    }
    setState(() {
      _busy = action.key;
      _status = null;
    });
    try {
      await controls.triggerAction(actions.game, action.key);
      if (!mounted) return;
      setState(() {
        _failed = false;
        _status = '${action.label}: sent to the game.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _status = e is ApiError ? e.message : 'The game did not take that.';
      });
      unawaited(_load());
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final actions = _actions;
    if (actions == null) return const SizedBox.shrink();
    return Section(title: actions.title, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final action in actions.actions)
          Tooltip(
            message: action.description,
            child: FilledButton.tonalIcon(
              key: ValueKey('action-${action.key}'),
              onPressed: _busy == null ? () => _press(actions, action) : null,
              icon: _busy == action.key
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow, size: 18),
              label: Text(action.label),
            ),
          ),
      ]),
      const SizedBox(height: 8),
      if (_failed && _status != null)
        Text(_status!, style: const TextStyle(color: GnColors.warn))
      else
        Hint(_status ?? 'The room log says who pressed it.'),
    ]);
  }
}
