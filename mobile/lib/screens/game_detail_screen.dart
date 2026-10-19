import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../account.dart';
import '../app_state.dart';
import '../catalog.dart';
import '../widgets/game_rating.dart';
import '../report_scope.dart';
import '../room_controls.dart';
import '../theme.dart';
import '../layout.dart';
import 'catalog_view.dart' show GameCover;

/// A game's page, with the same videos, screenshots and facts as the website.
class GameDetailScreen extends StatefulWidget {
  final CatalogGame game;
  final ValueChanged<String>? onTagSelected;
  final Future<ShareResult> Function(ShareParams)? share;

  /// Games in the same order as the list this page was opened from.
  final List<CatalogGame> games;

  /// What the room's host has; null outside a room.
  final Map<String, HostGame>? host;

  /// Puts a game in the room's queue.
  final Future<void> Function(CatalogGame game)? onAdd;

  /// Votes and like percentages; none without it.
  final CloudApi? cloud;

  /// Games this account develops, and opening one in the developer portal.
  final Set<String> developing;
  final void Function(CatalogGame game)? onManage;

  /// The player's Want to play list; no Want to play button without it.
  final AppState? state;

  /// Opens a page with every game by this developer.
  final ValueChanged<String>? onDeveloper;

  const GameDetailScreen(
      {super.key,
      required this.game,
      this.games = const [],
      this.host,
      this.onTagSelected,
      this.onAdd,
      this.developing = const {},
      this.onManage,
      this.cloud,
      this.state,
      this.onDeveloper,
      this.share});

  @override
  State<GameDetailScreen> createState() => _GameDetailScreenState();
}

class _GameDetailScreenState extends State<GameDetailScreen> {
  late final List<CatalogGame> _games;
  late final PageController _pages;
  late int _index;
  FeedbackGameContext? _feedbackGame;

  @override
  void initState() {
    super.initState();
    final byId = {for (final game in widget.games) game.id: game};
    if (!byId.containsKey(widget.game.id)) {
      _games = [widget.game, ...byId.values];
    } else {
      _games = byId.values.toList();
    }
    _index = _games.indexWhere((game) => game.id == widget.game.id);
    _pages = PageController(initialPage: _index);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _feedbackGame?.unregister(this);
    _feedbackGame = ReportScope.gameContextOf(context);
    final route = ModalRoute.of(context);
    _feedbackGame?.register(this,
        () => mounted && route?.isCurrent == true ? _games[_index].id : null);
  }

  @override
  void dispose() {
    _feedbackGame?.unregister(this);
    _pages.dispose();
    super.dispose();
  }

  void _go(int index) {
    if (index < 0 || index >= _games.length) return;
    _pages.animateToPage(index,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                _go(_index - 1),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                _go(_index + 1),
          },
          child: Focus(
              autofocus: MediaQuery.sizeOf(context).width >= 900,
              child: PageView.builder(
                key: const ValueKey('game-pages'),
                controller: _pages,
                itemCount: _games.length,
                onPageChanged: (index) => setState(() => _index = index),
                itemBuilder: (context, index) => _GameDetailPage(
                  key: ValueKey(_games[index].id),
                  previous: index > 0 ? () => _go(index - 1) : null,
                  next: index + 1 < _games.length ? () => _go(index + 1) : null,
                  game: _games[index],
                  games: _games,
                  active: index == _index,
                  host: widget.host,
                  onAdd: widget.onAdd,
                  onManage: widget.developing.contains(_games[index].id)
                      ? widget.onManage
                      : null,
                  share: widget.share,
                  cloud: widget.cloud,
                  state: widget.state,
                  onDeveloper: widget.onDeveloper,
                  onTagSelected: widget.onTagSelected,
                  onOpen: (game) =>
                      _go(_games.indexWhere((entry) => entry.id == game.id)),
                ),
              )));
}

