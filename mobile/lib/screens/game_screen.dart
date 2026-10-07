import 'package:flutter/material.dart';

import '../app_state.dart';
import '../companion/view.dart';
import '../theme.dart';

/// The current game's own phone screen, for games that have one: a hand of
/// cards, a private map, a vote. GameNight opens it here by itself when such
/// a game starts, so there is nothing to install per game.
class GameScreen extends StatelessWidget {
  final AppState state;
  final VoidCallback onJoin;
  const GameScreen({super.key, required this.state, required this.onJoin});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final companion = state.companion;
        final api = state.api;
        if (companion != null && api != null) {
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(children: [
                const Icon(Icons.sports_esports, color: GnColors.ok, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(companion.title,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                Text('on your phone', style: const TextStyle(color: GnColors.muted, fontSize: 13)),
              ]),
            ),
            Expanded(
              child: CompanionView(
                key: ValueKey(companion.game),
                url: api.resolve(companion.url),
              ),
            ),
          ]);
        }
        final session = state.session;
        final linked = session?.linked ?? false;
        return ListView(padding: const EdgeInsets.all(16), children: [
          Section(title: 'Game screen', children: [
            if (!linked) ...[
              const Hint('Some games put part of the game on your phone, like your own '
                  'hand of cards. Join a room and it opens here when such a game starts.'),
              const SizedBox(height: 12),
              FilledButton(onPressed: onJoin, child: const Text('Join a room')),
            ] else if (session?.currentTitle != null)
              Hint('${session!.currentTitle} is played on the TV with your controller. '
                  'Games with a phone screen open here by themselves.')
            else
              const Hint('Nothing is being played right now. Games with a phone screen '
                  'open here by themselves when they start.'),
          ]),
        ]);
      },
    );
  }
}
