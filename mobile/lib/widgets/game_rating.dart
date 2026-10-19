import 'package:flutter/material.dart';

import '../account.dart';
import '../api.dart';
import '../theme.dart';

/// How many players like a game, for everyone, and thumbs to vote once you
/// have played it.
class GameRating extends StatefulWidget {
  final String game;
  final CloudApi? cloud;
  const GameRating({super.key, required this.game, this.cloud});

  @override
  State<GameRating> createState() => _GameRatingState();
}

class _GameRatingState extends State<GameRating> {
  ({int up, int down}) _counts = (up: 0, down: 0);
  int _mine = 0;
  bool _played = false;
  bool _saving = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cloud = widget.cloud;
    if (cloud == null) return;
    try {
      final totals = await cloud.ratingTotals();
      if (!mounted) return;
      setState(() => _counts = totals[widget.game] ?? (up: 0, down: 0));
      if (!cloud.signedIn) return;
      final mine = await cloud.gameRatings();
      final played = await cloud.playedGames();
      if (!mounted) return;
      setState(() {
        _mine = mine[widget.game] ?? 0;
        _played = played.contains(widget.game) || _mine != 0;
      });
    } on ApiError {
      // Offline: the page works without votes.
    }
  }

  Future<void> _vote(int value) async {
    final cloud = widget.cloud!;
    final previous = _mine, counts = _counts;
    final next = previous == value ? 0 : value;
    int up = counts.up, down = counts.down;
    if (previous == 1) up--;
    if (previous == -1) down--;
    if (next == 1) up++;
    if (next == -1) down++;
    setState(() {
      _saving = true;
      _mine = next;
      _counts = (up: up, down: down);
      _message = null;
    });
    try {
      await cloud.rateGame(widget.game, next);
    } on ApiError catch (e) {
      if (mounted) {
        setState(() {
          _mine = previous;
          _counts = counts;
          _message = e.message;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _counts.up + _counts.down;
    final signedIn = widget.cloud?.signedIn ?? false;
    final canVote = signedIn && _played && !_saving;
    final summary = total == 0
        ? 'No votes yet'
        : '${(_counts.up * 100 / total).round()}% like it · '
            '$total ${total == 1 ? 'vote' : 'votes'}';
    Widget thumb(int value, IconData on, IconData off, String label) =>
        IconButton(
          tooltip: label,
          isSelected: _mine == value,
          selectedIcon: Icon(on, color: GnColors.accent),
          icon: Icon(off),
          onPressed: canVote ? () => _vote(value) : null,
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const Icon(Icons.thumb_up_alt_outlined,
            size: 18, color: GnColors.muted),
        const SizedBox(width: 8),
        Expanded(
            child: Text(summary,
                key: const ValueKey('rating-summary'),
                style: const TextStyle(fontWeight: FontWeight.w600))),
        thumb(1, Icons.thumb_up, Icons.thumb_up_outlined, 'Thumbs up'),
        thumb(-1, Icons.thumb_down, Icons.thumb_down_outlined, 'Thumbs down'),
      ]),
      if (_message != null || !signedIn || !_played)
        Hint(_message ??
            (!signedIn ? 'Sign in to vote.' : 'Play this game to vote on it.')),
    ]);
  }
}
