import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart' show ApiError;
import 'app_update.dart';
import 'app_state.dart';
import 'link.dart';
import 'layout.dart';
import 'player_face.dart';
import 'navigation/browser_history.dart';
import 'navigation/open_website.dart';
import 'navigation/website_session.dart';
import 'reports.dart';
import 'report_scope.dart';
import 'diagnostics.dart';
import 'screens/feedback_screen.dart';
import 'screens/about_screen.dart';
import 'screens/assistant_screen.dart';
import 'screens/game_screen.dart';
import 'screens/player_screen.dart';
import 'screens/room_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(gameNightSystemUi);
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
        ['Bungee'], await rootBundle.loadString('assets/fonts/OFL-Bungee.txt'));
    yield LicenseEntryWithLineBreaks(
        ['Outfit'], await rootBundle.loadString('assets/fonts/OFL-Outfit.txt'));
  });
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
  final _homeKey = GlobalKey<_HomeScreenState>();
  final _feedbackGame = FeedbackGameContext();
  int _selectedTab = 0;

  /// The About page is open, so no sidebar tab shows as current.
  bool _aboutOpen = false;
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
      _selectedTab = _history!.tab;
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
      key: _homeKey,
      onMore: _menu,
      onTabChanged: (tab) {
        if (mounted && _selectedTab != tab) setState(() => _selectedTab = tab);
      },
      state: widget.state,
      links: widget.links,
      initialLink: widget.initialLink,
      accountLoading: widget.accountLoading,
      reports: widget.reports,
      history: _history);

  void _feedback() {
    final reports = widget.reports;
    if (reports == null) return;
    final game = _feedbackGame.game;
    _navigator.currentState?.push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'feedback'),
      builder: (_) => FeedbackScreen(reports: reports, initialGame: game),
    ));
  }

  void _assistant() {
    _navigator.currentState?.push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'assistant'),
      builder: (_) => AssistantScreen(state: widget.state),
    ));
  }

  void _about() {
    final navigator = _navigator.currentState;
    if (navigator == null) return;
    String? top;
    navigator.popUntil((route) {
      top = route.settings.name;
      return true;
    });
    if (top == 'about') return;
    setState(() => _aboutOpen = true);
    navigator
        .push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'about'),
      builder: (_) => AboutScreen(
          state: widget.state,
          onHost: () => _openWebsite('/host'),
          onDocs: () => _openWebsite('/docs'),
          onScan: () {
            _selectDestination(0);
            _homeKey.currentState?._roomKey.currentState?.scan();
          }),
    ))
        .whenComplete(() {
      if (mounted) setState(() => _aboutOpen = false);
    });
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
                if (widget.reports != null)
                  ListTile(
                      leading: const Icon(Icons.mic_none),
                      title: const Text('Feedback'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.pop(context);
                        _feedback();
                      }),
                for (final entry in const [
                  ('/developers', 'Developer portal', Icons.code),
                  ('/docs', 'Documentation', Icons.menu_book_outlined),
                  (
                    '/docs/privacy',
                    'Privacy policy',
                    Icons.privacy_tip_outlined
                  ),
                  ('/host', 'Host a room', Icons.tv),
                ])
                  ListTile(
                      leading: Icon(entry.$3),
                      title: Text(entry.$2),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () {
                        Navigator.pop(context);
                        _openWebsite(entry.$1);
                      }),
              ]),
            ));
  }

  Future<void> _openWebsite(String path) =>
      openWebsite(widget.state.cloud, path);

  void _selectDestination(int tab) {
    _navigator.currentState?.popUntil((route) => route.isFirst);
    _homeKey.currentState?._selectTab(tab);
  }

  Widget _sidebar() => Material(
        color: GnColors.bg,
        child: ListView(
          key: const ValueKey('desktop-sidebar'),
          padding: const EdgeInsets.fromLTRB(12, 24, 12, 20),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 20),
              child: _BrandButton(
                onTap: _about,
                padding: const EdgeInsets.fromLTRB(10, 4, 8, 4),
                child: const Row(children: [
                  GameNightLogo(size: 28),
                  SizedBox(width: 9),
                  Expanded(
                      child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: GameNightWordmark(
                              key: ValueKey('app-brand'), size: 19)))
                ]),
              ),
            ),
            for (final entry in [
              (0, 'Room', Icons.meeting_room_outlined, Icons.meeting_room),
              (1, 'Games', Icons.sports_esports_outlined, Icons.sports_esports),
            ])
              _SidebarItem(
                key: ValueKey('desktop-tab-${entry.$1}'),
                label: entry.$2,
                icon: Icon(_selectedTab == entry.$1 ? entry.$4 : entry.$3),
                selected: !_aboutOpen && _selectedTab == entry.$1,
                onTap: () => _selectDestination(entry.$1),
              ),
            _SidebarItem(
              key: const ValueKey('desktop-tab-2'),
              label: 'You',
              icon: FittedBox(
                  child: PlayerFaceIcon(
                      face: widget.state.face, skin: widget.state.skinColor)),
              selected: !_aboutOpen && _selectedTab == 2,
              onTap: () => _selectDestination(2),
            ),
            const _SidebarHeading('Help'),
            _SidebarItem(
                label: 'Assistant',
                icon: const Icon(Icons.auto_awesome_outlined),
                onTap: _assistant),
            if (widget.reports != null)
              _SidebarItem(
                  label: 'Feedback',
                  icon: const Icon(Icons.mic_none),
                  onTap: _feedback),
            const _SidebarHeading('Website'),
            for (final entry in const [
              ('/developers', 'Developer portal', Icons.code),
              ('/docs', 'Documentation', Icons.menu_book_outlined),
              ('/docs/privacy', 'Privacy policy', Icons.privacy_tip_outlined),
              ('/host', 'Host a room', Icons.tv),
            ])
              _SidebarItem(
                  label: entry.$2,
                  icon: Icon(entry.$3),
                  external: true,
                  onTap: () => _openWebsite(entry.$1)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: kIsWeb ? null : _navigator,
        title: 'GameNight',
        debugShowCheckedModeBanner: false,
        theme: gameNightTheme(),
        builder: (context, child) => ListenableBuilder(
          listenable: widget.state,
          builder: (context, _) {
            final desktop = MediaQuery.sizeOf(context).width >= 900;
            final fullscreen = widget.state.companionFullscreen;
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: gameNightSystemUi,
              child: ReportScope(
                reports: widget.reports,
                gameContext: _feedbackGame,
                child: ColoredBox(
                  color: GnColors.bg,
                  child: SafeArea(
                    bottom: false,
                    // Navigator stays at the same tree position on resize. All pushed
                    // pages live inside this shell, including face, sign-in and feedback.
                    child: Row(textDirection: TextDirection.rtl, children: [
                      Expanded(
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
                              visible: !desktop && !fullscreen,
                              child: Material(
                                color: GnColors.bg,
                                child: Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(8, 4, 8, 4),
                                  child: Row(children: [
                                    Expanded(
                                        child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: _BrandButton(
                                        onTap: _about,
                                        child: const Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              GameNightLogo(size: 28),
                                              SizedBox(width: 8),
                                              Flexible(
                                                  child: FittedBox(
                                                      fit: BoxFit.scaleDown,
                                                      alignment:
                                                          Alignment.centerLeft,
                                                      child: GameNightWordmark(
                                                          key: ValueKey(
                                                              'app-brand'),
                                                          size: 21))),
                                            ]),
                                      ),
                                    )),
                                    if (widget.reports != null &&
                                        MediaQuery.sizeOf(context).width < 440)
                                      Semantics(
                                          container: true,
                                          label: 'Feedback',
                                          button: true,
                                          excludeSemantics: true,
                                          onTap: _feedback,
                                          child: IconButton(
                                              onPressed: _feedback,
                                              icon:
                                                  const Icon(Icons.mic_none))),
                                    if (widget.reports != null &&
                                        MediaQuery.sizeOf(context).width >= 440)
                                      TextButton.icon(
                                          onPressed: _feedback,
                                          icon: const Icon(Icons.mic_none,
                                              size: 20),
                                          label: const Text('Feedback')),
                                  ]),
                                ),
                              ),
                            ),
                          ])),
                      SizedBox(
                          width: desktop && !fullscreen ? 248 : 0,
                          child: desktop && !fullscreen ? _sidebar() : null),
                    ]),
                  ),
                ),
              ),
            );
          },
        ),
        home: kIsWeb ? null : _home(),
      );
}

