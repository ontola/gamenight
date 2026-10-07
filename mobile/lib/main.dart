import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_state.dart';
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
  runApp(GameNightApp(state: state));
}

class GameNightApp extends StatelessWidget {
  final AppState state;
  const GameNightApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GameNight',
      debugShowCheckedModeBanner: false,
      theme: gameNightTheme(),
      home: HomeScreen(state: state),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final AppState state;
  const HomeScreen({super.key, required this.state});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late int _tab = widget.state.host == null ? 0 : 2;
  String? _openedFor;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_followGame);
  }

  @override
  void dispose() {
    widget.state.removeListener(_followGame);
    super.dispose();
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
                label: 'Game',
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
