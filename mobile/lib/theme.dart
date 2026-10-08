import 'package:flutter/material.dart';
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
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: GnColors.card,
      indicatorColor: GnColors.button,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
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
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
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
