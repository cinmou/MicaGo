import 'package:go_router/go_router.dart';

import '../core/app_controller.dart';
import '../features/connection/connection_screen.dart';
import '../features/home/home_screen.dart';

/// Route names/paths for the app.
class Routes {
  Routes._();
  static const connection = '/connection';
  static const home = '/home';
}

/// Builds the app router. Guards send the user to the connection screen until a
/// complete profile exists; the connection screen stays reachable for editing.
GoRouter createRouter(AppController app) {
  return GoRouter(
    initialLocation: app.hasProfile ? Routes.home : Routes.connection,
    refreshListenable: app,
    redirect: (context, state) {
      // Wait until persisted state is loaded to avoid a flash of the wrong page.
      if (!app.bootstrapped) return null;
      final atConnection = state.matchedLocation == Routes.connection;
      if (!app.hasProfile && !atConnection) {
        return Routes.connection;
      }
      return null;
    },
    routes: [
      GoRoute(
        path: Routes.connection,
        builder: (context, state) => const ConnectionScreen(),
      ),
      GoRoute(
        path: Routes.home,
        builder: (context, state) => const HomeScreen(),
      ),
    ],
  );
}
