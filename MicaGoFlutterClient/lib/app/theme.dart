import 'package:flutter/material.dart';

/// MicaGo branding + Material 3 light/dark themes.
class MicaGoTheme {
  MicaGoTheme._();

  /// Brand seed color. Also the fallback when system dynamic color is unavailable.
  static const Color seed = Color(0xFF007AFF);

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
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      ),
    );
  }

  static ColorScheme blackWhiteScheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return (dark ? const ColorScheme.dark() : const ColorScheme.light())
        .copyWith(
          primary: dark ? const Color(0xFFEDEDED) : const Color(0xFF111111),
          onPrimary: dark ? const Color(0xFF111111) : const Color(0xFFFFFFFF),
          primaryContainer: dark
              ? const Color(0xFF333333)
              : const Color(0xFFEDEDED),
          onPrimaryContainer: dark
              ? const Color(0xFFF2F2F2)
              : const Color(0xFF111111),
          secondary: dark ? const Color(0xFFC7C7C7) : const Color(0xFF444444),
          onSecondary: dark ? const Color(0xFF111111) : const Color(0xFFFFFFFF),
          secondaryContainer: dark
              ? const Color(0xFF2A2A2A)
              : const Color(0xFFF4F4F4),
          onSecondaryContainer: dark
              ? const Color(0xFFF2F2F2)
              : const Color(0xFF111111),
          tertiary: dark ? const Color(0xFFDADADA) : const Color(0xFF5A5A5A),
          onTertiary: dark ? const Color(0xFF111111) : const Color(0xFFFFFFFF),
          tertiaryContainer: dark
              ? const Color(0xFF262626)
              : const Color(0xFFE0E0E0),
          onTertiaryContainer: dark
              ? const Color(0xFFF2F2F2)
              : const Color(0xFF111111),
          error: dark ? const Color(0xFFFFB4AB) : const Color(0xFFB3261E),
          onError: dark ? const Color(0xFF690005) : const Color(0xFFFFFFFF),
          surface: dark ? const Color(0xFF101010) : const Color(0xFFFFFFFF),
          onSurface: dark ? const Color(0xFFF2F2F2) : const Color(0xFF111111),
          surfaceContainerLowest: dark
              ? const Color(0xFF0B0B0B)
              : const Color(0xFFFFFFFF),
          surfaceContainerLow: dark
              ? const Color(0xFF161616)
              : const Color(0xFFF7F7F7),
          surfaceContainer: dark
              ? const Color(0xFF1A1A1A)
              : const Color(0xFFF4F4F4),
          surfaceContainerHigh: dark
              ? const Color(0xFF202020)
              : const Color(0xFFEDEDED),
          surfaceContainerHighest: dark
              ? const Color(0xFF252525)
              : const Color(0xFFE8E8E8),
          onSurfaceVariant: dark
              ? const Color(0xFFC7C7C7)
              : const Color(0xFF444444),
          outline: dark ? const Color(0xFF6A6A6A) : const Color(0xFFBDBDBD),
          outlineVariant: dark
              ? const Color(0xFF333333)
              : const Color(0xFFE0E0E0),
          inverseSurface: dark
              ? const Color(0xFFF2F2F2)
              : const Color(0xFF202020),
          onInverseSurface: dark
              ? const Color(0xFF111111)
              : const Color(0xFFFFFFFF),
          inversePrimary: dark
              ? const Color(0xFF111111)
              : const Color(0xFFEDEDED),
          shadow: const Color(0xFF000000),
          scrim: const Color(0xFF000000),
          surfaceTint: Colors.transparent,
        );
  }
}
