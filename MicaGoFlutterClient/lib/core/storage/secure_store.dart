import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/connection_profile.dart';

/// Persists the connection profile. The bearer token is stored with
/// [FlutterSecureStorage] (Android Keystore-backed EncryptedSharedPreferences),
/// not plain SharedPreferences, and is never logged.
class SecureStore {
  static const _profileKey = 'micago.connection_profile.v1';
  static const _contactsKey = 'micago.contacts_matching_enabled.v1';
  static const _fallbackMarkerKey = 'micago.secure_store_fallback.v1';
  static const _fallbackPrefix = 'micago.secure_fallback.';
  static const _secureTimeout = Duration(milliseconds: 900);

  final FlutterSecureStorage _storage;
  final SharedPreferencesAsync _fallback;

  // On Android, flutter_secure_storage (v10+) encrypts with custom ciphers by
  // default — no extra options needed. iOS/macOS use the Keychain.
  SecureStore({FlutterSecureStorage? storage, SharedPreferencesAsync? fallback})
    : _storage = storage ?? const FlutterSecureStorage(),
      _fallback = fallback ?? SharedPreferencesAsync();

  /// Loads the saved profile, or null if none / unreadable.
  Future<ConnectionProfile?> loadProfile() async {
    try {
      final raw = await _read(_profileKey);
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
    await _write(_profileKey, jsonEncode(profile.toJson()));
  }

  Future<void> clearProfile() async {
    await _delete(_profileKey);
  }

  /// Whether the user has opted into local contacts matching (a simple flag —
  /// the contact book itself is never persisted).
  Future<bool> contactsMatchingEnabled() async {
    try {
      return (await _read(_contactsKey)) == '1';
    } catch (_) {
      return false;
    }
  }

  Future<void> setContactsMatchingEnabled(bool enabled) async {
    await _write(_contactsKey, enabled ? '1' : '0');
  }

  /// Generic small-value storage for non-secret preferences (theme, language).
  Future<String?> readValue(String key) async {
    try {
      return await _read(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeValue(String key, String value) async {
    await _write(key, value);
  }

  Future<void> deleteValue(String key) async {
    await _delete(key);
  }

  Future<String?> _read(String key) async {
    if (await _fallbackEnabled()) {
      return _readFallback(key);
    }
    try {
      final secureValue = await _storage.read(key: key).timeout(_secureTimeout);
      if (secureValue != null) return secureValue;
      return _readFallback(key);
    } catch (error) {
      await _enableFallback(error);
      return _readFallback(key);
    }
  }

  Future<void> _write(String key, String value) async {
    if (await _fallbackEnabled()) {
      await _writeFallback(key, value);
      return;
    }
    try {
      await _storage.write(key: key, value: value).timeout(_secureTimeout);
      // Keep a plain fallback mirror. If a ROM later breaks Android Keystore,
      // pairing and appearance settings still survive the automatic downgrade.
      await _writeFallback(key, value);
    } catch (error) {
      await _enableFallback(error);
      await _writeFallback(key, value);
    }
  }

  Future<void> _delete(String key) async {
    await _deleteFallback(key);
    if (await _fallbackEnabled()) return;
    try {
      await _storage.delete(key: key).timeout(_secureTimeout);
    } catch (error) {
      await _enableFallback(error);
    }
  }

  Future<bool> _fallbackEnabled() async =>
      (await _fallback.getBool(_fallbackMarkerKey)) ?? false;

  Future<void> _enableFallback(Object error) async {
    debugPrint('[SecureStore] Falling back to SharedPreferences: $error');
    await _fallback.setBool(_fallbackMarkerKey, true);
  }

  Future<String?> _readFallback(String key) =>
      _fallback.getString(_fallbackPrefix + key);

  Future<void> _writeFallback(String key, String value) =>
      _fallback.setString(_fallbackPrefix + key, value);

  Future<void> _deleteFallback(String key) =>
      _fallback.remove(_fallbackPrefix + key);
}
