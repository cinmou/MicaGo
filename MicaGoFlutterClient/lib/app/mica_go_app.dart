import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/app_controller.dart';
import '../core/theme_controller.dart';
import '../features/contacts/contacts_service.dart';
import 'router.dart';
import 'theme.dart';

/// Root widget: provides controllers and wires Material 3 themes (with Android
/// 12+ dynamic color) + locale + router.
class MicaGoApp extends StatefulWidget {
  final AppController controller;
  final ContactsService contacts;
  final ThemeController theme;

  const MicaGoApp({
    super.key,
    required this.controller,
    required this.contacts,
    required this.theme,
  });

  @override
  State<MicaGoApp> createState() => _MicaGoAppState();
}

class _MicaGoAppState extends State<MicaGoApp> {
  late final GoRouter _router = createRouter(widget.controller);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppController>.value(value: widget.controller),
        ChangeNotifierProvider<ContactsService>.value(value: widget.contacts),
        ChangeNotifierProvider<ThemeController>.value(value: widget.theme),
      ],
      child: Consumer<ThemeController>(
        builder: (context, theme, _) {
          return DynamicColorBuilder(
            builder: (lightDynamic, darkDynamic) {
              final useDynamic =
                  theme.useSystemColors && lightDynamic != null;
              final lightScheme = useDynamic
                  ? lightDynamic.harmonized()
                  : ColorScheme.fromSeed(seedColor: theme.seedColor);
              final darkScheme = (useDynamic && darkDynamic != null)
                  ? darkDynamic.harmonized()
                  : ColorScheme.fromSeed(
                      seedColor: theme.seedColor,
                      brightness: Brightness.dark);

              return MaterialApp.router(
                title: 'MicaGo',
                debugShowCheckedModeBanner: false,
                theme: MicaGoTheme.fromScheme(lightScheme),
                darkTheme: MicaGoTheme.fromScheme(darkScheme),
                themeMode: theme.themeMode,
                // Locale architecture is wired; app strings are not yet
                // translated (only built-in Material widgets localize).
                locale: theme.locale,
                supportedLocales: const [Locale('en'), Locale('zh')],
                localizationsDelegates: const [
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                routerConfig: _router,
              );
            },
          );
        },
      ),
    );
  }
}
