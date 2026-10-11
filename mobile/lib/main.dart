import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart' show ApiError;
import 'app_update.dart';
import 'app_state.dart';
import 'link.dart';
import 'reports.dart';
import 'report_scope.dart';
import 'diagnostics.dart';
import 'screens/feedback_screen.dart';
import 'screens/game_screen.dart';
import 'screens/player_screen.dart';
import 'screens/playlist_screen.dart';
import 'screens/room_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(gameNightSystemUi);
  final prefs = await SharedPreferences.getInstance();
  final state = AppState(prefs);
  final reports = ReportService(prefs,
      context: () => {
            if (state.hostedRoom?.current ?? state.session?.currentGame ?? state.companion?.game
                case final String game)
              'game': game,
          });
  Diagnostics.onFailure = reports.captureFailure;
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    reports.captureError(details.exception, details.stack ?? StackTrace.current, source: 'flutter');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    reports.captureError(error, stack);
    return false;
  };
  reports.start();
  if (state.host != null || state.inHostedRoom) state.startPolling();
  state.loadAccount();
  final links = AppLinks();
  Uri? first;
  try {
    first = await links.getInitialLink();
  } catch (_) {
    Diagnostics.failure('Could not read the app launch link');
  }
  runApp(
      GameNightApp(state: state, links: links.uriLinkStream, initialLink: first, reports: reports));
}

class GameNightApp extends StatelessWidget {
  final AppState state;
  final ReportService? reports;

  /// Links that open the app, e.g. from the sign-in email.
  final Stream<Uri>? links;
  final Uri? initialLink;
  const GameNightApp({super.key, required this.state, this.links, this.initialLink, this.reports});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GameNight',
      debugShowCheckedModeBanner: false,
      theme: gameNightTheme(),
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: gameNightSystemUi,
        child: ReportScope(reports: reports, child: ColoredBox(color: GnColors.bg, child: child!)),
      ),
      home: HomeScreen(state: state, links: links, initialLink: initialLink, reports: reports),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final AppState state;
  final ReportService? reports;
  final Stream<Uri>? links;
  final Uri? initialLink;
  const HomeScreen({super.key, required this.state, this.links, this.initialLink, this.reports});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late int _tab = widget.state.host == null ? 0 : 2;
  String? _openedFor;
  final _roomKey = GlobalKey<RoomScreenState>();
  StreamSubscription<Uri>? _links;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.addListener(_followGame);
    _links = widget.links?.listen(_onLink);
    final first = widget.initialLink;
    if (first != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onLink(first));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _links?.cancel();
    widget.state.removeListener(_followGame);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(widget.reports?.flush());
  }

  void _feedback() {
    final reports = widget.reports;
    if (reports == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'feedback'),
      builder: (_) => FeedbackScreen(reports: reports),
    ));
  }

  /// The link in the sign-in email opens the app and signs in here.
  Future<void> _onLink(Uri uri) async {
    final link = SignInLink.parse(uri);
    if (link == null) {
      // Only trusted GameNight links can ask the app to join a room.
      if (uri.scheme != 'https' || uri.origin != hostedOrigin) return;
      try {
        final room = parseHostLink(uri.toString());
        if (room.roomCode == null && room.pair == null) return;
        if (mounted) setState(() => _tab = 0);
        await _roomKey.currentState?.openLink(uri.toString());
      } on LinkError {
        // Not a room invitation.
      }
      return;
    }
    String message;
    try {
      message = await widget.state.signInWithLink(link);
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
        widget.reports?.screen = const ['room', 'games', 'you', 'playlist'][_tab];
        final linked = widget.state.session?.linked ?? false;
        final pages = [
          RoomScreen(key: _roomKey, state: widget.state),
          GameScreen(state: widget.state, onJoin: () => setState(() => _tab = 0)),
          PlayerScreen(state: widget.state),
          PlaylistScreen(state: widget.state, onJoin: () => setState(() => _tab = 0)),
        ];
        return Scaffold(
          body: SafeArea(
            child: Column(children: [
              UpdateBanner(),
              if (widget.reports != null)
                Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: _feedback,
                      icon: const Icon(Icons.mic_none, size: 20),
                      label: const Text('Feedback'),
                    )),
              Expanded(child: IndexedStack(index: _tab, children: pages)),
            ]),
          ),
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
