import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';

import '../app_state.dart';
import '../apps.dart';
import '../companion/view.dart';
import '../room_controls.dart';
import '../theme.dart';
import '../layout.dart';
import 'catalog_view.dart';
import 'sign_in_screen.dart';
import 'settings_panel.dart';

/// The Game tab. While the current game has its own phone screen or app,
/// that comes first. Below it (or on its own) are the game's settings, when
/// it has any, and the store catalog to browse and queue games from.
class GameScreen extends StatelessWidget {
  final AppState state;
  final bool catalogOnly;
  final String? requestedGame;
  final VoidCallback? onRequestedGameOpened;
  final VoidCallback onJoin;
  const GameScreen(
      {super.key,
      required this.state,
      required this.onJoin,
      this.catalogOnly = false,
      this.requestedGame,
      this.onRequestedGameOpened});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final companion = state.companion;
        Uri resolve(String url) => state.inHostedRoom
            ? state.cloud.base.resolve(url)
            : state.api!.resolve(url);
        final controls = roomControlsFor(state);
        final session = state.session;
        final settings = state.isGuest
            ? const SizedBox.shrink()
            : SettingsSection(
                key: const ValueKey('settings'),
                controls: controls,
                title: state.inHostedRoom
                    ? state.hostedRoom?.currentTitle
                    : session?.currentTitle);
        final catalog = CatalogSection(
            key: const ValueKey('catalog'),
            cloud: state.cloud,
            onSignIn: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SignInScreen(
                      state: state,
                      reason: 'See your likes and play history.')));
            },
            controls: controls,
            requestedGame: requestedGame,
            onRequestedGameOpened: onRequestedGameOpened);
        if (catalogOnly) {
          return ListView(
              padding: const EdgeInsets.all(16), children: [catalog]);
        }
        if (companion != null && (state.inHostedRoom || state.api != null)) {
          final fullscreen = state.companionFullscreen;
          return Stack(children: [
            Column(children: [
              Visibility(
                  visible: !fullscreen,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                    child: Row(children: [
                      const Icon(Icons.sports_esports,
                          color: GnColors.ok, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(companion.title,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                      if (companion.url != null)
                        IconButton(
                          tooltip: 'Full screen',
                          icon: const Icon(Icons.fullscreen),
                          onPressed: () => state.setCompanionFullscreen(true),
                        ),
                      if (companion.url != null &&
                          controls != null &&
                          !state.isGuest)
                        IconButton(
                          tooltip: 'Game settings',
                          icon: const Icon(Icons.tune),
                          onPressed: () =>
                              _showSettings(context, controls, companion.title),
                        ),
                    ]),
                  )),
              if (companion.app != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: AppCard(
                      key: ValueKey('app-${companion.game}'),
                      app: companion.app!,
                      download: companion.app!.download == null
                          ? null
                          : resolve(companion.app!.download!)),
                ),
              if (companion.url != null)
                Expanded(
                  child: CompanionView(
                    key: ValueKey('${companion.game}:${companion.url}'),
                    url: resolve(companion.url!),
                  ),
                )
              else
                Expanded(
                  child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      children: [settings]),
                ),
            ]),
            if (fullscreen)
              Positioned(
                top: 8,
                right: 8,
                child: Material(
                  color: GnColors.card,
                  shape: const CircleBorder(),
                  child: IconButton(
                    tooltip: 'Exit full screen',
                    icon: const Icon(Icons.fullscreen_exit),
                    onPressed: () => state.setCompanionFullscreen(false),
                  ),
                ),
              ),
          ]);
        }
        // In a room on this Wi-Fi, or an online one: the Room tab has nothing
        // left to offer, so no "Join a room" here.
        final hosted = state.inHostedRoom ? state.hostedRoom : null;
        final linked =
            (session?.linked ?? false) || (hosted?.connected ?? false);
        final waiting =
            (session?.waiting ?? false) || (hosted?.waiting ?? false);
        final playing = hosted?.currentTitle ?? session?.currentTitle;
        return ContentWidth(
            child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
              Section(title: playing ?? 'Current game', children: [
                if (waiting)
                  const Hint(
                      'Walk your character to your door in the lobby and stand there to '
                      'connect. Games with a phone screen open here by themselves.')
                else if (!linked && state.host != null) ...[
                  const Hint(
                      'You are connected to a GameNight, but your character has not been '
                      'picked up yet. Enter the room code or scan the QR in the lobby.'),
                  const SizedBox(height: 12),
                  FilledButton(
                      onPressed: onJoin,
                      child: const Text('Pick up my character')),
                ] else if (!linked) ...[
                  const Hint(
                      'Some games put part of the game on your phone, like your own '
                      'hand of cards. Join a room and it opens here when such a game starts.'),
                  const SizedBox(height: 12),
                  FilledButton(
                      onPressed: onJoin, child: const Text('Join a room')),
                ] else if (playing != null)
                  Hint(
                      '$playing is on the TV. Phone controls appear here when available.')
                else
                  const Hint(
                      'Nothing is being played right now. Games with a phone screen '
                      'open here by themselves when they start.'),
              ]),
              if (state.companionError case final String error) Hint(error),
              settings,
            ]));
      },
    );
  }

  void _showSettings(
      BuildContext context, RoomControls controls, String title) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SettingsSection(
              controls: controls, title: title, showEmpty: true),
        ),
      ),
    );
  }
}

