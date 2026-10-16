import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart' show ApiError;
import 'app_update.dart';
import 'app_state.dart';
import 'link.dart';
import 'layout.dart';
import 'player_face.dart';
import 'package:url_launcher/url_launcher.dart';
import 'navigation/browser_history.dart';
import 'navigation/website_session.dart';
import 'reports.dart';
import 'report_scope.dart';
import 'diagnostics.dart';
import 'screens/feedback_screen.dart';
import 'screens/assistant_screen.dart';
import 'screens/game_screen.dart';
import 'screens/player_screen.dart';
import 'screens/room_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(gameNightSystemUi);
  final prefs = await SharedPreferences.getInstance();
  if (kIsWeb) await migrateWebsiteRoom(prefs);
  final state = AppState(prefs);
  final reports = ReportService(prefs,
      requestHeaders: state.cloud.browserMutationHeaders,
      context: () => {
            if (state.hostedRoom?.current ??
                    state.session?.currentGame ??
                    state.companion?.game
                case final String game)
              'game': game,
          });
  Diagnostics.onFailure = reports.captureFailure;
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    reports.captureError(details.exception, details.stack ?? StackTrace.current,
        source: 'flutter');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    reports.captureError(error, stack);
    return false;
  };
  reports.start();
  if (state.host != null || state.inHostedRoom) state.startPolling();
  final accountLoading = state.loadAccount();
  final links = AppLinks();
  Uri? first;
  try {
    first = kIsWeb ? Uri.base : await links.getInitialLink();
  } catch (_) {
    Diagnostics.failure('Could not read the app launch link');
  }
  runApp(GameNightApp(
      state: state,
      links: links.uriLinkStream,
      initialLink: first,
      accountLoading: accountLoading,
      reports: reports));
}

class GameNightApp extends StatefulWidget {
  final AppState state;
  final ReportService? reports;

  /// Links that open the app, e.g. from the sign-in email.
  final Stream<Uri>? links;
  final Uri? initialLink;
  final Future<void>? accountLoading;
  const GameNightApp(
      {super.key,
      required this.state,
      this.links,
      this.initialLink,
      this.accountLoading,
      this.reports});

  @override
  State<GameNightApp> createState() => _GameNightAppState();
}

