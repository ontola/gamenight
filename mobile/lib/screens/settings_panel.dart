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

  const SettingsSection({super.key, this.controls, this.title, this.showEmpty = false});

  @override
  State<SettingsSection> createState() => _SettingsSectionState();
}

class _SettingsSectionState extends State<SettingsSection> {
  GameSettings? _settings;
  bool _loaded = false;
  bool _busy = false;
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
    if ((old.controls == null) != (widget.controls == null) || old.title != widget.title) {
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
    if (_busy) return;
    if (controls == null) {
      if (_settings != null) setState(() => _settings = null);
      return;
    }
    try {
      final settings = await controls.settings();
      if (mounted && !_busy) {
        setState(() {
          _settings = settings;
          _loaded = true;
        });
      }
    } on ApiError {
      // Keep showing what we had; the next poll tries again.
    }
  }

  Future<void> _apply(Map<String, Object> values,
      {SettingsAction action = SettingsAction.set}) async {
    final controls = widget.controls, current = _settings;
    if (controls == null || current == null || _busy) return;
    setState(() => _busy = true);
    try {
      final next = await controls.applySettings(current, values: values, action: action);
      if (mounted) setState(() => _settings = next);
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
      unawaited(_load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    if (settings == null) {
      if (!widget.showEmpty) return const SizedBox.shrink();
      return Section(title: 'Game settings', children: [
        Hint(_loaded || widget.controls == null
            ? 'This game has no settings to change.'
            : 'Loading…'),
      ]);
    }
    return Section(
      title: widget.title == null ? 'Game settings' : '${widget.title} settings',
      children: [
        for (final s in settings.settings) _row(s),
        const SizedBox(height: 4),
        Row(children: [
          const Expanded(child: Hint('Everyone in the room shares these.')),
          if (_busy)
            const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
          else if (settings.canUndo)
            TextButton.icon(
              onPressed: () => _apply(const {}, action: SettingsAction.undo),
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
        : Text(s.description, style: const TextStyle(color: GnColors.muted, fontSize: 13));
    switch (s.kind) {
      case SettingKind.toggle:
        return SwitchListTile(
          key: ValueKey('setting-${s.key}'),
          contentPadding: EdgeInsets.zero,
          title: Text(s.label),
          subtitle: subtitle,
          value: s.value as bool,
          onChanged: _busy ? null : (v) => _apply({s.key: v}),
        );
      case SettingKind.number:
        final value = s.value as int;
        final lower = s.min == null || value > s.min!;
        final higher = s.max == null || value < s.max!;
        return ListTile(
          key: ValueKey('setting-${s.key}'),
          contentPadding: EdgeInsets.zero,
          title: Text(s.label),
          subtitle: subtitle,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              tooltip: 'Less ${s.label}',
              onPressed: _busy || !lower ? null : () => _apply({s.key: value - 1}),
              icon: const Icon(Icons.remove_circle_outline),
            ),
            SizedBox(
              width: 32,
              child: Text('$value',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            IconButton(
              tooltip: 'More ${s.label}',
              onPressed: _busy || !higher ? null : () => _apply({s.key: value + 1}),
              icon: const Icon(Icons.add_circle_outline),
            ),
          ]),
        );
      case SettingKind.choice:
        return Padding(
          key: ValueKey('setting-${s.key}'),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.label, style: const TextStyle(fontSize: 16)),
            if (subtitle != null) subtitle,
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final option in s.options)
                ChoiceChip(
                  label: Text(option),
                  selected: option == s.value,
                  onSelected: _busy
                      ? null
                      : (_) {
                          if (option != s.value) _apply({s.key: option});
                        },
                ),
            ]),
          ]),
        );
    }
  }
}
