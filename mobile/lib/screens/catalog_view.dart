import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../catalog.dart';
import '../room_controls.dart';
import '../theme.dart';
import 'game_detail_screen.dart';

/// The store catalog as a grid of covers. A tap opens the game's page with
/// its videos and screenshots. In a room, games its host can play get an "Add to queue" button.
class CatalogSection extends StatefulWidget {
  final RoomControls? controls;
  const CatalogSection({super.key, this.controls});

  @override
  State<CatalogSection> createState() => _CatalogSectionState();
}

class _CatalogSectionState extends State<CatalogSection> {
  List<CatalogGame>? _games;
  String? _error;
  Map<String, HostGame> _host = const {};
  final Set<String> _adding = {};
  Timer? _poll;

  bool get _inRoom => widget.controls != null;

  @override
  void initState() {
    super.initState();
    _loadCatalog();
    _loadHost();
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _loadHost());
  }

  @override
  void didUpdateWidget(CatalogSection old) {
    super.didUpdateWidget(old);
    if ((old.controls == null) != (widget.controls == null)) _loadHost();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    setState(() => _error = null);
    try {
      final games = await Catalog.instance.games();
      if (mounted) setState(() => _games = games);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _loadHost() async {
    final controls = widget.controls;
    if (controls == null) {
      if (_host.isNotEmpty) setState(() => _host = const {});
      return;
    }
    try {
      final games = await controls.games();
      if (mounted && widget.controls != null) {
        setState(() => _host = {for (final g in games) g.id: g});
      }
    } on ApiError {
      // Keep what we knew; the next poll tries again.
    }
  }

  Future<void> _add(CatalogGame game) async {
    final controls = widget.controls;
    if (controls == null) return;
    setState(() => _adding.add(game.id));
    try {
      await controls.addToQueue(game.id);
      if (mounted) toast(context, '${game.title} is in the queue');
    } on ApiError catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      if (mounted) setState(() => _adding.remove(game.id));
    }
  }

  void _open(CatalogGame game) => Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GameDetailScreen(
            game: game,
            games: _games ?? const [],
            host: _inRoom && _host.isNotEmpty ? _host : null,
            onAdd: _inRoom ? _add : null,
          )));

  @override
  Widget build(BuildContext context) {
    final games = _games;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(4, 16, 4, 4),
        child: Text('Games', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
        child: Hint(_inRoom
            ? 'Tap a game for videos and screenshots. Games this GameNight has can go into the queue.'
            : 'Everything in the GameNight store. Tap a game for videos and screenshots.'),
      ),
      if (games == null && _error == null)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (games == null)
        Section(children: [
          Hint(_error!),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _loadCatalog, child: const Text('Try again')),
        ])
      else
        _grid(_sorted(games)),
    ]);
  }

  /// In a room, games the host can play first; otherwise store order.
  List<CatalogGame> _sorted(List<CatalogGame> games) {
    if (!_inRoom || _host.isEmpty) return games;
    final playable = [
      for (final g in games)
        if (_host[g.id]?.playable ?? false) g
    ];
    return [
      ...playable,
      for (final g in games)
        if (!playable.contains(g)) g
    ];
  }

  Widget _grid(List<CatalogGame> games) {
    return LayoutBuilder(builder: (context, box) {
      const gap = 12.0;
      final columns = box.maxWidth >= 720 ? 4 : (box.maxWidth >= 480 ? 3 : 2);
      final width = (box.maxWidth - gap * (columns - 1)) / columns;
      // Until the host says which games it has, cards are for browsing only.
      final queueable = _inRoom && _host.isNotEmpty;
      final extent = width * 4 / 3 + (queueable ? 150 : 104);
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: games.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: gap,
          mainAxisSpacing: gap,
          mainAxisExtent: extent,
        ),
        itemBuilder: (context, i) {
          final game = games[i];
          final host = _host[game.id];
          return GameCard(
            key: ValueKey(game.id),
            game: game,
            onOpen: () => _open(game),
            inRoom: queueable,
            playable: host?.playable ?? false,
            adding: _adding.contains(game.id),
            onAdd: () => _add(game),
          );
        },
      );
    });
  }
}

/// One game in the catalog: cover, title, tagline and player count.
class GameCard extends StatelessWidget {
  final CatalogGame game;
  final VoidCallback onOpen;
  final bool inRoom;
  final bool playable;
  final bool adding;
  final VoidCallback? onAdd;

  const GameCard({
    super.key,
    required this.game,
    required this.onOpen,
    this.inRoom = false,
    this.playable = false,
    this.adding = false,
    this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AspectRatio(aspectRatio: 3 / 4, child: GameCover(game: game)),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(game.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(game.tagline,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, color: GnColors.muted, height: 1.25)),
                const Spacer(),
                if (game.players.isNotEmpty)
                  Row(children: [
                    const Icon(Icons.people_alt_outlined, size: 14, color: GnColors.muted),
                    const SizedBox(width: 4),
                    Text(game.players, style: const TextStyle(fontSize: 12, color: GnColors.muted)),
                  ]),
                if (inRoom) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 36,
                    width: double.infinity,
                    child: playable
                        ? FilledButton.icon(
                            style: FilledButton.styleFrom(
                                minimumSize: const Size(0, 36),
                                padding: const EdgeInsets.symmetric(horizontal: 8)),
                            onPressed: adding ? null : onAdd,
                            icon: adding
                                ? const SizedBox.square(
                                    dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.playlist_add, size: 18),
                            label: const Text('Add to queue', maxLines: 1),
                          )
                        : const Center(
                            child: Text('Not on this GameNight',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, color: GnColors.muted)),
                          ),
                  ),
                ],
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

/// The cover art, or a tile in the game's colour when there is none.
class GameCover extends StatelessWidget {
  final CatalogGame game;
  const GameCover({super.key, required this.game});

  @override
  Widget build(BuildContext context) {
    Widget tile(BuildContext context, [Object? _, StackTrace? __]) => ColoredBox(
          color: game.color ?? GnColors.field,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(game.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      shadows: [Shadow(blurRadius: 6, color: Colors.black54)])),
            ),
          ),
        );
    final bytes = game.coverBytes, url = game.coverUrl;
    if (bytes != null) {
      return Image.memory(bytes,
          fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: tile, semanticLabel: game.title);
    }
    if (url != null) {
      return Image.network(url.toString(),
          fit: BoxFit.cover, errorBuilder: tile, semanticLabel: game.title);
    }
    return tile(context);
  }
}
