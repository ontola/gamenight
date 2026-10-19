import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../account.dart';
import 'catalog_filters.dart';
import '../catalog.dart';
import '../room_controls.dart';
import '../theme.dart';
import 'game_detail_screen.dart';
import '../navigation/open_website.dart';

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

  /// Games this account develops: they get a Manage game button, a My games
  /// filter, and the unreviewed ones join the list for that filter.
  List<CatalogGame> _mine = const [];
  Set<String> get _developing => {for (final game in _mine) game.id};
  String? _developingAccount;
  CatalogFilter _filter = const CatalogFilter();
  String? _filterAccount;
  final _search = TextEditingController();
  bool _personalLoading = false;

  bool get _inRoom => widget.controls != null;

  @override
  void initState() {
    super.initState();
    _loadCatalog();
    _loadHost();
    _loadDeveloping();
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _loadHost());
  }

  @override
  void didUpdateWidget(CatalogSection old) {
    super.didUpdateWidget(old);
    if ((old.controls == null) != (widget.controls == null)) _loadHost();
    _loadDeveloping();
    if (_filterAccount != widget.cloud?.token) {
      _filterAccount = widget.cloud?.token;
      _filter = CatalogFilter(
          tags: _filter.tags, query: _filter.query, players: _filter.players);
    }
    _openRequestedGame();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _search.dispose();
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

  Future<void> _loadDeveloping() async {
    final cloud = widget.cloud;
    final account = cloud?.token;
    if (account == _developingAccount) return;
    _developingAccount = account;
    if (cloud == null || account == null) {
      if (_mine.isNotEmpty) {
        setState(() {
          _mine = const [];
          _filter = _filter.copyWith(mine: false, mineGames: const {});
        });
      }
      return;
    }
    try {
      final games = await cloud.developerGames();
      if (mounted && cloud.token == account) {
        setState(() {
          _mine = games;
          _filter = _filter.copyWith(mineGames: _developing);
        });
      }
    } on ApiError {
      // Not a developer, or offline: no Manage buttons.
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

  void _open(CatalogGame game) {
    // Popping back restores the catalog's last focus; without this the
    // search field grabs focus (and the keyboard) again.
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => GameDetailScreen(
              game: game,
              games: _visible,
              onTagSelected: (tag) {
                _search.clear();
                setState(() => _filter = CatalogFilter(tags: {tag}));
                Navigator.of(context).pop();
                Scrollable.ensureVisible(context,
                    duration: const Duration(milliseconds: 250));
              },
              host: _inRoom && _host.isNotEmpty ? _host : null,
              onAdd: _inRoom ? _add : null,
              developing: _developing,
              cloud: widget.cloud,
              onManage: (game) => openWebsite(widget.cloud!,
                  '/developers#game/${Uri.encodeComponent(game.id)}'),
            )));
  }

  @override
  Widget build(BuildContext context) {
    final games = _games;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _filterBar(games != null)),
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
              onPressed: _clearFilters, child: const Text('Clear filters'))
        ])
      else
        _grid(_visible),
    ]);
  }

  void _clearFilters() => setState(() {
        _search.clear();
        _filter = const CatalogFilter();
      });

  void _setFilter(CatalogFilter filter) => setState(() => _filter = filter);

  /// Search always; player count, then Liked and Not played join the bar
  /// as it gets wider. What does not fit stays in the Filter sheet.
  Widget _filterBar(bool ready) => LayoutBuilder(builder: (context, box) {
        final showPlayers = box.maxWidth >= 560;
        final showPersonal = box.maxWidth >= 820;
        final search = SizedBox(
            height: 44,
            child: TextField(
              key: const ValueKey('catalog-search'),
              controller: _search,
              enabled: ready,
              textInputAction: TextInputAction.search,
              onChanged: (v) => _setFilter(_filter.copyWith(query: v)),
              decoration: InputDecoration(
                hintText: 'Search games',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _filter.query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _search.clear();
                          _setFilter(_filter.copyWith(query: ''));
                        }),
                contentPadding: EdgeInsets.zero,
              ),
            ));
        final chips = [
          if (_mine.isNotEmpty)
            FilterChip(
                key: const ValueKey('my-games'),
                label: const Text('My games'),
                selected: _filter.mine,
                onSelected: (v) => _setFilter(
                    _filter.copyWith(mine: v, mineGames: _developing))),
          if (_filter.liked && !showPersonal)
            InputChip(
                label: const Text('Liked'),
                onPressed: () => _setFilter(_filter.copyWith(liked: false)),
                onDeleted: () => _setFilter(_filter.copyWith(liked: false))),
          if (_filter.unplayed && !showPersonal)
            InputChip(
                label: const Text('Not played'),
                onPressed: () => _setFilter(_filter.copyWith(unplayed: false)),
                onDeleted: () => _setFilter(_filter.copyWith(unplayed: false))),
          if (_filter.players != null && !showPlayers)
            InputChip(
                label: Text('${_filter.players} players'),
                onPressed: () =>
                    _setFilter(_filter.copyWith(players: () => null)),
                onDeleted: () =>
                    _setFilter(_filter.copyWith(players: () => null))),
          for (final tag in _filter.tags)
            InputChip(
                label: Text(tag),
                onPressed: () => _setFilter(
                    _filter.copyWith(tags: {..._filter.tags}..remove(tag))),
                onDeleted: () => _setFilter(
                    _filter.copyWith(tags: {..._filter.tags}..remove(tag)))),
          if (_filter.active)
            Text(
                '${_visible.length} ${_visible.length == 1 ? 'game' : 'games'}',
                style: const TextStyle(color: GnColors.muted)),
        ];
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                if (showPlayers)
                  ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: search)
                else
                  Expanded(child: search),
                if (showPlayers) ...[
                  const SizedBox(width: 8),
                  _playersButton(ready),
                ],
                if (showPersonal) ...[
                  const SizedBox(width: 8),
                  _personalChip('Liked', Icons.thumb_up_outlined, _filter.liked,
                      (v) => _filter.copyWith(liked: v)),
                  const SizedBox(width: 8),
                  _personalChip('Not played', null, _filter.unplayed,
                      (v) => _filter.copyWith(unplayed: v)),
                ],
                if (showPlayers) const Spacer() else const SizedBox(width: 8),
                OutlinedButton.icon(
                    onPressed: ready ? _showFilters : null,
                    icon: const Icon(Icons.tune, size: 18),
                    label: const Text('Filter')),
              ]),
              if (chips.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: chips)),
            ]);
      });

  Widget _playersButton(bool ready) {
    final n = _filter.players;
    return PopupMenuButton<int>(
      enabled: ready,
      tooltip: 'Player count',
      initialValue: n ?? 0,
      onSelected: (v) =>
          _setFilter(_filter.copyWith(players: () => v == 0 ? null : v)),
      itemBuilder: (_) => [
        const PopupMenuItem(value: 0, child: Text('Any number of players')),
        for (final count in playerCounts)
          PopupMenuItem(
              value: count,
              child: Text(count == 1 ? '1 player' : '$count players')),
      ],
      child: IgnorePointer(
        child: OutlinedButton.icon(
          style: n == null
              ? null
              : OutlinedButton.styleFrom(
                  backgroundColor: GnColors.button.withValues(alpha: .35),
                  side: const BorderSide(color: GnColors.accent)),
          onPressed: ready ? () {} : null,
          icon: const Icon(Icons.group_outlined, size: 18),
          label: Text(n == null
              ? 'Players'
              : n == 1
                  ? '1 player'
                  : '$n players'),
        ),
      ),
    );
  }

  /// Liked and Not played need the account's ratings and play history,
  /// loaded on first use. Signed out, a tap offers sign-in instead.
  Widget _personalChip(String label, IconData? icon, bool selected,
          CatalogFilter Function(bool) apply) =>
      FilterChip(
        label: Text(label),
        avatar: icon == null || selected ? null : Icon(icon, size: 18),
        selected: selected,
        onSelected: _games == null || _personalLoading
            ? null
            : (v) async {
                if (!v) return _setFilter(apply(false));
                if (widget.cloud?.signedIn != true) {
                  await widget.onSignIn?.call();
                  if (!mounted || widget.cloud?.signedIn != true) return;
                }
                final personal = await _loadPersonal();
                if (personal == null || !mounted) return;
                _setFilter(apply(true).copyWith(
                    likedGames: personal.liked, playedGames: personal.played));
                _filterAccount = widget.cloud?.token;
              },
      );

  Future<({Set<String> liked, Set<String> played})?> _loadPersonal() async {
    final cloud = widget.cloud!, identity = cloud.token;
    setState(() => _personalLoading = true);
    try {
      final results =
          await Future.wait<Object>([cloud.gameRatings(), cloud.playHistory()]);
      if (cloud.token != identity) return null;
      final ratings = results[0] as Map<String, int>;
      final history = results[1] as ({Set<String> games, int days});
      return (
        liked: {
          for (final entry in ratings.entries)
            if (entry.value == 1) entry.key
        },
        played: history.games
      );
    } catch (_) {
      if (mounted) {
        toast(context, 'Could not load your likes and play history.');
      }
      return null;
    } finally {
      if (mounted) setState(() => _personalLoading = false);
    }
  }

  List<CatalogGame> get _visible {
    final store = _games ?? const <CatalogGame>[];
    final listed = {for (final game in store) game.id};
    // Unreviewed games are not in the store yet; the filter shows them only
    // under My games.
    return _sorted([
      ...store,
      for (final game in _mine)
        if (!listed.contains(game.id)) game,
    ].where(_filter.matches).toList());
  }

  Future<void> _showFilters() async {
    FocusManager.instance.primaryFocus?.unfocus();
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