class _GameNightAppState extends State<GameNightApp> {
  final _navigator = GlobalKey<NavigatorState>();
  BrowserNavigation? _history;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialLink;
    if (initial != null &&
        Uri.tryParse(initial.fragment)?.path == '/assistant') {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await widget.accountLoading;
        if (mounted) _assistant();
      });
    }
    if (kIsWeb) {
      _history = BrowserNavigation(
          navigatorKey: _navigator,
          fullscreen: () => widget.state.companionFullscreen,
          setFullscreen: widget.state.setCompanionFullscreen);
      widget.state.addListener(_fullscreenChanged);
    }
  }

  void _fullscreenChanged() => _history?.fullscreenChanged();

  @override
  void dispose() {
    widget.state.removeListener(_fullscreenChanged);
    _history?.dispose();
    super.dispose();
  }

  Widget _home() => HomeScreen(
      state: widget.state,
      links: widget.links,
      initialLink: widget.initialLink,
      accountLoading: widget.accountLoading,
      reports: widget.reports,
      history: _history);

  void _feedback() {
    final reports = widget.reports;
    if (reports == null) return;
    _navigator.currentState?.push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'feedback'),
      builder: (_) => FeedbackScreen(reports: reports),
    ));
  }

  void _assistant() {
    _navigator.currentState?.push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'assistant'),
      builder: (_) => AssistantScreen(state: widget.state),
    ));
  }

  void _menu() {
    final context = _navigator.currentState?.overlay?.context;
    if (context == null) return;
    showModalBottomSheet<void>(
        context: context,
        builder: (context) => SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ListTile(
                    leading: const Icon(Icons.auto_awesome),
                    title: const Text('Assistant'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.pop(context);
                      _assistant();
                    }),
                for (final entry in const [
                  ('/developers', 'Developer portal'),
                  ('/docs', 'Documentation'),
                  ('/host', 'Host a room')
                ])
                  ListTile(
                      title: Text(entry.$2),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () {
                        Navigator.pop(context);
                        launchUrl(Uri.parse('$hostedOrigin${entry.$1}'));
                      }),
              ]),
            ));
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: kIsWeb ? null : _navigator,
        title: 'GameNight',
        debugShowCheckedModeBanner: false,
        theme: gameNightTheme(),
        builder: (context, child) => ListenableBuilder(
          listenable: widget.state,
          builder: (context, _) => AnnotatedRegion<SystemUiOverlayStyle>(
            value: gameNightSystemUi,
            child: ReportScope(
                reports: widget.reports,
                child: ColoredBox(
                  color: GnColors.bg,
                  child: SafeArea(
                      bottom: false,
                      // Route semantics must not hide the persistent header.
                      // Place it after Navigator in paint/semantics order while
                      // keeping it visually above the page.
                      child: Column(
                          verticalDirection: VerticalDirection.up,
                          children: [
                            Expanded(
                                child: _history == null
                                    ? child!
                                    : Navigator(
                                        key: _navigator,
                                        observers: [_history!.observer],
                                        onGenerateRoute: (_) =>
                                            MaterialPageRoute<void>(
                                                settings: const RouteSettings(
                                                    name: '/'),
                                                builder: (_) => _home()),
                                      )),
                            Visibility(
                                visible: !widget.state.companionFullscreen,
                                child: Material(
                                    color: GnColors.bg,
                                    child: Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                            16, 4, 8, 4),
                                        child: Row(children: [
                                          const GameNightLogo(size: 28),
                                          const SizedBox(width: 8),
                                          const Expanded(
                                              child: Text('GameNight',
                                                  key: ValueKey('app-brand'),
                                                  style: TextStyle(
                                                      fontSize: 22,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      color: GnColors.text))),
                                          Semantics(
                                              container: true,
                                              excludeSemantics: true,
                                              onTap: _menu,
                                              label: 'Menu',
                                              button: true,
                                              child: IconButton(
                                                  onPressed: _menu,
                                                  icon:
                                                      const Icon(Icons.menu))),
                                          if (widget.reports != null)
                                            TextButton.icon(
                                                onPressed: _feedback,
                                                icon: const Icon(Icons.mic_none,
                                                    size: 20),
                                                label: const Text('Feedback')),
                                        ])))),
                          ])),
                )),
          ),
        ),
        home: kIsWeb ? null : _home(),
      );
}

class HomeScreen extends StatefulWidget {
  final AppState state;
  final BrowserNavigation? history;
  final ReportService? reports;
  final Stream<Uri>? links;
  final Uri? initialLink;
  final Future<void>? accountLoading;
  const HomeScreen(
      {super.key,
      required this.state,
      this.history,
      this.links,
      this.initialLink,
      this.accountLoading,
      this.reports});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _tab = 0;
  String? _openedFor;
  String? _requestedGame;
  final _roomKey = GlobalKey<RoomScreenState>();
  StreamSubscription<Uri>? _links;

  @override
  void initState() {
    super.initState();
    _tab = widget.history?.tab ?? 0;
    final requested = widget.initialLink?.queryParameters['game'] ??
        widget.state.prefs.getString('requested_game');
    if (requested != null &&
        RegExp(r'^[a-z0-9][a-z0-9-]{0,79}$').hasMatch(requested)) {
      _requestedGame = requested;
      widget.state.prefs.setString('requested_game', requested);
    }
    widget.history?.addListener(_historyChanged);
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
    widget.history?.removeListener(_historyChanged);
    WidgetsBinding.instance.removeObserver(this);
    _links?.cancel();
    widget.state.removeListener(_followGame);
    super.dispose();
  }

  void _historyChanged() {
    if (mounted && _tab != widget.history?.tab) {
      setState(() => _tab = widget.history!.tab);
    }
  }

