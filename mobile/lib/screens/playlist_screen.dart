import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../app_state.dart';
import '../theme.dart';

/// Tonight's queue: drag to reorder, remove, or replay an earlier game.
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
          if (_busy) const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
        const SizedBox(height: 4),
        Hint(view.entries.isEmpty
            ? 'No games queued yet.'
            : 'Drag a game to change the order. Everyone on this GameNight sees the same queue.'),
        const SizedBox(height: 8),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorder: (from, to) {
            final a = upcoming[from];
            if (to > from) to -= 1;
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
            ? null
            : IconButton(
                tooltip: 'Remove ${entry.title}',
                icon: const Icon(Icons.close),
                onPressed: _busy ? null : () => _edit((api, v) => api.removePlaylistEntry(v, i)),
              ),
      ),
    );
  }

  Widget _pastRow(PlaylistView view, int i) {
    final entry = view.entries[i];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(entry.title, style: const TextStyle(color: GnColors.muted)),
      trailing: TextButton(
        onPressed: _busy
            ? null
            : () async {
                try {
                  await state.api!.playNext(entry.game, state.profileId, state.newRequestId());
                  if (mounted) toast(context, '${entry.title} will play next');
                  unawaited(_load());
                } on ApiError catch (e) {
                  if (mounted) toast(context, e.message);
                }
              },
        child: const Text('+ Play next'),
      ),
    );
  }
}
