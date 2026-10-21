import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../app_update.dart';
import '../layout.dart';
import '../theme.dart';
import 'face_editor_screen.dart';
import 'sign_in_screen.dart';

/// What GameNight is, in a few lines, and what is left to set up. Opens
/// from the logo.
class AboutScreen extends StatelessWidget {
  final AppState state;
  final VoidCallback? onHost;
  final VoidCallback? onScan;
  final VoidCallback? onDocs;
  const AboutScreen(
      {super.key, required this.state, this.onHost, this.onScan, this.onDocs});

  static const _points = [
    (
      Icons.bolt,
      'No waiting',
      'The next game loads while you play. Switching is instant.'
    ),
    (
      Icons.sports_esports,
      'Your controller stays yours',
      'Pick up once, play every game.'
    ),
    (
      Icons.face,
      'You, in every game',
      'Your name and the face you drew come along.'
    ),
    (
      Icons.groups,
      'Games that fit the room',
      'Only games for the people on the couch right now.'
    ),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(),
        body: ListenableBuilder(
          listenable: state,
          builder: (context, _) => ContentWidth(
            maxWidth: 560,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                const Row(children: [
                  GameNightLogo(size: 44),
                  SizedBox(width: 12),
                  Expanded(
                      child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: GameNightWordmark(size: 28))),
                ]),
                const SizedBox(height: 14),
                const Text('Less setup. More playing together.',
                    style:
                        TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                const Hint(
                    'Couch games for one big screen, with everyone in the room.'),
                const SizedBox(height: 18),
                for (final p in _points)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(p.$1, color: GnColors.warn, size: 22),
                          const SizedBox(width: 12),
                          Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Text(p.$2,
                                    style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700)),
                                const SizedBox(height: 2),
                                Hint(p.$3),
                              ])),
                        ]),
                  ),
                const SizedBox(height: 10),
                _Todos(state: state, onHost: onHost, onScan: onScan),
                const SizedBox(height: 18),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  if (onDocs != null)
                    _Link(
                        key: const ValueKey('about-docs'),
                        label: 'Docs',
                        icon: Icons.menu_book_outlined,
                        onTap: onDocs!),
                  _Link(
                      key: const ValueKey('about-github'),
                      label: 'GitHub',
                      icon: Icons.code,
                      onTap: () => launchUrl(
                          Uri.parse('https://github.com/ontola/gamenight'))),
                  _Link(
                      key: const ValueKey('about-ontola'),
                      label: 'Made by Ontola',
                      icon: Icons.favorite_outline,
                      onTap: () => launchUrl(Uri.parse('https://ontola.io'))),
                ]),
              ],
            ),
          ),
        ),
      );
}

class _Link extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _Link(
      {super.key,
      required this.label,
      required this.icon,
      required this.onTap});

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
      onPressed: onTap, icon: Icon(icon, size: 18), label: Text(label));
}

class _Todos extends StatelessWidget {
  final AppState state;
  final VoidCallback? onHost;
  final VoidCallback? onScan;
  const _Todos({required this.state, this.onHost, this.onScan});

  @override
  Widget build(BuildContext context) {
    final android = defaultTargetPlatform == TargetPlatform.android;
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    final items = [
      if (!kIsWeb || android || ios)
        _Todo(
          key: const ValueKey('todo-app'),
          done: !kIsWeb,
          title: 'Get the app',
          hint: kIsWeb && ios
              ? 'The iPhone app is in testing. Ask for an invite.'
              : 'Keep GameNight a tap away on your phone.',
          action: kIsWeb && android ? 'Download' : null,
          onTap: () =>
              launchUrl(AppUpdate.apk, mode: LaunchMode.externalApplication),
        ),
      _Todo(
        key: const ValueKey('todo-join'),
        done: state.joinedRoom,
        title: 'Join a session',
        hint: 'Scan the QR code on the TV to pick up your player.',
        action: onScan == null ? null : 'Scan QR',
        onTap: () => onScan?.call(),
      ),
      _Todo(
        key: const ValueKey('todo-face'),
        done: state.drewFace,
        title: 'Draw your face',
        hint: 'It shows up on your character in the games.',
        action: 'Draw',
        onTap: () => FaceEditorScreen.open(context, state),
      ),
      _Todo(
        key: const ValueKey('todo-email'),
        done: state.signedIn,
        title: 'Save your player with your email',
        hint: state.signedIn
            ? 'Signed in${state.account?.email == null ? '' : ' as ${state.account!.email}'}.'
            : 'Keep your faces and settings on every device.',
        action: 'Sign in',
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => SignInScreen(state: state))),
      ),
      _Todo(
        key: const ValueKey('todo-host'),
        done: state.hostedOwnRoom,
        title: 'Install on your PC and host a session',
        hint: 'Run GameNight on the TV computer and invite your friends.',
        action: onHost == null ? null : 'Host',
        onTap: () => onHost?.call(),
      ),
    ];
    final left = items.where((t) => !t.done).length;
    // Nothing left to do: the checklist goes away.
    if (left == 0) return const SizedBox.shrink();
    return Section(
      title: 'Get ready ($left to go)',
      children: items,
    );
  }
}

class _Todo extends StatelessWidget {
  final bool done;
  final String title;
  final String hint;
  final String? action;
  final VoidCallback onTap;
  const _Todo(
      {super.key,
      required this.done,
      required this.title,
      required this.hint,
      required this.action,
      required this.onTap});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Icon(done ? Icons.check_circle : Icons.radio_button_unchecked,
              color: done ? GnColors.ok : GnColors.muted),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: done ? GnColors.muted : GnColors.text,
                        decoration: done ? TextDecoration.lineThrough : null,
                        decorationColor: GnColors.muted)),
                Hint(hint),
              ])),
          if (!done && action != null) ...[
            const SizedBox(width: 8),
            FilledButton(onPressed: onTap, child: Text(action!)),
          ],
        ]),
      );
}