class _GameDetailPage extends StatefulWidget {
  const _GameDetailPage(
      {super.key,
      required this.game,
      required this.games,
      required this.active,
      required this.onOpen,
      this.host,
      this.onAdd,
      this.onManage,
      this.cloud,
      this.state,
      this.onDeveloper,
      this.share,
      this.previous,
      this.onTagSelected,
      this.next});
  final VoidCallback? previous, next;
  final ValueChanged<String>? onTagSelected;
  final CatalogGame game;
  final List<CatalogGame> games;
  final bool active;
  final void Function(CatalogGame) onOpen;
  final Map<String, HostGame>? host;
  final Future<void> Function(CatalogGame)? onAdd;
  final void Function(CatalogGame)? onManage;
  final CloudApi? cloud;
  final AppState? state;
  final ValueChanged<String>? onDeveloper;
  final Future<ShareResult> Function(ShareParams)? share;
  @override
  State<_GameDetailPage> createState() => _GameDetailPageState();
}

class _GameDetailPageState extends State<_GameDetailPage> {
  bool _adding = false;

  CatalogGame get game => widget.game;

  Future<void> _add() async {
    setState(() => _adding = true);
    try {
      await widget.onAdd!(game);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  void _openOther(CatalogGame other) => widget.onOpen(other);

  Future<void> _share(BuildContext anchor) async {
    final box = anchor.findRenderObject() as RenderBox?;
    try {
      final result =
          await (widget.share ?? SharePlus.instance.share)(ShareParams(
        uri: game.page,
        title: game.title,
        subject: game.title,
        sharePositionOrigin:
            box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
      if (result.status != ShareResultStatus.unavailable) return;
    } catch (_) {
      /* Keep the website link usable even without a share target. */
    }
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text('Share ${game.title}'),
              content: SelectableText(game.page.toString()),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close')),
                TextButton(
                    onPressed: () async {
                      try {
                        await Clipboard.setData(
                            ClipboardData(text: game.page.toString()));
                        if (context.mounted) toast(context, 'Link copied');
                      } catch (_) {
                        if (context.mounted) {
                          toast(context, 'Select the link above to copy it.');
                        }
                      }
                    },
                    child: const Text('Copy link')),
              ],
            ));
  }

  @override
  Widget build(BuildContext context) {
    final similar = game.similar(widget.games);
    return Scaffold(
      appBar: AppBar(title: Text(game.title), actions: [
        if (MediaQuery.sizeOf(context).width >= 900) ...[
          IconButton(
              tooltip: 'Previous game (Left arrow)',
              onPressed: widget.previous,
              icon: const Icon(Icons.chevron_left)),
          IconButton(
              tooltip: 'Next game (Right arrow)',
              onPressed: widget.next,
              icon: const Icon(Icons.chevron_right)),
        ],
        Builder(
            builder: (context) => IconButton(
                  tooltip: 'Share game',
                  onPressed: () => _share(context),
                  icon: const Icon(Icons.share_outlined),
                )),
      ]),
      body: SafeArea(
          top: false,
          child: ContentWidth(
              maxWidth: 1040,
              child: ListView(
                  key: PageStorageKey('game-details-${game.id}'),
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    MediaGallery(game: game, active: widget.active),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(children: [
                              if (game.icon != null) ...[
                                ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: SizedBox.square(
                                        dimension: 40,
                                        child: _image(game.icon!))),
                                const SizedBox(width: 12),
                              ],
                              Expanded(
                                child: Text(game.title,
                                    style: const TextStyle(
                                        fontSize: 26,
                                        fontWeight: FontWeight.w800)),
                              ),
                            ]),
                            if (game.developer.isNotEmpty)
                              Align(
                                  alignment: Alignment.centerLeft,
                                  child: _developer()),
                            if (game.tagline.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(game.tagline,
                                  style: const TextStyle(
                                      fontSize: 16, color: GnColors.muted)),
                            ],
                            const SizedBox(height: 14),
                            Wrap(spacing: 8, runSpacing: 8, children: [
                              if (game.players.isNotEmpty)
                                _Fact(Icons.people_alt_outlined, game.players),
                              if (game.matchMinutes != null)
                                _Fact(Icons.timer_outlined,
                                    '${game.matchMinutes} min'),
                              _Fact(Icons.sell_outlined, game.priceLabel),
                              _Fact(Icons.computer, game.platformLabel),
                            ]),
                            if (widget.cloud != null && !game.unreviewed) ...[
                              const SizedBox(height: 12),
                              GameRating(
                                  key: ValueKey('rating-${game.id}'),
                                  game: game.id,
                                  cloud: widget.cloud),
                            ],
                            const SizedBox(height: 16),
                            _action(),
                            if (_wantButton() case final want?) ...[
                              const SizedBox(height: 8),
                              want,
                            ],
                            if (widget.onManage case final manage?) ...[
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                    minimumSize: const Size.fromHeight(48)),
                                onPressed: () => manage(game),
                                icon:
                                    const Icon(Icons.build_outlined, size: 18),
                                label: const Text('Manage game'),
                              ),
                            ],
                            if (game.tags.isNotEmpty) ...[
                              const SizedBox(height: 16),
                              Wrap(spacing: 6, runSpacing: 6, children: [
                                for (final tag in game.tags)
                                  ActionChip(
                                    onPressed: widget.onTagSelected == null
                                        ? null
                                        : () => widget.onTagSelected!(tag),
                                    label: Text(tag),
                                    visualDensity: VisualDensity.compact,
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                              ]),
                            ],
                            _about(),
                            if (similar.isNotEmpty) ...[
                              const SizedBox(height: 20),
                              const Text('More like this',
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700)),
                              const SizedBox(height: 10),
                              SizedBox(
                                height: 170,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: similar.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(width: 10),
                                  itemBuilder: (context, i) => _SimilarTile(
                                      game: similar[i],
                                      onTap: () => _openOther(similar[i])),
                                ),
                              ),
                            ],
                          ]),
                    ),
                  ]))),
    );
  }

  Widget _action() {
    final host = widget.host;
    if (host != null && widget.onAdd != null) {
      final known = host[game.id];
      if (known?.state == 'playing') return const _Note('Playing now');
      if (known?.playable ?? false) {
        return FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          onPressed: _adding ? null : _add,
          icon: _adding
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.playlist_add),
          label: const Text('Add to queue'),
        );
      }
    }
    final store = game.storeLink;
    final buy = !game.free && store != null
        ? OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48)),
            onPressed: () => _launch(context, store),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('View price & buy'),
          )
        : null;
    final note = _Note(game.unreviewed
        ? host == null
            ? 'Not in the store yet. Join a room to playtest: the GameNight '
                'gets your preview build while you are there.'
            : 'Your preview build is not on this GameNight yet. It comes '
                'with you once one is uploaded and ready.'
        : host == null
            ? 'Join a room to put this game in the queue.'
            : 'This GameNight does not have this game yet.');
    // Outside a room, Want to play says what happens next.
    if (host == null && !game.unreviewed && _canWant) {
      return buy ?? const SizedBox.shrink();
    }
    if (buy == null) return note;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      buy,
      const SizedBox(height: 8),
      note,
    ]);
  }

  bool get _canWant =>
      widget.state != null && widget.state!.cloud.signedIn && !game.unreviewed;

  /// Saves the game for the next room this player joins.
  Widget? _wantButton() {
    final state = widget.state;
    if (state == null || !_canWant) return null;
    return ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final wanted = state.wantToPlay?.contains(game.id) ?? false;
          return OutlinedButton.icon(
            key: const ValueKey('want-to-play'),
            style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                side: wanted ? const BorderSide(color: GnColors.accent) : null),
            onPressed: state.wantToPlay == null
                ? null
                : () async {
                    try {
                      await state.setWantToPlay(game.id, !wanted);
                      if (context.mounted && !wanted) {
                        toast(context,
                            '${game.title} goes in the queue when you join a room.');
                      }
                    } catch (_) {
                      if (context.mounted) {
                        toast(context, 'Could not save that. Try again.');
                      }
                    }
                  },
            icon:
                Icon(wanted ? Icons.bookmark : Icons.bookmark_border, size: 18),
            label: Text(wanted ? 'On your Want to play list' : 'Want to play'),
          );
        });
  }

  Widget _developer() {
    final open = widget.onDeveloper;
    final text = Text('by ${game.developer}',
        style: TextStyle(
            fontSize: 15,
            color: open == null ? GnColors.muted : GnColors.accent,
            fontWeight: FontWeight.w600));
    if (open == null) return text;
    return Semantics(
        container: true,
        button: true,
        child: InkWell(
            key: const ValueKey('developer'),
            borderRadius: BorderRadius.circular(6),
            onTap: () => open(game.developer),
            child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: text)));
  }

  Widget _about() {
    final links = {
      ...game.links,
      if (game.mediaSource != null) 'Gameplay source': game.mediaSource!
    };
    if (links.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 20),
      const Text('Links',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final MapEntry(:key, :value) in links.entries)
          OutlinedButton.icon(
            onPressed: () => _launch(context, value),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: Text(_linkName(key)),
          ),
      ]),
    ]);
  }

  static String _linkName(String key) =>
      const {
        'homepage': 'Homepage',
        'itch': 'itch.io',
        'steam': 'Steam',
        'source': 'Source code'
      }[key] ??
      key;
}

