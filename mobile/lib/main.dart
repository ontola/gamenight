import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_state.dart';
import 'screens/player_screen.dart';
import 'screens/playlist_screen.dart';
import 'screens/room_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final state = AppState(prefs);
  if (state.host != null) state.startPolling();
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
  late int _tab = widget.state.host == null ? 0 : 1;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final linked = widget.state.session?.linked ?? false;
        final pages = [
          RoomScreen(state: widget.state),
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
              const NavigationDestination(icon: Icon(Icons.face_retouching_natural), label: 'You'),
              const NavigationDestination(icon: Icon(Icons.queue_music), label: 'Playlist'),
            ],
          ),
        );
      },
    );
  }
}
