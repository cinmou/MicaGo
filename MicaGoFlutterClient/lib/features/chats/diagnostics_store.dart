import 'package:flutter/foundation.dart';

import 'message_render.dart';

/// Holds the most recently computed thread diagnostics so the Settings →
/// "Message Compatibility Diagnostics" page can show them. Updated by the open
/// thread whenever its message list changes. Debug-only; no message content
/// beyond the redacted last-unsupported preview.
final ValueNotifier<ThreadDiagnostics> lastThreadDiagnostics =
    ValueNotifier<ThreadDiagnostics>(ThreadDiagnostics.empty);
