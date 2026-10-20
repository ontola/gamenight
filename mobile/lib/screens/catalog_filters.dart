import 'package:flutter/material.dart';

import '../account.dart';
import '../catalog.dart';
import '../theme.dart';

class CatalogFilter {
  final bool liked, unplayed, played, wanted;

  /// Only games by this developer, as the store names them.
  final String? developer;

  /// Only games this account develops, in the store or not.
  final bool mine;
  final Set<String> tags, likedGames, playedGames, mineGames, wantedGames;

  /// Words to find in a game's title, tagline, developer or tags.
  final String query;

  /// Only games that can be played with exactly this many players.
  final int? players;
  const CatalogFilter(
      {this.liked = false,
      this.unplayed = false,
      this.played = false,
      this.wanted = false,
      this.wantedGames = const {},
      this.developer,
      this.mine = false,
      this.mineGames = const {},
      this.tags = const {},
      this.likedGames = const {},
      this.playedGames = const {},
      this.query = '',
      this.players});
  bool get active =>
      liked ||
      unplayed ||
      played ||
      wanted ||
      developer != null ||
      mine ||
      tags.isNotEmpty ||
      query.trim().isNotEmpty ||
      players != null;
  bool matches(CatalogGame game) =>
      (!liked || likedGames.contains(game.id)) &&
      (!unplayed || !playedGames.contains(game.id)) &&
      (!played || playedGames.contains(game.id)) &&
      (!wanted || wantedGames.contains(game.id)) &&
      (developer == null || game.developer == developer) &&
      (mine ? mineGames.contains(game.id) : !game.unreviewed) &&
      (tags.isEmpty || tags.any(game.tags.contains)) &&
      _fits(game) &&
      _found(game);
  bool _fits(CatalogGame game) {
    final n = players;
    if (n == null) return true;
    final min = game.minPlayers ?? game.maxPlayers;
    final max = game.maxPlayers ?? game.minPlayers;
    return min == null || max == null || (min <= n && n <= max);
  }

  bool _found(CatalogGame game) {
    final text = [game.title, game.tagline, game.developer, ...game.tags]
        .join(' ')
        .toLowerCase();
    return query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .every(text.contains);
  }

  CatalogFilter copyWith(
          {bool? liked,
          bool? unplayed,
          bool? played,
          bool? wanted,
          Set<String>? wantedGames,
          String? Function()? developer,
          bool? mine,
          Set<String>? mineGames,
          Set<String>? tags,
          Set<String>? likedGames,
          Set<String>? playedGames,
          String? query,
          int? Function()? players}) =>
      CatalogFilter(
          liked: liked ?? this.liked,
          unplayed: unplayed ?? this.unplayed,
          played: played ?? this.played,
          wanted: wanted ?? this.wanted,
          wantedGames: wantedGames ?? this.wantedGames,
          developer: developer == null ? this.developer : developer(),
          mine: mine ?? this.mine,
          mineGames: mineGames ?? this.mineGames,
          tags: tags ?? this.tags,
          likedGames: likedGames ?? this.likedGames,
          playedGames: playedGames ?? this.playedGames,
          query: query ?? this.query,
          players: players == null ? this.players : players());
}

/// How the store orders its games.
enum CatalogSort {
  store('Featured', 'Featured'),
  newest('Newest', 'Newest'),
  updated('Recently updated', 'Updated'),
  lastPlayed('Last played by you', 'Last played'),
  title('A to Z', 'A–Z'),
  liked('Most liked', 'Liked');

  /// In the menu, and on the sort button once chosen.
  final String label, short;
  const CatalogSort(this.label, this.short);
}

/// The player counts the filters offer.
const playerCounts = [1, 2, 3, 4, 5, 6, 8];

class CatalogFilters extends StatefulWidget {
  final CatalogFilter filter;
  final List<CatalogGame> games;
  final CloudApi? cloud;
  final Future<void> Function()? onSignIn;

  /// The games this player wants to play, when known.
  final Set<String> wantedGames;
  const CatalogFilters(
      {super.key,
      required this.filter,
      required this.games,
      this.cloud,
      this.onSignIn,
      this.wantedGames = const {}});
  @override
  State<CatalogFilters> createState() => _CatalogFiltersState();
}

