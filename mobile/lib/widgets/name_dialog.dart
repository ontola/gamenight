import 'package:flutter/material.dart';

import '../app_state.dart';
import '../player_face.dart';
import '../theme.dart';

/// Asks a new player for a name before a scanned room shows them on the TV.
/// Leaving it empty keeps the random name; either way it asks only once.
Future<void> askName(BuildContext context, AppState state) async {
  final input = TextEditingController();
  final name = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        void done() => Navigator.pop(context, input.text.trim());
        return AlertDialog(
          key: const ValueKey('name-dialog'),
          title: const Text("What's your name?", textAlign: TextAlign.center),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox.square(
              dimension: 72,
              child: FittedBox(
                  child:
                      PlayerFaceIcon(face: state.face, skin: state.skinColor)),
            ),
            const SizedBox(height: 8),
            const Text('Everyone in the room sees it on the TV.',
                textAlign: TextAlign.center,
                style: TextStyle(color: GnColors.muted)),
            const SizedBox(height: 12),
            TextField(
              controller: input,
              autofocus: true,
              maxLength: 20,
              textAlign: TextAlign.center,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.go,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              decoration:
                  InputDecoration(counterText: '', hintText: state.name),
              onSubmitted: (_) => done(),
            ),
          ]),
          actions: [
            FilledButton(onPressed: done, child: const Text('Join room')),
          ],
        );
      });
  // The dialog's exit animation can still use its text controller.
  Future<void>.delayed(const Duration(milliseconds: 300), input.dispose);
  if (name != null && name.isNotEmpty) {
    state.setName(name);
  } else {
    state.keepName();
  }
}
