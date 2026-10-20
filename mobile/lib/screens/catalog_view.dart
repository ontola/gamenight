import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../account.dart';
import '../app_state.dart';
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

  /// The player's Want to play list and play history; none without it.
  final AppState? state;

  /// Shows only this developer's games, without the search and filters.
  final String? developer;
  const CatalogSection(
      {super.key,
      this.controls,
      this.cloud,
      this.onSignIn,
      this.requestedGame,
      this.onRequestedGameOpened,
      this.state,
      this.developer});

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
  late CatalogFilter _filter = CatalogFilter(developer: widget.developer);
  CatalogSort _sort = CatalogSort.store;
  Map<String, ({int up, int down})> _ratings = const {};
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
    _loadRatings();
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
          tags: _filter.tags,
          query: _filter.query,
          players: _filter.players,
          developer: _filter.developer);
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

  Future<void> _loadRatings() async {
    try {
      final ratings = await widget.cloud?.ratingTotals();
      if (mounted && ratings != null) setState(() => _ratings = ratings);
    } catch (_) {
      // Like ratio sorting falls back to store order.
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
              state: widget.state,
              onDeveloper: widget.developer == null ? _openDeveloper : null,
              onManage: (game) => openWebsite(widget.cloud!,
                  '/developers#game/${Uri.encodeComponent(game.id)}'),
            )));
  }

  void _openDeveloper(String developer) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
            appBar: AppBar(title: Text(developer)),
            body: SafeArea(
                top: false,
                child: ListView(padding: const EdgeInsets.all(16), children: [
                  CatalogSection(
                      key: ValueKey('developer-$developer'),
                      cloud: widget.cloud,
                      controls: widget.controls,
                      onSignIn: widget.onSignIn,
                      state: widget.state,
                      developer: developer),
                ])))));
  }

  @override
  Widget build(BuildContext context) {
    final games = _games;
    final developer = widget.developer;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (developer != null)
        Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
                games == null
                    ? 'Games by $developer'
                    : '${_visible.length} ${_visible.length == 1 ? 'game' : 'games'} by $developer',
                style: const TextStyle(color: GnColors.muted)))
      else
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
        _filter = CatalogFilter(developer: widget.developer);
      });

  Set<String> get _wanted => {...?widget.state?.wantToPlay};

  void _setFilter(CatalogFilter filter) => setState(() => _filter = filter);

  /// One row: search, then the quick filters that fit, then Sort and
  /// Filter. Quick filters that do not fit live in the Filter sheet, and
  /// the Filter button counts the active filters the row does not show.
  Widget _filterBar(bool ready) => LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= 560;
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
        final n = _filter.players;
        // In order of priority: the first ones get the room first.
        final quick = <({String label, bool active, Widget button})>[
          if (_wanted.isNotEmpty || _filter.wanted)
            (
              label: 'Want to play',
              active: _filter.wanted,
              button: _BarButton(
                  key: const ValueKey('want-to-play'),
                  icon: Icons.bookmark_border,
                  label: 'Want to play',
                  selected: _filter.wanted,
                  onPressed: ready
                      ? () => _setFilter(_filter.copyWith(
                          wanted: !_filter.wanted, wantedGames: _wanted))
                      : null),
            ),
          if (_mine.isNotEmpty)
            (
              label: 'My games',
              active: _filter.mine,
              button: _BarButton(
                  key: const ValueKey('my-games'),
                  icon: Icons.code,
                  label: 'My games',
                  selected: _filter.mine,
                  onPressed: ready
                      ? () => _setFilter(_filter.copyWith(
                          mine: !_filter.mine, mineGames: _developing))
                      : null),
            ),
          (
            label: n == null ? 'Players' : '$n players',
            active: n != null,
            button: _playersButton(ready),
          ),
          (
            label: 'Liked',
            active: _filter.liked,
            button: _personalButton('Liked', Icons.thumb_up_outlined,
                _filter.liked, (v) => _filter.copyWith(liked: v)),
          ),
          (
            label: 'Not played',
            active: _filter.unplayed,
            button: _personalButton('Not played', Icons.history,
                _filter.unplayed, (v) => _filter.copyWith(unplayed: v)),
          ),
        ];
        // Search keeps at least this much; Sort and Filter always fit.
        final searchMin = wide ? 260.0 : 120.0;
        final sortLabel = wide ? _sortLabel : null;
        var room = box.maxWidth -
            searchMin -
            _BarButton.widthOf(context, sortLabel) -
            _BarButton.widthOf(context, wide ? 'Filter 9' : null) -
            16;
        final shown = <({String label, bool active, Widget button})>[];
        if (wide) {
          for (final item in quick) {
            final width = _BarButton.widthOf(context, item.label) + 8;
            if (width > room) break;
            room -= width;
            shown.add(item);
          }
        }
        final hidden = _filter.tags.length +
            (_filter.played ? 1 : 0) +
            (_filter.developer != null ? 1 : 0) +
            quick.where((q) => q.active && !shown.contains(q)).length;
        return SizedBox(
            height: 44,
            child: Row(children: [
              Expanded(
                  child: Align(
                      alignment: Alignment.centerLeft,
                      child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 400),
                          child: search))),
              for (final item in shown) ...[
                const SizedBox(width: 8),
                item.button,
              ],
              const SizedBox(width: 8),
              _sortButton(ready, sortLabel),
              const SizedBox(width: 8),
              _BarButton(
                  icon: Icons.tune,
                  label: wide ? 'Filter' : null,
                  tooltip: 'Filter',
                  count: hidden,
                  selected: hidden > 0,
                  onPressed: ready ? _showFilters : null),
            ]));
      });

  String get _sortLabel => _sort == CatalogSort.store ? 'Sort' : _sort.short;

  Widget _sortButton(bool ready, String? label) {
    final signedIn = widget.cloud?.signedIn == true;
    return PopupMenuButton<CatalogSort>(
      key: const ValueKey('catalog-sort'),
      enabled: ready,
      tooltip: 'Sort games',
      initialValue: _sort,
      onSelected: (sort) => setState(() => _sort = sort),
      itemBuilder: (_) => [
        for (final sort in CatalogSort.values)
          if (sort != CatalogSort.lastPlayed || signedIn)
            PopupMenuItem(value: sort, child: Text(sort.label)),
      ],
      child: IgnorePointer(
          child: _BarButton(
              icon: Icons.sort,
              label: label,
              name: 'Sort',
              selected: _sort != CatalogSort.store,
              onPressed: ready ? () {} : null)),
    );
  }

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
        child: _BarButton(
            icon: Icons.group_outlined,
            label: n == null
                ? 'Players'
                : n == 1
                    ? '1 player'
                    : '$n players',
            selected: n != null,
            onPressed: ready ? () {} : null),
      ),
    );
  }

  /// Liked and Not played need the account's ratings and play history,
  /// loaded on first use. Signed out, a tap offers sign-in instead.
  Widget _personalButton(String label, IconData icon, bool selected,
          CatalogFilter Function(bool) apply) =>
      _BarButton(
        icon: icon,
        label: label,
        selected: selected,
        onPressed: _games == null || _personalLoading
            ? null
            : () async {
                if (selected) return _setFilter(apply(false));
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
          await Future.wait<Object>([cloud.gameRatings(), cloud.lastPlayed()]);
      if (cloud.token != identity) return null;
      final ratings = results[0] as Map<String, int>;
      final played = results[1] as Map<String, int>;
      return (
        liked: {
          for (final entry in ratings.entries)
            if (entry.value == 1) entry.key
        },
        played: played.keys.toSet()
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
            onSignIn: widget.onSignIn,
            wantedGames: _wanted));
    if (mounted && filter != null) {
      setState(() {
        _filter = filter;
        _filterAccount = widget.cloud?.token;
      });
    }
  }

  /// The chosen order; in store order, games the room's host can play
  /// come first.
  List<CatalogGame> _sorted(List<CatalogGame> games) {
    final played = widget.state?.lastPlayed ?? const <String, int>{};
    double ratio(CatalogGame g) {
      final r = _ratings[g.id];
      final votes = (r?.up ?? 0) + (r?.down ?? 0);
      return votes == 0 ? -1 : r!.up / votes;
    }

    int votes(CatalogGame g) =>
        (_ratings[g.id]?.up ?? 0) + (_ratings[g.id]?.down ?? 0);
    int by<T extends Comparable<Object>>(
            T? Function(CatalogGame) key, CatalogGame a, CatalogGame b) =>
        switch ((key(a), key(b))) {
          (null, null) => 0,
          (null, _) => 1,
          (_, null) => -1,
          (final x?, final y?) => y.compareTo(x),
        };
    final order = switch (_sort) {
      CatalogSort.store => null,
      CatalogSort.newest => (CatalogGame a, CatalogGame b) =>
          by((g) => g.added, a, b),
      CatalogSort.updated => (CatalogGame a, CatalogGame b) =>
          by((g) => g.updated, a, b),
      CatalogSort.lastPlayed => (CatalogGame a, CatalogGame b) =>
          by((g) => played[g.id], a, b),
      CatalogSort.title => (CatalogGame a, CatalogGame b) =>
          a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      CatalogSort.liked => (CatalogGame a, CatalogGame b) {
          final r = ratio(b).compareTo(ratio(a));
          return r != 0 ? r : votes(b).compareTo(votes(a));
        },
    };
    if (order != null) {
      // A stable sort keeps store order between equals.
      final indexed = [for (var i = 0; i < games.length; i++) (i, games[i])];
      indexed.sort((a, b) {
        final c = order(a.$2, b.$2);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
      return [for (final e in indexed) e.$2];
    }
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

/// The look every control in the catalog's filter row shares: as tall as
/// the search field, outlined, and accent-coloured while it filters or
/// sorts. Without a label it is a square icon button.
class _BarButton extends StatelessWidget {
  final IconData icon;
  final String? label, tooltip;

  /// What screen readers call an icon-only button; [tooltip] by default.
  final String? name;
  final bool selected;

  /// Shown as a badge after the label when above zero.
  final int count;
  final VoidCallback? onPressed;
  const _BarButton(
      {super.key,
      required this.icon,
      this.label,
      this.tooltip,
      this.name,
      this.selected = false,
      this.count = 0,
      required this.onPressed});

  static const _text = TextStyle(fontSize: 14, fontWeight: FontWeight.w600);

  /// How wide a button with this label is drawn, to see what fits.
  static double widthOf(BuildContext context, String? label) {
    if (label == null) return 44;
    final painter = TextPainter(
        text: TextSpan(text: label, style: _text),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context))
      ..layout();
    return 12 + 18 + 8 + painter.width + 16 + 2;
  }

  @override
  Widget build(BuildContext context) {
    final style = OutlinedButton.styleFrom(
      minimumSize: const Size(44, 44),
      maximumSize: const Size(double.infinity, 44),
      padding: label == null
          ? EdgeInsets.zero
          : const EdgeInsets.only(left: 12, right: 16),
      textStyle: _text,
      backgroundColor: selected ? GnColors.button.withValues(alpha: .35) : null,
      side: selected ? const BorderSide(color: GnColors.accent) : null,
    );
    // Screen readers hear the count as the button's value.
    final badge = count > 0
        ? ExcludeSemantics(
            child: Container(
                constraints: const BoxConstraints(minWidth: 18),
                height: 18,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: GnColors.accent,
                    borderRadius: BorderRadius.circular(9)),
                child: Text('$count',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.white))))
        : null;
    final Widget button;
    if (label == null) {
      button = OutlinedButton(
          style: style,
          onPressed: onPressed,
          child: Stack(clipBehavior: Clip.none, children: [
            // Icon-only buttons still read as Sort or Filter.
            Icon(icon, size: 20, semanticLabel: name ?? tooltip),
            if (badge != null) Positioned(right: -12, top: -10, child: badge),
          ]));
    } else {
      button = OutlinedButton(
          style: style,
          onPressed: onPressed,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 18),
            const SizedBox(width: 8),
            Text(label!),
            if (badge != null) ...[const SizedBox(width: 6), badge],
          ]));
    }
    final semantics = Semantics(
        selected: selected,
        value: count > 0 ? '$count active' : null,
        child: button);
    return label == null && tooltip != null
        ? Tooltip(
            message: tooltip!, excludeFromSemantics: true, child: semantics)
        : semantics;
  }
}
