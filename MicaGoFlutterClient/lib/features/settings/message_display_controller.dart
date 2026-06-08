import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/storage/secure_store.dart';
import '../chats/message_display.dart';

/// Holds + persists the user's [MessageDisplayPrefs]. Display-only; never
/// touches server data. Provided app-wide so the thread view reacts to changes.
class MessageDisplayController extends ChangeNotifier {
  final SecureStore store;
  static const _key = 'micago.message_display_prefs.v1';

  MessageDisplayController({required this.store});

  MessageDisplayPrefs prefs = MessageDisplayPrefs.defaults;

  Future<void> bootstrap() async {
    final raw = await store.readValue(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          prefs = MessageDisplayPrefs.fromMap(
              decoded.map((k, v) => MapEntry('$k', v?.toString())));
        }
      } catch (_) {
        // Corrupt value → keep defaults.
      }
    }
    notifyListeners();
  }

  Future<void> update(MessageDisplayPrefs next) async {
    prefs = next;
    notifyListeners();
    await store.writeValue(_key, jsonEncode(next.toMap()));
  }
}
