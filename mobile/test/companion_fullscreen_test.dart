import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/account.dart';
import 'package:gamenight/api.dart';
import 'package:gamenight/app_state.dart';
import 'package:gamenight/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class PhonePlatform extends WebViewPlatform {
  final loads = <Uri>[];
  @override
  PlatformWebViewController createPlatformWebViewController(
          PlatformWebViewControllerCreationParams params) =>
      PhoneController(params, loads);
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
          PlatformWebViewWidgetCreationParams params) =>
      PhoneWidget(params);
}

class PhoneController extends PlatformWebViewController {
  PhoneController(super.params, this.loads) : super.implementation();
  final List<Uri> loads;
  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}
  @override
  Future<void> setBackgroundColor(Color color) async {}
  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    loads.add(params.uri);
  }
}

class PhoneWidget extends PlatformWebViewWidget {
  PhoneWidget(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: Color(0xff163c32),
        child: Center(
            child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.style, color: Color(0xffd7c48c), size: 64),
                    SizedBox(height: 24),
                    Text('Phone screen preview',
                        style:
                            TextStyle(fontSize: 24, color: Color(0xfff5efdf))),
                    SizedBox(height: 12),
                    Text('Test game content',
                        style: TextStyle(color: Color(0xffd7c48c))),
                  ],
                ))),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fonts = Platform.environment['ROOM_PREVIEW_FONTS'];
    if (fonts == null) return;
    for (final family in ['Roboto', 'Ahem']) {
      final loader = FontLoader(family)
        ..addFont(File('$fonts/Roboto-Regular.ttf')
            .readAsBytes()
            .then((b) => ByteData.sublistView(b)));
      await loader.load();
    }
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  testWidgets(
      'full screen preserves phone connection and Back restores app navigation',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'cloud_token': 'test-only', 'hosted_room': true});
    final room = {
      'status': 'connected',
      'room_code': 'TEST42',
      'players': 2,
      'fresh': true,
      'discovery': {
        'current': 'pocket-aces',
        'games': [],
        'playlist': {'entries': []}
      }
    };
    final state = AppState(await SharedPreferences.getInstance(),
        cloud: CloudApi(
            client:
                MockClient((_) async => http.Response(jsonEncode(room), 200))));
    state.hostedRoom = HostedRoom(room);
    state.companion = const Companion(
        game: 'pocket-aces',
        title: 'Pocket Aces',
        url: '/v1/companion/test-only/index.html');
    final platform = PhonePlatform();
    WebViewPlatform.instance = platform;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
        RepaintBoundary(key: boundaryKey, child: GameNightApp(state: state)));
    await tester.pumpAndSettle();
    expect(platform.loads, hasLength(1));
    for (final size in [
      const Size(1280, 900),
      const Size(1920, 1080),
      const Size(390, 844)
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar),
          size.width >= 900 ? findsNothing : findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-sidebar')),
          size.width >= 900 ? findsOneWidget : findsNothing);
      expect(platform.loads, hasLength(1),
          reason: 'Resizing keeps the private game mounted');
      expect(tester.takeException(), isNull);
    }
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.tap(find.byTooltip('Full screen'));
    await tester.pumpAndSettle();
    expect(state.companionFullscreen, isTrue);
    expect(find.byKey(const ValueKey('app-brand')), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(SegmentedButton<int>), findsNothing);
    expect(find.byTooltip('Exit full screen'), findsOneWidget);
    expect(platform.loads, hasLength(1),
        reason: 'Expanding must not reload the private phone page');
    final directory = Platform.environment['ROOM_PREVIEW_DIR'];
    if (directory != null) {
      await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(directory).create(recursive: true);
        await File('$directory/companion-fullscreen.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(state.companionFullscreen, isFalse);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(platform.loads, hasLength(1));
    await tester.tap(find.byTooltip('Full screen'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Exit full screen'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-brand')), findsOneWidget);
    state.setCompanionFullscreen(true);
    state.companion = null;
    state.notifyListeners();
    await tester.pumpAndSettle();
    expect(state.companionFullscreen, isFalse);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
