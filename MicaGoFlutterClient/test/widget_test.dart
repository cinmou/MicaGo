// C0 smoke test: the connection setup screen renders its core fields.
//
// Uses a fake AppController-free path by pumping ConnectionScreen inside a
// Provider with a controller backed by an in-memory store, so no platform
// channels (secure storage) are exercised.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:mica_go/core/app_controller.dart';
import 'package:mica_go/core/models/connection_profile.dart';
import 'package:mica_go/core/storage/secure_store.dart';
import 'package:mica_go/features/connection/connection_screen.dart';

/// In-memory SecureStore stand-in so tests never touch platform channels.
class _MemoryStore implements SecureStore {
  ConnectionProfile? _saved;

  @override
  Future<ConnectionProfile?> loadProfile() async => _saved;

  @override
  Future<void> saveProfile(ConnectionProfile profile) async {
    _saved = profile;
  }

  @override
  Future<void> clearProfile() async {
    _saved = null;
  }

  bool _contactsEnabled = false;

  @override
  Future<bool> contactsMatchingEnabled() async => _contactsEnabled;

  @override
  Future<void> setContactsMatchingEnabled(bool enabled) async {
    _contactsEnabled = enabled;
  }

  final Map<String, String> _values = {};

  @override
  Future<String?> readValue(String key) async => _values[key];

  @override
  Future<void> writeValue(String key, String value) async {
    _values[key] = value;
  }
}

void main() {
  testWidgets('connection screen shows server, token, and ws fields',
      (tester) async {
    final controller = AppController(store: _MemoryStore());

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: ConnectionScreen()),
      ),
    );

    expect(find.text('Server URL'), findsOneWidget);
    expect(find.text('Bearer token'), findsOneWidget);
    expect(find.text('WebSocket URL (optional)'), findsOneWidget);
    expect(find.text('Test connection'), findsOneWidget);
    expect(find.text('Save & continue'), findsOneWidget);
  });
}
