import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Colours from web/site.css, so the app and the phone studio match.
class GnColors {
  static const bg = Color(0xFF0D1020);
  static const card = Color(0xFF181E30);
  static const field = Color(0xFF20283C);
  static const border = Color(0xFF343B53);
  static const text = Color(0xFFEEF0FC);
  static const muted = Color(0xFFA8ADC4);
  static const accent = Color(0xFF7565EE);
  static const button = Color(0xFF5143AE);
  static const ok = Color(0xFF34D399);
  static const warn = Color(0xFFFBBF24);
  static const canvas = Color(0xFF0F172A);
}

// On edge-to-edge Android the bar is transparent, so the app paints the
// dark surface behind it. Older versions also use the explicit bar color.
const gameNightSystemUi = SystemUiOverlayStyle(
  systemNavigationBarColor: GnColors.bg,
  systemNavigationBarDividerColor: GnColors.bg,
  systemNavigationBarIconBrightness: Brightness.light,
  systemNavigationBarContrastEnforced: false,
);

Color hexColor(String hex) =>
    Color(int.parse(hex.substring(1, 7), radix: 16) | 0xFF000000);

ThemeData gameNightTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: GnColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: GnColors.accent,
    surface: GnColors.bg,
    onSurface: GnColors.text,
    surfaceContainerHighest: GnColors.field,
    outline: GnColors.border,
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(10));
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: GnColors.bg,
    useMaterial3: true,
    appBarTheme: const AppBarTheme(
      backgroundColor: GnColors.bg,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      systemOverlayStyle: gameNightSystemUi,
    ),
    cardTheme: CardThemeData(
      color: GnColors.card,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: GnColors.border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: GnColors.button,
        foregroundColor: Colors.white,
        minimumSize: const Size(44, 48),
        shape: shape,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: GnColors.text,
        backgroundColor: GnColors.field,
        side: const BorderSide(color: GnColors.border),
        minimumSize: const Size(44, 44),
        shape: shape,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: GnColors.field,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: GnColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: GnColors.border),
      ),
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: GnColors.bg,
      indicatorColor: GnColors.button,
      selectedLabelTextStyle:
          TextStyle(color: GnColors.text, fontWeight: FontWeight.w700),
      unselectedLabelTextStyle: TextStyle(color: GnColors.muted),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: GnColors.card,
      indicatorColor: GnColors.button,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    pageTransitionsTheme: PageTransitionsTheme(builders: {
      for (final platform in TargetPlatform.values)
        platform: _WidthPageTransitionsBuilder(),
    }),
  );
}

/// Next to the desktop sidebar a page grows from the middle of the content
/// area; a sideways slide there shoves the whole screen past the sidebar.
/// Phones keep their platform's own transition.
class _WidthPageTransitionsBuilder extends PageTransitionsBuilder {
  const _WidthPageTransitionsBuilder();
  static const _desktop = ZoomPageTransitionsBuilder();
  static const _cupertino = CupertinoPageTransitionsBuilder();
  static const _android = FadeForwardsPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
      PageRoute<T> route,
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      Widget child) {
    final builder = MediaQuery.sizeOf(context).width >= 900
        ? _desktop
        : switch (Theme.of(context).platform) {
            TargetPlatform.iOS || TargetPlatform.macOS => _cupertino,
            _ => _android,
          };
    return builder.buildTransitions(
        route, context, animation, secondaryAnimation, child);
  }
}

/// A titled card, the building block of every screen.
class Section extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  const Section({super.key, this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(title!,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
              ),
            ...children,
          ],
        ),
      ),
    );
  }
}

class Hint extends StatelessWidget {
  final String text;
  const Hint(this.text, {super.key});
  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(color: GnColors.muted, fontSize: 14));
}

void toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// The GameNight logo: the website's own icon (`web/icon.svg`, copied by
/// `scripts/generate-branding.cjs`), never a stand-in.
class GameNightLogo extends StatelessWidget {
  final double size;
  const GameNightLogo({super.key, this.size = 32});

  @override
  Widget build(BuildContext context) => SvgPicture.asset('assets/icon.svg',
      width: size, height: size, semanticsLabel: 'GameNight');
}

/// Shared wordmark: Bungee and the amber/lilac palette from the intro video.
class GameNightWordmark extends StatelessWidget {
  final double size;
  const GameNightWordmark({super.key, this.size = 21});
  @override
  Widget build(BuildContext context) => Semantics(
        label: 'GameNight',
        excludeSemantics: true,
        child: Text.rich(
          const TextSpan(children: [
            TextSpan(text: 'Game', style: TextStyle(color: Color(0xFFFFB454))),
            TextSpan(text: 'Night', style: TextStyle(color: Color(0xFFA78BFA))),
          ]),
          maxLines: 1,
          style: TextStyle(fontFamily: 'Bungee', fontSize: size, height: 1.3),
        ),
      );
}
