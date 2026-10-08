import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart' show ApiError;
import 'app_state.dart';
import 'link.dart';
import 'screens/game_screen.dart';
import 'screens/player_screen.dart';
import 'screens/playlist_screen.dart';
import 'screens/room_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final state = AppState(prefs);
  if (state.host != null || state.inHostedRoom) state.startPolling();
  state.loadAccount();
  final links = AppLinks();
  Uri? first;
  try {
    first = await links.getInitialLink();
  } catch (_) {}
  runApp(GameNightApp(state: state, links: links.uriLinkStream, initialLink: first));
}

class GameNightApp extends StatelessWidget {
  final AppState state;

  /// Links that open the app, e.g. from the sign-in email.
  final Stream<Uri>? links;
  final Uri? initialLink;
  const GameNightApp({super.key, required this.state, this.links, this.initialLink});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GameNight',
      debugShowCheckedModeBanner: false,
      theme: gameNightTheme(),
      home: HomeScreen(state: state, links: links, initialLink: initialLink),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final AppState state;
  final Stream<Uri>? links;
  final Uri? initialLink;
  const HomeScreen({super.key, required this.state, this.links, this.initialLink});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late int _tab = widget.state.host == null ? 0 : 2;
  String? _openedFor;
  StreamSubscription<Uri>? _links;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_followGame);
    _links = widget.links?.listen(_onLink);
    final first = widget.initialLink;
    if (first != null) WidgetsBinding.instance.addPostFrameCallback((_) => _onLink(first));
  }

  @override
  void dispose() {
    _links?.cancel();
    widget.state.removeListener(_followGame);
    super.dispose();
  }

  /// The link in the sign-in email opens the app and signs in here.
  Future<void> _onLink(Uri uri) async {
    final link = SignInLink.parse(uri);
    if (link == null) return;
    String message;
    try {
      message = await widget.state.signInWithLink(link);
      if (mounted) setState(() => _tab = 2);
    } on ApiError catch (e) {
      message = e.message;
    }
    if (mounted) toast(context, message);
  }

  /// Bring up a game's phone screen the moment that game starts, once per
  /// game, so players never have to go looking for it.
  void _followGame() {
    final game = widget.state.companion?.game;
    if (game != null && game != _openedFor) setState(() => _tab = 1);
    _openedFor = game;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final linked = widget.state.session?.linked ?? false;
        final pages = [
          RoomScreen(state: widget.state),
          GameScreen(state: widget.state, onJoin: () => setState(() => _tab = 0)),
          PlayerScreen(state: widget.state),
          PlaylistScreen(state: widget.state, onJoin: () => setState(() => _tab = 0)),
        ];
        return Scaffold(
          body: SafeArea(child: IndexedStack(index: _tab, children: pages)),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: linked,
                  backgroundColor: GnColors.ok,
                  smallSize: 8,
                  child: const Icon(Icons.qr_code_scanner),
                ),
                label: 'Room',
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: widget.state.companion != null,
                  backgroundColor: GnColors.ok,
                  smallSize: 8,
                  child: const Icon(Icons.sports_esports),
                ),
                label: 'Games',
              ),
              const NavigationDestination(icon: Icon(Icons.face_retouching_natural), label: 'You'),
              const NavigationDestination(icon: Icon(Icons.queue_music), label: 'Playlist'),
            ],
          ),
        );
      },
    );
  }
}
