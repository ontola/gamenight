import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'browser_location_stub.dart'
    if (dart.library.js_interop) 'browser_location_web.dart' as location;

/// Browser history owns only UI destinations. Room/account capabilities and
/// invitation links never enter route information or the browser's history state.
class BrowserNavigation extends ChangeNotifier with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> navigatorKey;
  final bool Function() fullscreen;
  final void Function(bool) setFullscreen;
  final Future<void> Function(RouteInformation, bool) report;
  final void Function() back;
  late final NavigatorObserver observer = _HistoryObserver(this);
  final List<Route<dynamic>> _routes = [];
  final Expando<int> _routeIds = Expando<int>();
  final Map<int, Route<dynamic> Function()> _builders = {};
  final Map<int, _Destination> _entries = {};
  // Route builders belong to this page load, not earlier browser entries.
  final String _instance = List.generate(16,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join();
  int _nextRoute = 1, _entry = 0;
  int tab;
  bool _restoring = false, _scheduled = false, _preferBack = false;
  bool _disposed = false;
  _Destination? _last;

  BrowserNavigation({
    required this.navigatorKey,
    required this.fullscreen,
    required this.setFullscreen,
    Future<void> Function(RouteInformation, bool)? report,
    void Function()? back,
    Uri? initialUri,
    bool attach = true,
  })  : report = report ?? _report,
        back = back ?? location.back,
        tab = _initialTab(initialUri ?? Uri.base) {
    if (attach) {
      location.cleanLaunchUrl();
      WidgetsBinding.instance.addObserver(this);
    }
  }

  static int _initialTab(Uri uri) {
    final path = uri.fragment.startsWith('/')
        ? Uri.tryParse(uri.fragment)?.path
        : uri.path;
    return path == '/games'
        ? 1
        : path == '/you'
            ? 2
            : 0;
  }

  static Future<void> _report(
      RouteInformation information, bool replace) async {
    await SystemNavigator.selectMultiEntryHistory();
    await SystemNavigator.routeInformationUpdated(
        uri: information.uri, state: information.state, replace: replace);
  }

  void selectTab(int value) {
    if (value == tab || value < 0 || value > 2) return;
    tab = value;
    notifyListeners();
    _schedule();
  }

  void fullscreenChanged() {
    if (_last?.fullscreen == fullscreen()) return;
    _schedule(preferBack: !fullscreen());
  }

  _Destination get _current => _Destination(
      tab, fullscreen(), _routes.skip(1).map((r) => _routeIds[r]!).toList());

  void _pushed(Route<dynamic> route) {
    _routes.add(route);
    if (_routes.length > 1) {
      final id = _routeIds[route] ?? _nextRoute++;
      _routeIds[route] = id;
      // Keep a builder, never a disposed Route/animation/controller. Dialogs
      // still get a Back entry, but are not resurrected by Forward.
      if (route is MaterialPageRoute<dynamic>) {
        final builder = route.builder;
        final settings = route.settings;
        final dialog = route.fullscreenDialog;
        final maintainState = route.maintainState;
        _builders[id] = () => MaterialPageRoute<dynamic>(
            builder: builder,
            settings: settings,
            fullscreenDialog: dialog,
            maintainState: maintainState);
      }
    }
    _schedule();
  }

  void _removed(Route<dynamic> route, {bool popped = false}) {
    _routes.remove(route);
    _schedule(preferBack: popped);
  }

  void _schedule({bool preferBack = false}) {
    if (_disposed || _restoring) return;
    _preferBack |= preferBack;
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (_disposed || _restoring || _routes.isEmpty) return;
      final target = _current;
      final goBack = _preferBack;
      _preferBack = false;
      if (target.same(_last)) return;
      if (goBack && target.same(_entries[_entry - 1])) {
        back();
        return;
      }
      final first = _last == null;
      if (!first) {
        _entries.removeWhere((id, _) => id > _entry);
        _entry++;
      }
      _entries[_entry] = target;
      _last = target;
      unawaited(report(_information(target), first));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  RouteInformation _information(_Destination target) => RouteInformation(
          uri: Uri(
              path: const ['/room', '/games', '/you'][target.tab],
              queryParameters: {
                if (target.routes.isNotEmpty)
                  'screen': target.routes.last.toString(),
                if (target.fullscreen) 'fullscreen': '1',
              }.isEmpty
                  ? null
                  : {
                      if (target.routes.isNotEmpty)
                        'screen': target.routes.last.toString(),
                      if (target.fullscreen) 'fullscreen': '1',
                    }),
          state: {
            'gamenight_navigation': 1,
            'instance': _instance,
            'entry': _entry,
            'tab': target.tab,
            'fullscreen': target.fullscreen,
            'routes': target.routes
          });

  @override
  Future<bool> didPushRouteInformation(
      RouteInformation routeInformation) async {
    final data = routeInformation.state;
    final valid = data is Map &&
        data['gamenight_navigation'] == 1 &&
        data['entry'] is int &&
        data['tab'] is int &&
        data['tab'] >= 0 &&
        data['tab'] <= 2 &&
        data['routes'] is List;
    final sameInstance = valid && data['instance'] == _instance;
    final wanted = sameInstance
        ? _Destination(data['tab'] as int, data['fullscreen'] == true,
            (data['routes'] as List).whereType<int>().take(32).toList())
        : _Destination(
            valid ? data['tab'] as int : _initialTab(routeInformation.uri),
            false, []);
    _restoring = true;
    try {
      if (sameInstance) _entry = data['entry'] as int;
      final desired = <int>[];
      for (final id in wanted.routes) {
        if (!_builders.containsKey(id) &&
            !_routes.any((r) => _routeIds[r] == id)) {
          break;
        }
        desired.add(id);
      }
      final current = _current.routes;
      var shared = 0;
      while (shared < current.length &&
          shared < desired.length &&
          current[shared] == desired[shared]) {
        shared++;
      }
      final nav = navigatorKey.currentState;
      while (_routes.length > shared + 1 && nav != null) {
        final length = _routes.length;
        nav.pop();
        if (_routes.length == length) break;
      }
      for (final id in desired.skip(shared)) {
        final create = _builders[id];
        if (create == null) break;
        final route = create();
        _routeIds[route] = id;
        nav?.push(route);
      }
      tab = wanted.tab;
      setFullscreen(wanted.fullscreen);
      notifyListeners();
      _last = _current;
      _entries[_entry] = _last!;
      // A reload cannot restore an in-memory builder. Keep the known tab,
      // safely discard stale route IDs, and replace rather than add history.
      if (!sameInstance || !_last!.same(wanted)) {
        await report(_information(_last!), true);
      }
    } finally {
      _preferBack = false;
      _restoring = false;
    }
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class _Destination {
  final int tab;
  final bool fullscreen;
  final List<int> routes;
  const _Destination(this.tab, this.fullscreen, this.routes);
  bool same(_Destination? other) =>
      other != null &&
      tab == other.tab &&
      fullscreen == other.fullscreen &&
      listEquals(routes, other.routes);
}

class _HistoryObserver extends NavigatorObserver {
  final BrowserNavigation history;
  _HistoryObserver(this.history);
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      history._pushed(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      history._removed(route, popped: true);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      history._removed(route);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) history._removed(oldRoute);
    if (newRoute != null) history._pushed(newRoute);
  }
}
