import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/app_controller.dart';
import 'router.dart';
import 'theme.dart';

/// Root widget: provides [AppController] and wires Material 3 themes + router.
class MicaGoApp extends StatefulWidget {
  final AppController controller;

  const MicaGoApp({super.key, required this.controller});

  @override
  State<MicaGoApp> createState() => _MicaGoAppState();
}

class _MicaGoAppState extends State<MicaGoApp> {
  late final GoRouter _router = createRouter(widget.controller);

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppController>.value(
      value: widget.controller,
      child: MaterialApp.router(
        title: 'MicaGo',
        debugShowCheckedModeBanner: false,
        theme: MicaGoTheme.light(),
        darkTheme: MicaGoTheme.dark(),
        themeMode: ThemeMode.system,
        routerConfig: _router,
      ),
    );
  }
}