class HomeScreen extends StatefulWidget {
  final ValueChanged<int>? onTabChanged;

  /// The phone's More tab: assistant and website links, in a sheet.
  final VoidCallback? onMore;
  final AppState state;
  final BrowserNavigation? history;
  final ReportService? reports;
  final Stream<Uri>? links;
  final Uri? initialLink;
  final Future<void>? accountLoading;
  const HomeScreen(
      {super.key,
      required this.state,
      this.onTabChanged,
      this.onMore,
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
      widget.onTabChanged?.call(_tab);
    }
  }

  void _selectTab(int tab) {
    if (widget.history case final history?) {
      history.selectTab(tab);
    } else if (_tab != tab) {
      setState(() => _tab = tab);
      widget.onTabChanged?.call(_tab);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.reports?.flush());
      if (widget.state.cloud.browserCookies) {
        unawaited(widget.state.loadAccount());
      } else {
        unawaited(widget.state.findHostedRoom());
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
                    child: ContentWidth(
                        maxWidth: fullscreen ? double.infinity : 1440,
                        child: IndexedStack(index: _tab, children: pages))),
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
                        onDestinationSelected: (tab) =>
                            tab == 3 ? widget.onMore?.call() : _selectTab(tab),
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
                          if (widget.onMore != null)
                            const NavigationDestination(
                                icon: Icon(Icons.more_horiz), label: 'More'),
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

/// Small caps label above a group of sidebar items.
class _SidebarHeading extends StatelessWidget {
  final String text;
  const _SidebarHeading(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 24, 14, 8),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                color: GnColors.muted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2)),
      );
}