Future<void> _launch(BuildContext context, Uri url) async {
  var opened = false;
  try {
    opened = await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (!opened && context.mounted) toast(context, 'Could not open $url');
}

Widget _image(CatalogImage image, {BoxFit fit = BoxFit.cover, String? label}) {
  Widget broken(BuildContext _, Object __, StackTrace? ___) => const ColoredBox(
      color: GnColors.field, child: Center(child: Icon(Icons.broken_image)));
  if (image.bytes != null) {
    return Image.memory(image.bytes!,
        fit: fit,
        gaplessPlayback: true,
        errorBuilder: broken,
        semanticLabel: label);
  }
  return Image.network(image.url.toString(),
      fit: fit, errorBuilder: broken, semanticLabel: label);
}

class _Fact extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Fact(this.icon, this.text);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
            color: GnColors.field, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: GnColors.muted),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontSize: 13)),
        ]),
      );
}

class _Note extends StatelessWidget {
  final String text;
  const _Note(this.text);
  @override
  Widget build(BuildContext context) =>
      Align(alignment: Alignment.centerLeft, child: Hint(text));
}

class _SimilarTile extends StatelessWidget {
  final CatalogGame game;
  final VoidCallback onTap;
  const _SimilarTile({required this.game, required this.onTap});
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 110,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child:
                  AspectRatio(aspectRatio: 3 / 4, child: GameCover(game: game)),
            ),
            const SizedBox(height: 4),
            Text(game.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
        ),
      );
}

