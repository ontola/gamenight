import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../catalog.dart';
import '../room_controls.dart';
import '../theme.dart';
import 'game_detail_screen.dart';
import 'settings_panel.dart';

/// Tonight's queue: drag to reorder, remove, or replay an earlier game. A tap
/// on a game opens it: start it now, change its settings or see it in the
/// store.
class PlaylistScreen extends StatefulWidget {
  final AppState state;
  final VoidCallback onJoin;
  const PlaylistScreen({super.key, required this.state, required this.onJoin});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  PlaylistView? _view;
  String? _error;
  bool _busy = false;
  Timer? _timer;

  AppState get state => widget.state;
  bool get _linked => state.session?.linked ?? false;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final api = state.api;
    if (api == null || !_linked || _busy) return;
    try {
      final view = await api.playlist();
      if (mounted && !_busy) {
        setState(() {
          _view = view;
          _error = null;
        });
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _edit(Future<PlaylistView> Function(GameNightApi api, PlaylistView view) change,
      {PlaylistView? optimistic}) async {
    final api = state.api, view = _view;
    if (api == null || view == null || _busy) return;
    setState(() {
      _busy = true;
      if (optimistic != null) _view = optimistic;
    });
    try {
      final next = await change(api, view);
      if (mounted) setState(() => _view = next);
    } on ApiError catch (e) {
      if (mounted) {
        setState(() => _view = view);
        toast(context, e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      unawaited(_load());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        if (!_linked) {
          return ListView(padding: const EdgeInsets.all(16), children: [
            Section(title: 'Tonight’s playlist', children: [
              const Hint('Join a room to see and change its playlist.'),
              const SizedBox(height: 12),
              FilledButton(onPressed: widget.onJoin, child: const Text('Join a room')),
            ]),
          ]);
        }
        if (_view == null) {
          unawaited(_load());
          return Center(child: _error == null ? const CircularProgressIndicator() : Hint(_error!));
        }
        return _list(_view!);
      },
    );
  }

  Widget _list(PlaylistView view) {
    final start = view.current ?? 0;
    final upcoming = [for (var i = start; i < view.entries.length; i++) i];
    final past = [for (var i = 0; i < start; i++) i];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Row(children: [
          const Expanded(
            child: Text('Tonight’s playlist',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          ),
          if (_busy)
            const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
        const SizedBox(height: 4),
        Hint(view.entries.isEmpty
            ? 'No games queued yet.'
            : 'Tap a game to start it, change its settings or see it in the store. '
                'Drag to change the order. Everyone on this GameNight sees the same queue.'),
        const SizedBox(height: 8),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: (from, to) {
            final a = upcoming[from];
            final b = upcoming[to];
            if (a == b || a == view.current || b == view.current) return;
            _edit((api, v) => api.movePlaylistEntry(v, a, b));
          },
          children: [
            for (final (row, i) in upcoming.indexed)
              _row(view, i, row, key: ValueKey('${view.entries[i].game}-$i')),
          ],
        ),
        if (past.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Previous games'),
            children: [for (final i in past) _pastRow(view, i)],
          ),
      ],
    );
  }

  Widget _row(PlaylistView view, int i, int row, {required Key key}) {
    final entry = view.entries[i];
    final playing = view.current == i;
    final badges = [if (playing) 'Playing', if (view.next == entry.game && !playing) 'Up next'];
    return Card(
      key: key,
      child: ListTile(
        onTap: () => _open(view, i),
        leading: playing
            ? const Icon(Icons.play_circle, color: GnColors.ok)
            : ReorderableDragStartListener(
                index: row,
                enabled: !_busy,
                child: const Icon(Icons.drag_indicator, color: GnColors.muted),
              ),
        title: Text(entry.title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: badges.isEmpty ? null : Text(badges.join(' · ')),
        trailing: playing
            ? const Icon(Icons.chevron_right, color: GnColors.muted)
            : IconButton(
                tooltip: 'Remove ${entry.title}',
                icon: const Icon(Icons.close),
                onPressed: _busy ? null : () => _remove(i),
              ),
      ),
    );
  }

  void _remove(int i) => _edit((api, v) => api.removePlaylistEntry(v, i));

  Widget _pastRow(PlaylistView view, int i) {
    final entry = view.entries[i];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: () => _open(view, i),
      title: Text(entry.title, style: const TextStyle(color: GnColors.muted)),
      trailing: TextButton(
        onPressed: _busy ? null : () => _playNext(entry),
        child: const Text('+ Play next'),
      ),
    );
  }

  Future<void> _playNext(PlaylistEntry entry, {bool start = false}) async {
    final controls = roomControlsFor(state);
    if (controls == null) return;
    setState(() => _busy = true);
    try {
      await controls.playNext(entry.game, start: start);
      if (mounted) {
        toast(
            context,
            start
                ? '${entry.title} starts as soon as it has loaded'
                : '${entry.title} will play next');
      }
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
      unawaited(_load());
    }
  }

  void _open(PlaylistView view, int i) {
    final entry = view.entries[i];
    final playing = view.current == i;
    final status = playing
        ? EntryStatus.playing
        : view.next == entry.game
            ? EntryStatus.upNext
            : i < (view.current ?? 0)
                ? EntryStatus.played
                : EntryStatus.queued;
    final current = view.current == null ? null : view.entries[view.current!];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => PlaylistGameSheet(
        entry: entry,
        status: status,
        controls: roomControlsFor(state),
        playingTitle: playing ? null : current?.title,
        onStart: () {
          Navigator.of(sheet).pop();
          _playNext(entry, start: true);
        },
        onPlayNext: () {
          Navigator.of(sheet).pop();
          _playNext(entry);
        },
        onRemove: status == EntryStatus.queued || status == EntryStatus.upNext
            ? () {
                Navigator.of(sheet).pop();
                _remove(i);
              }
            : null,
      ),
    );
  }
}

enum EntryStatus { playing, upNext, queued, played }

/// One game from the playlist: start it now, make it the next game, change
/// its settings, or open its store page.
class PlaylistGameSheet extends StatefulWidget {
  final PlaylistEntry entry;
  final EntryStatus status;
  final RoomControls? controls;

  /// The game on screen, when it is another one: starting ends it.
  final String? playingTitle;

  final VoidCallback onStart;
  final VoidCallback onPlayNext;
  final VoidCallback? onRemove;

  const PlaylistGameSheet({
    super.key,
    required this.entry,
    required this.status,
    required this.controls,
    this.playingTitle,
    required this.onStart,
    required this.onPlayNext,
    this.onRemove,
  });

  @override
  State<PlaylistGameSheet> createState() => _PlaylistGameSheetState();
}

class _PlaylistGameSheetState extends State<PlaylistGameSheet> {
  bool _opening = false;

  PlaylistEntry get entry => widget.entry;

  Future<void> _start() async {
    final other = widget.playingTitle;
    if (other != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('Start ${entry.title} now?'),
          content: Text('This ends $other for everyone as soon as ${entry.title} has loaded.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(dialog).pop(false), child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.of(dialog).pop(true), child: const Text('Start now')),
          ],
        ),
      );
      if (ok != true) return;
    }
    widget.onStart();
  }

