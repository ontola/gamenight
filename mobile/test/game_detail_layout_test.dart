import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/catalog.dart';
import 'package:gamenight/screens/game_detail_screen.dart';
import 'package:gamenight/theme.dart';
import 'package:gamenight/room_controls.dart';
import 'package:share_plus/share_plus.dart';

final _preview = GlobalKey();
final _previewDirectory = Platform.environment['GAME_DETAIL_PREVIEW_DIR'];
late List<CatalogGame> _games;

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = _previewDirectory;
  if (directory == null) return;
  await tester.pump();
  final boundary =
      _preview.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _open(WidgetTester tester,
    {Future<ShareResult> Function(ShareParams)? share}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
  tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 48);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(RepaintBoundary(
      key: _preview,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: gameNightTheme(),
        home: GameDetailScreen(game: _games.first, games: _games, share: share),
      )));
  // Decode committed catalog art on the real clock. No external image request.
  await tester.runAsync(() async {
    final context = tester.element(find.byType(GameDetailScreen));
    for (final game in _games) {
      if (game.coverBytes != null) {
        await precacheImage(MemoryImage(game.coverBytes!), context);
      }
      if (game.icon?.bytes != null) {
        await precacheImage(MemoryImage(game.icon!.bytes!), context);
      }
      for (final media in game.media) {
        if (media.image?.bytes != null) {
          await precacheImage(MemoryImage(media.image!.bytes!), context);
        }
      }
    }
  });
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final fonts = Platform.environment['GAME_DETAIL_PREVIEW_FONTS'];
    if (fonts != null) {
      final roboto = FontLoader('Roboto');
      for (final weight in ['Regular', 'Bold']) {
        roboto.addFont(File('$fonts/Roboto-$weight.ttf')
            .readAsBytes()
            .then(ByteData.sublistView));
      }
      await roboto.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    }
    _games = [
      for (final id in ['blast-party', 'bubble-buddies', 'ricochet-club'])
        (() {
          final data =
              jsonDecode(File('../catalog/games/$id.json').readAsStringSync())
                  as Map<String, dynamic>;
          // Use the checked-in gameplay screenshot instead of a network video in
          // this deterministic layout/share test. All other metadata is real.
          data['media'] = <String, dynamic>{};
          data['screenshot'] =
              'data:image/png;base64,${base64Encode(File('../catalog/art/$id/screenshot.png').readAsBytesSync())}';
          data['media'] = {
            'items': [
              {'kind': 'image', 'url': data['screenshot'], 'label': 'Gameplay'}
            ]
          };
          return CatalogGame.fromJson(data)!;
        })()
    ];
  });

  testWidgets('similar game labels fully scroll above a 48px navigation inset',
      (tester) async {
    await _open(tester);
    await _capture(tester, 'game-detail-top');
    final outer = tester.state<ScrollableState>(find
        .descendant(
            of: find.byType(ListView).first, matching: find.byType(Scrollable))
        .first);
    outer.position.jumpTo(outer.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('More like this').hitTestable(), findsOneWidget);
    final title = find.text(_games.first.similar(_games).first.title);
    expect(title.hitTestable(), findsOneWidget);
    final titleRect = tester.getRect(title);
    expect(titleRect.bottom, lessThanOrEqualTo(844 - 48),
        reason: 'whole label clears the system navigation area');
    final list = tester.getRect(find.byType(ListView).first);
    expect(list.bottom, 844 - 48);
    final appBarTheme =
        Theme.of(tester.element(find.byType(GameDetailScreen))).appBarTheme;
    expect(appBarTheme.backgroundColor, GnColors.bg);
    expect(appBarTheme.scrolledUnderElevation, 0);
    expect(appBarTheme.systemOverlayStyle!.systemNavigationBarIconBrightness,
        Brightness.light);
    await _capture(tester, 'game-detail-bottom-safe');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'swipe changes games in list order and share uses the visible game',
      (tester) async {
    ShareParams? shared;
    await _open(tester, share: (params) async {
      shared = params;
      return const ShareResult('test', ShareResultStatus.success);
    });
    await tester.dragFrom(const Offset(300, 430), const Offset(-310, 0));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, _games[1].title).hitTestable(),
        findsOneWidget);
    await tester.tap(find.byTooltip('Share game').hitTestable());
    await tester.pumpAndSettle();
    expect(shared!.uri, _games[1].page);
    await _capture(tester, 'game-swiped-next');
    await tester.dragFrom(const Offset(70, 430), const Offset(310, 0));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, _games[0].title).hitTestable(),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'media gestures stay inside gallery and game swipes stop at list ends',
      (tester) async {
    await _open(tester);
    await tester.drag(
        find.byType(MediaGallery).hitTestable(), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, _games[0].title).hitTestable(),
        findsOneWidget);
    expect(find.byTooltip('Previous game'), findsNothing);
    expect(find.byTooltip('Next game'), findsNothing);
    for (var i = 0; i < 2; i++) {
      await tester.dragFrom(const Offset(300, 430), const Offset(-700, 0));
      await tester.pumpAndSettle();
    }
    expect(find.widgetWithText(AppBar, _games[2].title).hitTestable(),
        findsOneWidget);
    await tester.dragFrom(const Offset(300, 430), const Offset(-310, 0));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, _games[2].title).hitTestable(),
        findsOneWidget);
  });

  testWidgets(
      'opening a middle game keeps list position and queues the swiped game',
      (tester) async {
    String? queued;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => GameDetailScreen(
                            game: _games[1],
                            games: _games,
                            host: {
                              for (final game in _games)
                                game.id: HostGame(id: game.id, playable: true)
                            },
                            onAdd: (game) async {
                              queued = game.id;
                            }))),
                child: const Text('Open list game')))));
    await tester.tap(find.text('Open list game'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, _games[1].title).hitTestable(),
        findsOneWidget);
    await tester.dragFrom(const Offset(300, 430), const Offset(-700, 0));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.descendant(
        of: find.byKey(ValueKey(_games[2].id)),
        matching: find.text('Add to queue')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to queue').hitTestable());
    await tester.pumpAndSettle();
    expect(queued, _games[2].id);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Open list game'), findsOneWidget);
  });

  testWidgets('share receives canonical game page and a real nonzero anchor',
      (tester) async {
    ShareParams? received;
    await _open(tester, share: (params) async {
      received = params;
      return const ShareResult('test target', ShareResultStatus.success);
    });
    await tester.tap(find.byTooltip('Share game'));
    await tester.pumpAndSettle();
    expect(received!.uri,
        Uri.parse('https://gamenight.ontola.io/games/blast-party'));
    expect(received!.uri, _games.first.page);
    expect(received!.title, 'Blast Party');
    final anchor = received!.sharePositionOrigin!;
    expect(anchor.width, greaterThan(0));
    expect(anchor.height, greaterThan(0));
    expect(const Rect.fromLTWH(0, 0, 390, 844).contains(anchor.center), isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'unavailable share offers selectable canonical link and clipboard fallback',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await _open(tester, share: (_) async => ShareResult.unavailable);
    await tester.tap(find.byTooltip('Share game'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.widget<SelectableText>(find.byType(SelectableText)).data,
        _games.first.page.toString());
    await _capture(tester, 'game-share-link-fallback');
    await tester.tap(find.text('Copy link'));
    await tester.pumpAndSettle();
    expect(copied, _games.first.page.toString());
    expect(find.text('Link copied'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('share platform exception keeps the link available',
      (tester) async {
    await _open(tester,
        share: (_) async => throw PlatformException(code: 'unavailable'));
    await tester.tap(find.byTooltip('Share game'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
