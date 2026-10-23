import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../layout.dart';
import '../room_controls.dart';
import '../theme.dart';

/// What happened in the room tonight, newest first: who joined and when,
/// which games started, controllers, rounds and changed settings. For reading
/// back on a phone; the TV never shows it.
class RoomLogScreen extends StatefulWidget {
  final AppState state;

  /// The room to read; by default the one this phone plays in.
  final RoomControls? controls;
  const RoomLogScreen({super.key, required this.state, this.controls});

  static Future<void> open(BuildContext context, AppState state) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (context) => Scaffold(
              appBar: AppBar(title: const Text('Room log')),
              body: RoomLogScreen(state: state))));

  @override
  State<RoomLogScreen> createState() => _RoomLogScreenState();
}

class _RoomLogScreenState extends State<RoomLogScreen> {
  final _log = _RoomLog();

  @override
  void initState() {
    super.initState();
    _log.start(() => widget.controls ?? roomControlsFor(widget.state), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _log.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _log.entries?.reversed.toList();
    final children = <Widget>[];
    if (_log.error != null) {
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(_log.error!, style: const TextStyle(color: GnColors.warn)),
      ));
    }
    if (entries == null) {
      children.add(const Hint('Loading…'));
    } else if (entries.isEmpty) {
      children.add(const Hint('Nothing has happened in this room yet.'));
    } else {
      DateTime? day;
      for (final entry in entries) {
        final local = entry.at.toLocal();
        final thisDay = DateTime(local.year, local.month, local.day);
        if (thisDay != day) {
          day = thisDay;
          children.add(Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
            child: Text(_dayLabel(thisDay),
                style: const TextStyle(
                    color: GnColors.muted, fontWeight: FontWeight.w700)),
          ));
        }
        children.add(ActivityRow(entry: entry));
      }
    }
    return ContentWidth(
      child: RefreshIndicator(
        onRefresh: _log.load,
        child: ListView(
            key: const ValueKey('room-log'),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: children),
      ),
    );
  }

  String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (day == today) return 'Today';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return MaterialLocalizations.of(context).formatMediumDate(day);
  }
}

/// The newest few lines on the room page, opening the whole log.
class RoomLogPeek extends StatefulWidget {
  final AppState state;
  const RoomLogPeek({super.key, required this.state});

  @override
  State<RoomLogPeek> createState() => _RoomLogPeekState();
}

class _RoomLogPeekState extends State<RoomLogPeek> {
  final _log = _RoomLog();

  @override
  void initState() {
    super.initState();
    _log.start(() => roomControlsFor(widget.state), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _log.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _log.entries;
    final newest = entries?.reversed.take(3).toList() ?? const [];
    return Card(
      key: const ValueKey('room-log-peek'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => RoomLogScreen.open(context, widget.state),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Row(children: [
              Expanded(
                child: Text('Room log',
                    style:
                        TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              Icon(Icons.chevron_right, color: GnColors.muted),
            ]),
            const SizedBox(height: 6),
            if (entries == null)
              const Hint('Loading…')
            else if (newest.isEmpty)
              const Hint('Who joined, games, controllers and settings show up '
                  'here.')
            else
              for (final entry in newest) ActivityRow(entry: entry),
          ]),
        ),
      ),
    );
  }
}

/// One log line: when, an icon for what kind of thing, and what happened.
class ActivityRow extends StatelessWidget {
  final ActivityEntry entry;
  const ActivityRow({super.key, required this.entry});

  static IconData icon(String kind) => switch (kind) {
        'joined' => Icons.login,
        'left' => Icons.logout,
        'profile' => Icons.badge_outlined,
        'controller' => Icons.sports_esports_outlined,
        'phone' => Icons.smartphone,
        'game_started' => Icons.play_circle_outline,
        'round' => Icons.flag_outlined,
        'setting' => Icons.tune,
        _ => Icons.notes,
      };

  @override
  Widget build(BuildContext context) {
    final time = TimeOfDay.fromDateTime(entry.at.toLocal());
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 48,
          child: Text(
              MaterialLocalizations.of(context)
                  .formatTimeOfDay(time, alwaysUse24HourFormat: true),
              style: const TextStyle(
                  color: GnColors.muted,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 1, right: 10),
          child: Icon(icon(entry.kind), size: 18, color: GnColors.muted),
        ),
        Expanded(child: Text(entry.text)),
      ]),
    );
  }
}

/// Polls the room log while a screen shows it.
class _RoomLog {
  List<ActivityEntry>? entries;
  String? error;
  RoomControls? Function()? _controls;
  Timer? _timer;
  void Function()? _changed;

  void start(RoomControls? Function() controls, void Function() changed) {
    _controls = controls;
    _changed = changed;
    unawaited(load());
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => load());
  }

  void stop() {
    _timer?.cancel();
    _changed = null;
  }

  Future<void> load() async {
    final controls = _controls?.call();
    if (controls == null) return;
    try {
      entries = await controls.activity();
      error = null;
    } on ApiError catch (e) {
      // Keep what we showed; the next poll tries again.
      error = entries == null ? e.message : null;
    }
    _changed?.call();
  }
}