/// Swipe through a game's videos and screenshots. Only the visible video
/// loads; looping previews play muted by themselves, others on a tap.
class MediaGallery extends StatefulWidget {
  final CatalogGame game;
  final bool active;
  const MediaGallery({super.key, required this.game, this.active = true});

  @override
  State<MediaGallery> createState() => _MediaGalleryState();
}

class _MediaGalleryState extends State<MediaGallery> {
  final _pages = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int page) => _pages.animateToPage(page,
      duration: const Duration(milliseconds: 300), curve: Curves.easeOut);

  @override
  Widget build(BuildContext context) {
    final items = widget.game.media;
    if (items.isEmpty) {
      return AspectRatio(
          aspectRatio: 16 / 9, child: GameCover(game: widget.game));
    }
    return Column(children: [
      AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: PageView.builder(
            controller: _pages,
            // A mouse can drag through the slides too, as on the website.
            scrollBehavior:
                ScrollConfiguration.of(context).copyWith(dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
            }),
            itemCount: items.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, i) =>
                _slide(items[i], active: widget.active && i == _page),
          ),
        ),
      ),
      if (items.length > 1)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < items.length; i++)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _go(i),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: i == _page ? 18 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: i == _page
                          ? GnColors.accent
                          : GnColors.muted.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
          ]),
        ),
    ]);
  }

  Widget _slide(CatalogMedia item, {required bool active}) {
    final label = '${widget.game.title} ${item.label}';
    switch (item.kind) {
      case MediaKind.image:
        return _image(item.image!, fit: BoxFit.contain, label: label);
      case MediaKind.video:
        return active
            ? _VideoSlide(item: item, key: ValueKey(item.url))
            : _poster(item, Icons.play_circle_fill);
      case MediaKind.trailer:
        return Stack(fit: StackFit.expand, children: [
          _poster(item, null),
          Center(
            child: FilledButton.icon(
              onPressed: () => _launch(context, item.url!),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Watch the trailer'),
            ),
          ),
        ]);
    }
  }

  Widget _poster(CatalogMedia item, IconData? icon) {
    final poster = item.poster;
    return Stack(fit: StackFit.expand, children: [
      if (poster != null) _image(poster, fit: BoxFit.contain),
      if (icon != null)
        Center(child: Icon(icon, size: 56, color: Colors.white70)),
    ]);
  }
}