/// One sidebar button. Every item shares the same height, padding, icon
/// slot and rounded highlight, whether it is a tab, an action or a link.
class _SidebarItem extends StatelessWidget {
  final String label;
  final Widget icon;
  final VoidCallback onTap;
  final bool selected;
  final bool external;
  const _SidebarItem(
      {super.key,
      required this.label,
      required this.icon,
      required this.onTap,
      this.selected = false,
      this.external = false});

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? Colors.white : GnColors.text;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: selected ? GnColors.button : Colors.transparent,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                  color: selected
                      ? GnColors.accent.withValues(alpha: .6)
                      : Colors.transparent)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            hoverColor: Colors.white.withValues(alpha: .06),
            focusColor: Colors.white.withValues(alpha: .1),
            highlightColor: Colors.white.withValues(alpha: .08),
            splashColor: GnColors.accent.withValues(alpha: .25),
            child: SizedBox(
              height: 46,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(children: [
                  IconTheme.merge(
                    data: IconThemeData(
                        size: 22,
                        color: selected ? Colors.white : GnColors.muted),
                    child: SizedBox.square(dimension: 24, child: icon),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                      child: Text(label,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: foreground,
                              fontSize: 15,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w500))),
                  if (external)
                    const Icon(Icons.open_in_new,
                        size: 15, color: GnColors.muted),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The logo and wordmark; a tap opens the About page.
class _BrandButton extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  final EdgeInsets padding;
  const _BrandButton(
      {required this.child,
      required this.onTap,
      this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4)});

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'About GameNight',
        excludeSemantics: true,
        child: InkWell(
          key: const ValueKey('about-button'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(padding: padding, child: child),
        ),
      );
}