/// A game's own phone app: GameNight installs it from the GameNight computer
/// and opens it, like a store would.
class AppCard extends StatefulWidget {
  final CompanionApp app;
  final Uri? download;
  const AppCard({super.key, required this.app, this.download});

  @override
  State<AppCard> createState() => _AppCardState();
}

enum _Step { checking, missing, installed, installing }

class _AppCardState extends State<AppCard> with WidgetsBindingObserver {
  _Step step = _Step.checking;
  String? error;
  Timer? _poll;

  String? get package => widget.app.android;
  bool get apk => widget.download?.path.toLowerCase().endsWith('.apk') ?? false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  // Back from Android's settings or install dialog.
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed && step != _Step.installing) _check();
  }

  Future<void> _check() async {
    final p = package;
    final version = p == null ? null : await Apps.installed(p);
    if (!mounted) return;
    setState(() => step = version == null ? _Step.missing : _Step.installed);
  }

  Future<void> _open() async {
    if (!await Apps.open(package!)) _check();
  }

  Future<void> _install() async {
    final url = widget.download!;
    if (!apk) return Apps.view(url);
    if (!await Apps.canInstall()) return Apps.allowInstalls();
    setState(() {
      step = _Step.installing;
      error = null;
    });
    try {
      await Apps.install(url, package!);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        step = _Step.missing;
        error = 'Could not install: ${e.message}';
      });
      return;
    }
    var waited = 0;
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (t) async {
      final status = await Apps.status(package!);
      waited++;
      if (!mounted) return t.cancel();
      if (status == 'done') {
        t.cancel();
        _check();
      } else if (status != null && status.startsWith('failed')) {
        t.cancel();
        setState(() {
          step = _Step.missing;
          error = 'Android did not install it (${status.substring(8)}).';
        });
      } else if (waited > 300) {
        t.cancel();
        _check();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.app.name;
    final canInstall = Apps.supported &&
        !Apps.playStore &&
        package != null &&
        widget.download != null;
    final Widget action;
    String hint;
    switch (step) {
      case _Step.checking:
        action = const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2));
        hint = 'This game has its own app.';
      case _Step.installing:
        action = const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2));
        hint = 'Installing. Android may ask you to confirm.';
      case _Step.installed:
        action = FilledButton(onPressed: _open, child: const Text('Open'));
        hint = 'Open it to play your side of the game.';
      case _Step.missing:
        action = FilledButton(
            onPressed: canInstall ? _install : null,
            child: const Text('Install'));
        hint = !Apps.supported
            ? 'Get $name from your app store, then open it to play.'
            : canInstall
                ? 'GameNight installs it from the GameNight computer.'
                : 'Get $name from your app store, then open it to play.';
    }
    return Section(title: name, children: [
      Row(children: [
        Expanded(child: Hint(hint)),
        const SizedBox(width: 12),
        action,
      ]),
      if (error != null) ...[
        const SizedBox(height: 8),
        Text(error!,
            style: const TextStyle(color: GnColors.warn, fontSize: 13)),
      ],
      if (step == _Step.installed && canInstall && apk)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
              onPressed: _install,
              child: const Text('Update from the GameNight computer')),
        ),
    ]);
  }
}
