import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../catalog.dart';
import '../room_controls.dart';
import '../theme.dart';
import 'catalog_view.dart' show GameCover;

/// A game's page, with the same videos, screenshots and facts as the website.
class GameDetailScreen extends StatefulWidget {
  final CatalogGame game;

  /// The whole catalog, for "More like this".
  final List<CatalogGame> games;

  /// What the room's host has; null outside a room.
  final Map<String, HostGame>? host;

  /// Puts a game in the room's queue.
  final Future<void> Function(CatalogGame game)? onAdd;

  const GameDetailScreen(
      {super.key, required this.game, this.games = const [], this.host, this.onAdd});

  @override
  State<GameDetailScreen> createState() => _GameDetailScreenState();
}

class _GameDetailScreenState extends State<GameDetailScreen> {
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

  void _openOther(CatalogGame other) => Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => GameDetailScreen(
          game: other, games: widget.games, host: widget.host, onAdd: widget.onAdd)));

  @override
  Widget build(BuildContext context) {
    final similar = game.similar(widget.games);
    return Scaffold(
      appBar: AppBar(title: Text(game.title)),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        MediaGallery(game: game),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              if (game.icon != null) ...[
                ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox.square(dimension: 40, child: _image(game.icon!))),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Text(game.title,
                    style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
              ),
            ]),
            if (game.tagline.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(game.tagline, style: const TextStyle(fontSize: 16, color: GnColors.muted)),
            ],
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (game.players.isNotEmpty) _Fact(Icons.people_alt_outlined, game.players),
              if (game.matchMinutes != null) _Fact(Icons.timer_outlined, '${game.matchMinutes} min'),
              _Fact(Icons.sell_outlined, game.priceLabel),
              _Fact(Icons.computer, game.platformLabel),
            ]),
            const SizedBox(height: 16),
            _action(),
            if (game.tags.isNotEmpty) ...[
              const SizedBox(height: 16),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final tag in game.tags)
                  Chip(
                    label: Text(tag),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
              ]),
            ],
            const SizedBox(height: 8),
            _about(),
            if (similar.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('More like this',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              SizedBox(
                height: 170,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: similar.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, i) => _SimilarTile(
                      game: similar[i], onTap: () => _openOther(similar[i])),
                ),
              ),
            ],
          ]),
        ),
      ]),
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
              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.playlist_add),
          label: const Text('Add to queue'),
        );
      }
    }
    final store = game.storeLink;
    final buy = !game.free && store != null
        ? OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => _launch(context, store),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('View price & buy'),
          )
        : null;
    final note = _Note(host == null
        ? 'Join a room to put this game in the queue.'
        : 'This GameNight does not have this game yet.');
    if (buy == null) return note;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      buy,
      const SizedBox(height: 8),
      note,
    ]);
  }

  Widget _about() {
    final links = {...game.links, if (game.mediaSource != null) 'Gameplay source': game.mediaSource!};
    if (game.developer.isEmpty && links.isEmpty) return const SizedBox.shrink();
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: const Text('About this game', style: TextStyle(fontWeight: FontWeight.w700)),
        children: [
          if (game.developer.isNotEmpty) Hint('Made by ${game.developer}'),
          if (links.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final MapEntry(:key, :value) in links.entries)
                OutlinedButton.icon(
                  onPressed: () => _launch(context, value),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: Text(_linkName(key)),
                ),
            ]),
          ],
        ],
      ),
    );
  }

  static String _linkName(String key) =>
      const {'homepage': 'Homepage', 'itch': 'itch.io', 'steam': 'Steam', 'source': 'Source code'}[
          key] ??
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
  Widget broken(BuildContext _, Object __, StackTrace? ___) =>
      const ColoredBox(color: GnColors.field, child: Center(child: Icon(Icons.broken_image)));
  if (image.bytes != null) {
    return Image.memory(image.bytes!,
        fit: fit, gaplessPlayback: true, errorBuilder: broken, semanticLabel: label);
  }
  return Image.network(image.url.toString(), fit: fit, errorBuilder: broken, semanticLabel: label);
}

class _Fact extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Fact(this.icon, this.text);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: GnColors.field, borderRadius: BorderRadius.circular(20)),
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
  Widget build(BuildContext context) => Center(child: Hint(text));
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
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AspectRatio(aspectRatio: 3 / 4, child: GameCover(game: game)),
            ),
            const SizedBox(height: 4),
            Text(game.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
        ),
      );
}

/// Swipe through a game's videos and screenshots. Only the visible video
/// loads; looping previews play muted by themselves, others on a tap.
class MediaGallery extends StatefulWidget {
  final CatalogGame game;
  const MediaGallery({super.key, required this.game});

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
      return AspectRatio(aspectRatio: 16 / 9, child: GameCover(game: widget.game));
    }
    return Column(children: [
      AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: PageView.builder(
            controller: _pages,
            // A mouse can drag through the slides too, as on the website.
            scrollBehavior: ScrollConfiguration.of(context).copyWith(dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
            }),
            itemCount: items.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, i) => _slide(items[i], active: i == _page),
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
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: i == _page ? 18 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: i == _page ? GnColors.accent : GnColors.muted.withValues(alpha: 0.5),
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
      if (icon != null) Center(child: Icon(icon, size: 56, color: Colors.white70)),
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
  late final VideoPlayerController _video = VideoPlayerController.networkUrl(widget.item.url!,
      formatHint: widget.item.url!.path.endsWith('.m3u8') ? VideoFormat.hls : null,
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
    if (_video.value.hasError && !_failed && mounted) setState(() => _failed = true);
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
            child: Padding(padding: EdgeInsets.all(8), child: Hint('Video unavailable.'))),
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
            child: AspectRatio(aspectRatio: _video.value.aspectRatio, child: VideoPlayer(_video)),
          ),
        if (!ready)
          const Center(child: CircularProgressIndicator())
        else if (!playing)
          const Center(child: Icon(Icons.play_circle_fill, size: 56, color: Colors.white70)),
      ]),
    );
  }
}