  Future<void> _store() async {
    final controls = widget.controls;
    setState(() => _opening = true);
    try {
      final games = await Catalog.instance.games();
      final game = games.where((g) => g.id == entry.game).firstOrNull;
      if (!mounted) return;
      if (game == null) {
        toast(context, '${entry.title} has no page in the store.');
        return;
      }
      // Like the Games tab: in the room, games the host has can be queued again.
      final host = controls == null
          ? const <HostGame>[]
          : await controls.games().catchError((_) => const <HostGame>[]);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => GameDetailScreen(
                game: game,
                games: games,
                host: host.isEmpty ? null : {for (final g in host) g.id: g},
                onAdd: controls == null ? null : _queue,
              )));
    } catch (e) {
      if (mounted) toast(context, e.toString());
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _queue(CatalogGame game) async {
    try {
      await widget.controls!.addToQueue(game.id);
      if (mounted) toast(context, '${game.title} is in the queue');
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    final label = switch (status) {
      EntryStatus.playing => 'Playing now',
      EntryStatus.upNext => 'Up next',
      EntryStatus.queued => 'In the queue',
      EntryStatus.played => 'Played earlier tonight',
    };
    final emptyHint = switch (status) {
      EntryStatus.playing => 'This game has no settings to change.',
      EntryStatus.upNext =>
        'No settings to change yet. They show up here once ${entry.title} has loaded, '
            'if it has any.',
      _ => 'Settings can be changed once ${entry.title} is up next and has loaded. '
          'Choose Play next to load it.',
    };
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(entry.title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(
                  color: status == EntryStatus.playing ? GnColors.ok : GnColors.muted,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: status == EntryStatus.playing || widget.controls == null ? null : _start,
                icon: const Icon(Icons.play_arrow),
                label: Text(status == EntryStatus.playing ? 'Playing' : 'Start now'),
              ),
            ),
            if (status == EntryStatus.queued || status == EntryStatus.played) ...[
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: widget.controls == null ? null : widget.onPlayNext,
                  icon: const Icon(Icons.skip_next),
                  label: const Text('Play next'),
                ),
              ),
            ],
          ]),
          const SizedBox(height: 4),
          SettingsSection(
            key: ValueKey('sheet-settings-${entry.game}'),
            controls: widget.controls,
            game: entry.game,
            title: entry.title,
            showEmpty: true,
            emptyHint: emptyHint,
          ),
          Card(
            child: Column(children: [
              ListTile(
                leading: const Icon(Icons.storefront_outlined),
                title: const Text('View in the store'),
                subtitle: const Text('Videos, screenshots and details'),
                trailing: _opening
                    ? const SizedBox.square(
                        dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.chevron_right),
                onTap: _opening ? null : _store,
              ),
              if (widget.onRemove != null)
                ListTile(
                  leading: const Icon(Icons.remove_circle_outline, color: Color(0xFFF87171)),
                  title: const Text('Remove from the playlist'),
                  onTap: widget.onRemove,
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