  void _selectTab(int tab) {
    if (widget.history case final history?) {
      history.selectTab(tab);
    } else if (_tab != tab) {
      setState(() => _tab = tab);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.reports?.flush());
      if (widget.state.cloud.browserCookies) {
        unawaited(widget.state.loadAccount());
      }
    }
  }

  /// The link in the sign-in email opens the app and signs in here.
  Future<void> _onLink(Uri uri) async {
    await widget.accountLoading;
    if (!mounted) return;
    final link = SignInLink.parse(uri);
    if (link == null) {
      // Only trusted GameNight links can ask the app to join a room.
      if (uri.scheme != 'https' || uri.origin != hostedOrigin) return;
      try {
        final room = parseHostLink(uri.toString());
        if (room.roomCode == null && room.pair == null) return;
        if (mounted) _selectTab(0);
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
    if (_requestedGame != null &&
        (widget.state.hostedRoom?.connected == true ||
            widget.state.session?.linked == true)) {
      _openedFor = widget.state.companion?.game;
      _selectTab(1);
      return;
    }
    final game = widget.state.companion?.game;
    if (game != null && game != _openedFor) {
      _selectTab(0);
      _roomKey.currentState?.showCurrentGame();
    }
    _openedFor = game;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        widget.reports?.screen = const ['room', 'games', 'you'][_tab];
        final wide = MediaQuery.sizeOf(context).width >= 900;
        final fullscreen = widget.state.companionFullscreen;
        final linked = widget.state.inHostedRoom
            ? widget.state.hostedRoom?.connected ?? false
            : widget.state.session?.linked ?? false;
        final pages = [
          RoomScreen(
              key: _roomKey,
              state: widget.state,
              initialSection: Uri.tryParse(widget.initialLink?.fragment ?? '')
                          ?.queryParameters['section'] ==
                      'playlist'
                  ? 1
                  : 0),
          GameScreen(
              catalogOnly: true,
              requestedGame: _tab == 1 ? _requestedGame : null,
              onRequestedGameOpened: () {
                _requestedGame = null;
                widget.state.prefs.remove('requested_game');
              },
              state: widget.state,
              onJoin: () => _selectTab(0)),
          PlayerScreen(state: widget.state),
        ];
        return PopScope(
          canPop: !widget.state.companionFullscreen,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && widget.state.companionFullscreen) {
              widget.state.setCompanionFullscreen(false);
            }
          },
          child: Scaffold(
            body: SafeArea(
              child: Column(children: [
                UpdateBanner(),
                Expanded(
                    child: Row(children: [
                  // Keep the content at the same tree position across breakpoints;
                  // embedded games must never reload when the window is resized.
                  SizedBox(
                      width: wide && !fullscreen ? 200 : 0,
                      child: Offstage(
                          offstage: !wide || fullscreen,
                          child: NavigationRail(
                            extended: true,
                            minExtendedWidth: 200,
                            selectedIndex: _tab,
                            onDestinationSelected: _selectTab,
                            destinations: [
                              const NavigationRailDestination(
                                  icon: Icon(Icons.meeting_room_outlined),
                                  label: Text('Room')),
                              const NavigationRailDestination(
                                  icon: Icon(Icons.sports_esports_outlined),
                                  label: Text('Games')),
                              NavigationRailDestination(
                                  icon: PlayerFaceIcon(
                                      face: widget.state.face,
                                      skin: widget.state.skinColor),
                                  label: Text('You')),
                            ],
                          ))),
                  SizedBox(
                      width: wide && !fullscreen ? 1 : 0,
                      child: Offstage(
                          offstage: !wide || fullscreen,
                          child: const VerticalDivider(width: 1))),
                  Expanded(
                      child: ContentWidth(
                          maxWidth: fullscreen ? double.infinity : 1440,
                          child: IndexedStack(index: _tab, children: pages))),
                ])),
              ]),
            ),
            bottomNavigationBar: fullscreen || wide
                ? null
                : DecoratedBox(
                    decoration: const BoxDecoration(
                      border: Border(
                          top: BorderSide(color: GnColors.border, width: 1)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: NavigationBar(
                        selectedIndex: _tab,
                        onDestinationSelected: _selectTab,
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
                          NavigationDestination(
                              icon: PlayerFaceIcon(
                                  face: widget.state.face,
                                  skin: widget.state.skinColor),
                              label: 'You'),
                        ],
                      ),
                    ),
                  ),
          ),
        );
      },
    );
  }
}
