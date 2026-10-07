import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';

import '../app_state.dart';
import '../apps.dart';
import '../companion/view.dart';
import '../room_controls.dart';
import '../theme.dart';
import 'catalog_view.dart';
import 'settings_panel.dart';

/// The Game tab. While the current game has its own phone screen or app,
/// that comes first. Below it (or on its own) are the game's settings, when
/// it has any, and the store catalog to browse and queue games from.
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
        final controls = roomControlsFor(state);
        final session = state.session;
        final settings = SettingsSection(
            key: const ValueKey('settings'), controls: controls, title: session?.currentTitle);
        final catalog = CatalogSection(key: const ValueKey('catalog'), controls: controls);
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
                if (companion.url != null && controls != null)
                  IconButton(
                    tooltip: 'Game settings',
                    icon: const Icon(Icons.tune),
                    onPressed: () => _showSettings(context, controls, companion.title),
                  ),
              ]),
            ),
            if (companion.app != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: AppCard(
                    key: ValueKey('app-${companion.game}'),
                    app: companion.app!,
                    download: companion.app!.download == null
                        ? null
                        : api.resolve(companion.app!.download!)),
              ),
            if (companion.url != null)
              Expanded(
                child: CompanionView(
                  key: ValueKey(companion.game),
                  url: api.resolve(companion.url!),
                ),
              )
            else
              Expanded(
                child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    children: [settings, catalog]),
              ),
          ]);
        }
        final linked = session?.linked ?? false;
        return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
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
          settings,
          catalog,
        ]);
      },
    );
  }

  void _showSettings(BuildContext context, RoomControls controls, String title) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SettingsSection(controls: controls, title: title, showEmpty: true),
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
    final canInstall = Apps.supported && package != null && widget.download != null;
    final Widget action;
    String hint;
    switch (step) {
      case _Step.checking:
        action =
            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2));
        hint = 'This game has its own app.';
      case _Step.installing:
        action =
            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2));
        hint = 'Installing. Android may ask you to confirm.';
      case _Step.installed:
        action = FilledButton(onPressed: _open, child: const Text('Open'));
        hint = 'Open it to play your side of the game.';
      case _Step.missing:
        action =
            FilledButton(onPressed: canInstall ? _install : null, child: const Text('Install'));
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
        Text(error!, style: const TextStyle(color: GnColors.warn, fontSize: 13)),
      ],
      if (step == _Step.installed && canInstall && apk)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
              onPressed: _install, child: const Text('Update from the GameNight computer')),
        ),
    ]);
  }
}
