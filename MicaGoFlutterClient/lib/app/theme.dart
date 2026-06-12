import 'package:flutter/material.dart';

/// MicaGo branding + Material 3 light/dark themes.
class MicaGoTheme {
  MicaGoTheme._();

  /// Brand seed color (Mica indigo).
  static const Color seed = Color(0xFF5B6CFF);

  static ThemeData light() => fromSeed(seed, Brightness.light);
  static ThemeData dark() => fromSeed(seed, Brightness.dark);

  /// Builds a theme from a seed color (used when dynamic color is off).
  static ThemeData fromSeed(Color seedColor, Brightness brightness) =>
      fromScheme(
        ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness),
      );

  /// Builds a theme from a ready-made [ColorScheme] (used for Android 12+
  /// dynamic / Material You colors).
  static ThemeData fromScheme(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      appBarTheme: const AppBarTheme(centerTitle: false),
      cardTheme: CardThemeData(
        clipBehavior: Clip.antiAlias,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      ),
    );
  }
}