class _VideoSlide extends StatefulWidget {
  final CatalogMedia item;
  const _VideoSlide({super.key, required this.item});

  @override
  State<_VideoSlide> createState() => _VideoSlideState();
}

class _VideoSlideState extends State<_VideoSlide> {
  late final VideoPlayerController _video = VideoPlayerController.networkUrl(
      widget.item.url!,
      formatHint:
          widget.item.url!.path.endsWith('.m3u8') ? VideoFormat.hls : null,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));
  bool _failed = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _video.addListener(_onVideo);
    _video.setVolume(0);
    _video.setLooping(widget.item.preview);
    _video.initialize().then((_) {
      if (!mounted) return;
      // Short gameplay previews play by themselves, like on the website.
      if (widget.item.preview) _play();
      setState(() {});
    }, onError: (_) {
      if (mounted) setState(() => _failed = true);
    });
  }

  void _onVideo() {
    if (_video.value.hasError && !_failed && mounted) {
      setState(() => _failed = true);
    }
    if (mounted) setState(() {});
  }

  void _play() {
    _started = true;
    _video.play();
  }

  @override
  void dispose() {
    _video.removeListener(_onVideo);
    _video.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      final poster = widget.item.poster;
      return Stack(fit: StackFit.expand, children: [
        if (poster != null) _image(poster, fit: BoxFit.contain),
        const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
                padding: EdgeInsets.all(8), child: Hint('Video unavailable.'))),
      ]);
    }
    final ready = _video.value.isInitialized;
    final playing = _video.value.isPlaying;
    final poster = widget.item.poster;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: !ready
          ? null
          : () {
              if (playing) {
                _video.pause();
              } else {
                // A full video gets its sound once the player asks for it.
                if (!widget.item.preview) _video.setVolume(1);
                _play();
              }
            },
      child: Stack(fit: StackFit.expand, children: [
        if (!_started && poster != null) _image(poster, fit: BoxFit.contain),
        if (ready && _started)
          Center(
            child: AspectRatio(
                aspectRatio: _video.value.aspectRatio,
                child: VideoPlayer(_video)),
          ),
        if (!ready)
          const Center(child: CircularProgressIndicator())
        else if (!playing)
          const Center(
              child: Icon(Icons.play_circle_fill,
                  size: 56, color: Colors.white70)),
      ]),
    );
  }
}
