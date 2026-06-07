import 'package:flutter/material.dart';

import '../app/theme.dart';
import 'storage/secure_store.dart';

/// Theme color choice. `system` = use Android 12+ dynamic (Material You) colors
/// when available; the rest are fixed seed colors.
enum ThemeColorChoice { system, micago, blue, green, purple, orange }

/// Language choice. The UI is wired for locale switching, but app-specific
/// strings are **not yet translated** (see docs/imessage-feature-map.md) — only
/// Flutter's built-in Material widgets localize today.
enum LanguageChoice { system, english, chinese }

/// App appearance + language preferences, persisted locally.
class ThemeController extends ChangeNotifier {
  final SecureStore store;

  ThemeController({required this.store});

  ThemeMode themeMode = ThemeMode.system;
  ThemeColorChoice colorChoice = ThemeColorChoice.system; // system colors ON
  LanguageChoice language = LanguageChoice.system;

  bool get useSystemColors => colorChoice == ThemeColorChoice.system;

  /// Seed color used when dynamic color is off/unavailable.
  Color get seedColor {
    switch (colorChoice) {
      case ThemeColorChoice.system:
      case ThemeColorChoice.micago:
        return MicaGoTheme.seed;
      case ThemeColorChoice.blue:
        return const Color(0xFF1565C0);
      case ThemeColorChoice.green:
        return const Color(0xFF2E7D32);
      case ThemeColorChoice.purple:
        return const Color(0xFF6A1B9A);
      case ThemeColorChoice.orange:
        return const Color(0xFFE65100);
    }
  }

  /// Locale override, or null to follow the system.
  Locale? get locale {
    switch (language) {
      case LanguageChoice.system:
        return null;
      case LanguageChoice.english:
        return const Locale('en');
      case LanguageChoice.chinese:
        return const Locale('zh');
    }
  }

  static const _kMode = 'micago.theme.mode';
  static const _kColor = 'micago.theme.color';
  static const _kLang = 'micago.theme.lang';

  Future<void> bootstrap() async {
    themeMode = _parseMode(await store.readValue(_kMode));
    colorChoice = _parseColor(await store.readValue(_kColor));
    language = _parseLang(await store.readValue(_kLang));
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    await store.writeValue(_kMode, mode.name);
  }

  Future<void> setColorChoice(ThemeColorChoice choice) async {
    colorChoice = choice;
    notifyListeners();
    await store.writeValue(_kColor, choice.name);
  }

  Future<void> setLanguage(LanguageChoice lang) async {
    language = lang;
    notifyListeners();
    await store.writeValue(_kLang, lang.name);
  }

  ThemeMode _parseMode(String? v) =>
      ThemeMode.values.firstWhere((m) => m.name == v,
          orElse: () => ThemeMode.system);
  ThemeColorChoice _parseColor(String? v) =>
      ThemeColorChoice.values.firstWhere((c) => c.name == v,
          orElse: () => ThemeColorChoice.system);
  LanguageChoice _parseLang(String? v) =>
      LanguageChoice.values.firstWhere((l) => l.name == v,
          orElse: () => LanguageChoice.system);
}
