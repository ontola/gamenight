import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../account.dart';
import 'catalog_filters.dart';
import '../catalog.dart';
import '../room_controls.dart';
import '../theme.dart';
import 'game_detail_screen.dart';

/// The store catalog as a grid of covers. A tap opens the game's page with
/// its videos and screenshots. In a room, games its host can play get an "Add to queue" button.
class CatalogSection extends StatefulWidget {
  final RoomControls? controls;
  final CloudApi? cloud;
  final Future<void> Function()? onSignIn;
  final String? requestedGame;
  final VoidCallback? onRequestedGameOpened;
  const CatalogSection(
      {super.key,
      this.controls,
      this.cloud,
      this.onSignIn,
      this.requestedGame,
      this.onRequestedGameOpened});

  @override
  State<CatalogSection> createState() => _CatalogSectionState();
}

class _CatalogSectionState extends State<CatalogSection> {
  List<CatalogGame>? _games;
  String? _error;
  Map<String, HostGame> _host = const {};
  final Set<String> _adding = {};
  Timer? _poll;
  String? _openedRequest;
  bool _hostLoaded = false;
  CatalogFilter _filter = const CatalogFilter();
  String? _filterAccount;

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
    if (_filterAccount != widget.cloud?.token) {
      _filterAccount = widget.cloud?.token;
      _filter = CatalogFilter(tags: _filter.tags);
    }
    _openRequestedGame();
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
      if (mounted) {
        setState(() => _games = games);
        _openRequestedGame();
      }
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
        setState(() {
          _host = {for (final g in games) g.id: g};
          _hostLoaded = true;
        });
        _openRequestedGame();
      }
    } on ApiError {
      // Keep what we knew; the next poll tries again.
    }
  }

  void _openRequestedGame() {
    final wanted = widget.requestedGame;
    if (wanted == null ||
        wanted == _openedRequest ||
        _games == null ||
        !_inRoom ||
        !_hostLoaded) {
      return;
    }
    _openedRequest = wanted;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onRequestedGameOpened?.call();
      final matches = _games!.where((game) => game.id == wanted);
      if (matches.isEmpty) {
        toast(context, 'This game is no longer in the catalog.');
        return;
      }
      _open(matches.first);
    });
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
            games: _visible,
            onTagSelected: (tag) {
              setState(() => _filter = CatalogFilter(tags: {tag}));
              Navigator.of(context).pop();
              Scrollable.ensureVisible(context,
                  duration: const Duration(milliseconds: 250));
            },
            host: _inRoom && _host.isNotEmpty ? _host : null,
            onAdd: _inRoom ? _add : null,
          )));

  @override
  Widget build(BuildContext context) {
    final games = _games;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                  onPressed: games == null ? null : _showFilters,
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('Filter')),
              if (_filter.liked)
                InputChip(
                    label: const Text('Liked'),
                    onPressed: () => setState(
                        () => _filter = _filter.copyWith(liked: false)),
                    onDeleted: () => setState(
                        () => _filter = _filter.copyWith(liked: false))),
              if (_filter.unplayed)
                InputChip(
                    label: const Text('Not played'),
                    onPressed: () => setState(
                        () => _filter = _filter.copyWith(unplayed: false)),
                    onDeleted: () => setState(
                        () => _filter = _filter.copyWith(unplayed: false))),
              for (final tag in _filter.tags)
                InputChip(
                    label: Text(tag),
                    onPressed: () => setState(() => _filter =
                        _filter.copyWith(tags: {..._filter.tags}..remove(tag))),
                    onDeleted: () => setState(() => _filter = _filter.copyWith(
                        tags: {..._filter.tags}..remove(tag)))),
              if (_filter.active)
                Text(
                    '${_visible.length} ${_visible.length == 1 ? 'game' : 'games'}',
                    style: const TextStyle(color: GnColors.muted)),
            ]),
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
          OutlinedButton(
              onPressed: _loadCatalog, child: const Text('Try again')),
        ])
      else if (_visible.isEmpty)
        Section(children: [
          const Text('No games match these filters.'),
          TextButton(
              onPressed: () => setState(() => _filter = const CatalogFilter()),
              child: const Text('Clear filters'))
        ])
      else
        _grid(_visible),
    ]);
  }

  List<CatalogGame> get _visible =>
      _sorted((_games ?? const []).where(_filter.matches).toList());

  Future<void> _showFilters() async {
    final filter = await showModalBottomSheet<CatalogFilter>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        constraints: const BoxConstraints(maxWidth: 560),
        builder: (_) => CatalogFilters(
            filter: _filter,
            games: _games!,
            cloud: widget.cloud,
            onSignIn: widget.onSignIn));
    if (mounted && filter != null) {
      setState(() {
        _filter = filter;
        _filterAccount = widget.cloud?.token;
      });
    }
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
      final columns = box.maxWidth >= 1200
          ? 6
          : box.maxWidth >= 960
              ? 5
              : box.maxWidth >= 720
                  ? 4
                  : (box.maxWidth >= 480 ? 3 : 2);
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
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AspectRatio(aspectRatio: 3 / 4, child: GameCover(game: game)),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(game.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(game.tagline,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12.5,
                            color: GnColors.muted,
                            height: 1.25)),
                    const Spacer(),
                    if (game.players.isNotEmpty)
                      Row(children: [
                        const Icon(Icons.people_alt_outlined,
                            size: 14, color: GnColors.muted),
                        const SizedBox(width: 4),
                        Text(game.players,
                            style: const TextStyle(
                                fontSize: 12, color: GnColors.muted)),
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
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8)),
                                onPressed: adding ? null : onAdd,
                                icon: adding
                                    ? const SizedBox.square(
                                        dimension: 14,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2))
                                    : const Icon(Icons.playlist_add, size: 18),
                                label: const Text('Add to queue', maxLines: 1),
                              )
                            : const Center(
                                child: Text('Not on this GameNight',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 12, color: GnColors.muted)),
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
    Widget tile(BuildContext context, [Object? _, StackTrace? __]) =>
        ColoredBox(
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
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: tile,
          semanticLabel: game.title);
    }
    if (url != null) {
      return Image.network(url.toString(),
          fit: BoxFit.cover, errorBuilder: tile, semanticLabel: game.title);
    }
    return tile(context);
  }
}
