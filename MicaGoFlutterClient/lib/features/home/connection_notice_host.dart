import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_controller.dart';
import '../../core/network/connection_notice.dart';
import '../../core/ui/top_banner.dart';

/// Surfaces [AppController.connectionNotice] as the user-visible connection
/// feedback (C19): a sticky banner while offline / on the public fallback, and
/// a transient snackbar for recoveries. De-dup happens in the controller's
/// pure derivation, so this never spams.
class ConnectionNoticeHost extends StatefulWidget {
  final Widget child;
  const ConnectionNoticeHost({super.key, required this.child});

  @override
  State<ConnectionNoticeHost> createState() => _ConnectionNoticeHostState();
}

class _ConnectionNoticeHostState extends State<ConnectionNoticeHost> {
  AppController? _app;
  ConnectionNotice? _sticky;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.read<AppController>();
    if (identical(app, _app)) return;
    _app?.connectionNotice.removeListener(_onNotice);
    _app?.connectionHealthy.removeListener(_onHealthy);
    _app = app;
    app.connectionNotice.addListener(_onNotice);
    app.connectionHealthy.addListener(_onHealthy);
  }

  @override
  void dispose() {
    _app?.connectionNotice.removeListener(_onNotice);
    _app?.connectionHealthy.removeListener(_onHealthy);
    super.dispose();
  }

  /// C26: a healthy (connected) connection must never leave a stale problem
  /// banner up. Clearing here covers the connecting→connected edge that the
  /// one-shot notice derivation intentionally reports as null.
  void _onHealthy() {
    if (_app?.connectionHealthy.value == true && _sticky != null) {
      setState(() => _sticky = null);
    }
  }

  void _onNotice() {
    final notice = _app?.connectionNotice.value;
    if (notice == null) return;

    if (notice.isTransient) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // C21u: surface recoveries/fallback switches as a top banner, not a
        // bottom snackbar.
        TopBanner.show(
          context,
          notice.message,
          kind: notice.isProblem
              ? TopBannerKind.error
              : TopBannerKind.info,
          duration: const Duration(seconds: 2),
        );
      });
    }
    // Never raise a sticky problem banner while the connection is actually
    // healthy — a late/stale problem notice must not override a live connection.
    final healthy = _app?.connectionHealthy.value == true;
    setState(() => _sticky = (notice.isProblem && !healthy) ? notice : null);
    // Consume the one-shot so the same transition isn't re-handled.
    _app?.connectionNotice.value = null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sticky = _sticky;
    return Column(
      children: [
        if (sticky != null)
          Material(
            color: scheme.errorContainer,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    Icon(Icons.cloud_off, size: 16, color: scheme.onErrorContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        sticky.message,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: scheme.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(child: widget.child),
      ],
    );
  }
}
