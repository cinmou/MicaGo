import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/connection_profile.dart';

/// Persists the connection profile. The bearer token is stored with
/// [FlutterSecureStorage] (Android Keystore-backed EncryptedSharedPreferences),
/// not plain SharedPreferences, and is never logged.
class SecureStore {
  static const _profileKey = 'micago.connection_profile.v1';
  static const _contactsKey = 'micago.contacts_matching_enabled.v1';

  final FlutterSecureStorage _storage;

  // On Android, flutter_secure_storage (v10+) encrypts with custom ciphers by
  // default — no extra options needed. iOS/macOS use the Keychain.
  SecureStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  /// Loads the saved profile, or null if none / unreadable.
  Future<ConnectionProfile?> loadProfile() async {
    try {
      final raw = await _storage.read(key: _profileKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return ConnectionProfile.fromJson(decoded);
      }
      return null;
    } catch (_) {
      // Corrupt/unreadable storage should not crash the app.
      return null;
    }
  }

  Future<void> saveProfile(ConnectionProfile profile) async {
    await _storage.write(key: _profileKey, value: jsonEncode(profile.toJson()));
  }

  Future<void> clearProfile() async {
    await _storage.delete(key: _profileKey);
  }

  /// Whether the user has opted into local contacts matching (a simple flag —
  /// the contact book itself is never persisted).
  Future<bool> contactsMatchingEnabled() async {
    try {
      return (await _storage.read(key: _contactsKey)) == '1';
    } catch (_) {
      return false;
    }
  }

  Future<void> setContactsMatchingEnabled(bool enabled) async {
    await _storage.write(key: _contactsKey, value: enabled ? '1' : '0');
  }

  /// Generic small-value storage for non-secret preferences (theme, language).
  Future<String?> readValue(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeValue(String key, String value) async {
    await _storage.write(key: key, value: value);
  }
}
