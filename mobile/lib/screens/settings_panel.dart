import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../room_controls.dart';
import '../theme.dart';

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

  void _adjust(Setting s, int delta) {
    final value = (_value(s) as int) + delta;
    if ((s.min != null && value < s.min!) ||
        (s.max != null && value > s.max!)) {
      return;
    }
    _apply({s.key: value});
  }

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
        final value = _value(s) as int;
        final lower = s.min == null || value > s.min!;
        final higher = s.max == null || value < s.max!;
        return ListTile(
          key: ValueKey('setting-${s.key}'),
          contentPadding: EdgeInsets.zero,
          title: _label(s),
          subtitle: subtitle,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              tooltip: 'Less ${s.label}',
              onPressed: !lower ? null : () => _adjust(s, -1),
              icon: const Icon(Icons.remove_circle_outline),
            ),
            SizedBox(
              width: 32,
              child: Text('$value',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            IconButton(
              tooltip: 'More ${s.label}',
              onPressed: !higher ? null : () => _adjust(s, 1),
              icon: const Icon(Icons.add_circle_outline),
            ),
          ]),
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
