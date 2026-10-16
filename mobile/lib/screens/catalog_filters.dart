import 'package:flutter/material.dart';

import '../account.dart';
import '../catalog.dart';
import '../theme.dart';

class CatalogFilter {
  final bool liked, unplayed;
  final Set<String> tags, likedGames, playedGames;
  const CatalogFilter(
      {this.liked = false,
      this.unplayed = false,
      this.tags = const {},
      this.likedGames = const {},
      this.playedGames = const {}});
  bool get active => liked || unplayed || tags.isNotEmpty;
  bool matches(CatalogGame game) =>
      (!liked || likedGames.contains(game.id)) &&
      (!unplayed || !playedGames.contains(game.id)) &&
      (tags.isEmpty || tags.any(game.tags.contains));
  CatalogFilter copyWith({bool? liked, bool? unplayed, Set<String>? tags}) =>
      CatalogFilter(
          liked: liked ?? this.liked,
          unplayed: unplayed ?? this.unplayed,
          tags: tags ?? this.tags,
          likedGames: likedGames,
          playedGames: playedGames);
}

class CatalogFilters extends StatefulWidget {
  final CatalogFilter filter;
  final List<CatalogGame> games;
  final CloudApi? cloud;
  final Future<void> Function()? onSignIn;
  const CatalogFilters(
      {super.key,
      required this.filter,
      required this.games,
      this.cloud,
      this.onSignIn});
  @override
  State<CatalogFilters> createState() => _CatalogFiltersState();
}

class _CatalogFiltersState extends State<CatalogFilters> {
  late bool _liked = widget.filter.liked, _unplayed = widget.filter.unplayed;
  late final Set<String> _tags = {...widget.filter.tags};
  Set<String> _likedGames = {}, _playedGames = {};
  bool _loading = false, _loaded = false;
  String? _error;
  int _days = 90;
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
          await Future.wait<Object>([cloud.gameRatings(), cloud.playHistory()]);
      if (!mounted || cloud.token != identity) return;
      final ratings = results[0] as Map<String, int>;
      final history = results[1] as ({Set<String> games, int days});
      setState(() {
        _likedGames = {
          for (final entry in ratings.entries)
            if (entry.value == 1) entry.key
        };
        _playedGames = history.games;
        _days = history.days;
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
      tags: _tags,
      likedGames: _likedGames,
      playedGames: _playedGames);

  @override
  Widget build(BuildContext context) {
    final tags = widget.games.expand((game) => game.tags).toSet().toList()
      ..sort();
    final ready = !(_liked || _unplayed) || _loaded;
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
                    label: const Text('Not played'),
                    selected: _unplayed,
                    onSelected:
                        _loaded ? (v) => setState(() => _unplayed = v) : null),
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
              ] else if (_loaded)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Hint(
                        'Not played uses your recorded play history from the last $_days days.')),
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