class _CatalogFiltersState extends State<CatalogFilters> {
  late bool _liked = widget.filter.liked,
      _unplayed = widget.filter.unplayed,
      _played = widget.filter.played,
      _wanted = widget.filter.wanted,
      _mine = widget.filter.mine;
  late final Set<String> _tags = {...widget.filter.tags};
  late int? _players = widget.filter.players;
  Set<String> _likedGames = {}, _playedGames = {};
  bool _loading = false, _loaded = false;
  String? _error;
  bool get _signedIn => widget.cloud?.signedIn == true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_signedIn) return;
    setState(() {
      _loading = true;
      _error = null;
      _loaded = false;
    });
    try {
      final cloud = widget.cloud!, identity = widget.cloud!.token;
      final results =
          await Future.wait<Object>([cloud.gameRatings(), cloud.lastPlayed()]);
      if (!mounted || cloud.token != identity) return;
      final ratings = results[0] as Map<String, int>;
      final played = results[1] as Map<String, int>;
      setState(() {
        _likedGames = {
          for (final entry in ratings.entries)
            if (entry.value == 1) entry.key
        };
        _playedGames = played.keys.toSet();
        _loaded = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not load your likes and play history.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  CatalogFilter get _selection => CatalogFilter(
      liked: _liked,
      unplayed: _unplayed,
      played: _played,
      wanted: _wanted,
      wantedGames: widget.wantedGames,
      developer: widget.filter.developer,
      mine: _mine,
      mineGames: widget.filter.mineGames,
      tags: _tags,
      likedGames: _likedGames,
      playedGames: _playedGames,
      query: widget.filter.query,
      players: _players);

  @override
  Widget build(BuildContext context) {
    final tags = widget.games.expand((game) => game.tags).toSet().toList()
      ..sort();
    final ready = !(_liked || _unplayed || _played) || _loaded;
    return SafeArea(
        child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .75,
      child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Expanded(
                  child: Text('Filter games',
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w700))),
              TextButton(
                  onPressed: () => setState(() {
                        _liked = false;
                        _unplayed = false;
                        _played = false;
                        _wanted = false;
                        _mine = false;
                        _players = null;
                        _tags.clear();
                      }),
                  child: const Text('Clear')),
            ]),
            Expanded(
                child: ListView(children: [
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilterChip(
                    label: const Text('Liked'),
                    avatar: const Icon(Icons.thumb_up_outlined, size: 18),
                    selected: _liked,
                    onSelected:
                        _loaded ? (v) => setState(() => _liked = v) : null),
                FilterChip(
                    label: const Text('Want to play'),
                    avatar: const Icon(Icons.bookmark_border, size: 18),
                    selected: _wanted,
                    onSelected:
                        _signedIn ? (v) => setState(() => _wanted = v) : null),
                if (widget.filter.mineGames.isNotEmpty)
                  FilterChip(
                      label: const Text('My games'),
                      avatar: const Icon(Icons.code, size: 18),
                      selected: _mine,
                      onSelected: (v) => setState(() => _mine = v)),
                FilterChip(
                    label: const Text('Played'),
                    selected: _played,
                    onSelected: _loaded
                        ? (v) => setState(() {
                              _played = v;
                              if (v) _unplayed = false;
                            })
                        : null),
                FilterChip(
                    label: const Text('Not played'),
                    selected: _unplayed,
                    onSelected: _loaded
                        ? (v) => setState(() {
                              _unplayed = v;
                              if (v) _played = false;
                            })
                        : null),
              ]),
              if (_loading)
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator()),
              if (!_signedIn) ...[
                const Hint('Sign in to filter by your likes and play history.'),
                if (widget.onSignIn != null)
                  Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                          onPressed: () async {
                            await widget.onSignIn!();
                            if (mounted) {
                              setState(() {});
                              await _load();
                            }
                          },
                          child: const Text('Sign in'))),
              ] else if (_error != null) ...[
                Text(_error!, style: const TextStyle(color: GnColors.warn)),
                Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                        onPressed: _load, child: const Text('Try again'))),
              ],
              const SizedBox(height: 24),
              const Text('Players',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final n in playerCounts)
                  ChoiceChip(
                      label: Text('$n'),
                      selected: _players == n,
                      onSelected: (v) =>
                          setState(() => _players = v ? n : null)),
              ]),
              const SizedBox(height: 24),
              const Text('Tags', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Hint('Match any selected tag.'),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final tag in tags)
                  FilterChip(
                      label: Text(tag),
                      selected: _tags.contains(tag),
                      onSelected: (v) => setState(() {
                            v ? _tags.add(tag) : _tags.remove(tag);
                          })),
              ]),
              const SizedBox(height: 16),
            ])),
            FilledButton(
                onPressed:
                    ready ? () => Navigator.pop(context, _selection) : null,
                child: Text(ready
                    ? 'Show ${widget.games.where(_selection.matches).length} ${widget.games.where(_selection.matches).length == 1 ? 'game' : 'games'}'
                    : _loading
                        ? 'Loading your games…'
                        : 'Show games')),
          ])),
    ));
  }
}
