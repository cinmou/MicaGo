import 'package:flutter/foundation.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as fc;

import '../../core/storage/secure_store.dart';
import 'contact_identity.dart';

enum ContactsStatus { disabled, requesting, denied, ready }

/// Read-only local contacts matching. Requests `READ_CONTACTS` only when the
/// user explicitly enables it, builds an in-memory [ContactIndex], and never
/// writes, uploads, or persists the contact book (only an opt-in flag is
/// stored). Clearable via [disable].
class ContactsService extends ChangeNotifier {
  final SecureStore store;

  ContactsService({required this.store});

  ContactsStatus status = ContactsStatus.disabled;
  ContactIndex index = const ContactIndex.empty();
  List<ContactIdentity> contacts = const [];
  String? error;

  bool get isReady => status == ContactsStatus.ready;

  /// On launch: if the user previously enabled matching and permission is still
  /// granted, silently load. Never prompts here.
  Future<void> bootstrap() async {
    if (!await store.contactsMatchingEnabled()) {
      status = ContactsStatus.disabled;
      notifyListeners();
      return;
    }
    try {
      if (await fc.FlutterContacts.permissions.has(fc.PermissionType.read)) {
        await _load();
      } else {
        status = ContactsStatus.disabled;
      }
    } catch (_) {
      status = ContactsStatus.disabled;
    }
    notifyListeners();
  }

  /// Prompts for read-only contacts permission and loads on success.
  Future<void> enable() async {
    status = ContactsStatus.requesting;
    error = null;
    notifyListeners();

    fc.PermissionStatus result;
    try {
      result = await fc.FlutterContacts.permissions.request(fc.PermissionType.read);
    } catch (_) {
      status = ContactsStatus.denied;
      error = 'Could not request contacts permission.';
      notifyListeners();
      return;
    }

    final granted = result == fc.PermissionStatus.granted ||
        result == fc.PermissionStatus.limited;
    if (!granted) {
      status = ContactsStatus.denied;
      await store.setContactsMatchingEnabled(false);
      notifyListeners();
      return;
    }

    await store.setContactsMatchingEnabled(true);
    await _load();
    notifyListeners();
  }

  /// Turns matching off and clears the in-memory cache.
  Future<void> disable() async {
    await store.setContactsMatchingEnabled(false);
    contacts = const [];
    index = const ContactIndex.empty();
    status = ContactsStatus.disabled;
    notifyListeners();
  }

  Future<void> openSettings() => fc.FlutterContacts.permissions.openSettings();

  /// Local display name for a handle/identifier, or null when unmatched.
  String? displayNameFor(String? handle) => index.displayNameFor(handle);

  Future<void> _load() async {
    try {
      final raw = await fc.FlutterContacts.getAll(
        properties: const {
          fc.ContactProperty.name,
          fc.ContactProperty.phone,
          fc.ContactProperty.email,
        },
      );
      final identities = raw
          .map((c) => ContactIdentity(
                id: c.id ?? '',
                displayName: c.displayName ?? '',
                phones: c.phones.map((p) => p.number).toList(growable: false),
                emails: c.emails.map((e) => e.address).toList(growable: false),
              ))
          .where((c) => c.displayName.trim().isNotEmpty)
          .toList(growable: false);
      contacts = identities;
      index = ContactIndex.fromContacts(identities);
      status = ContactsStatus.ready;
      error = null;
    } catch (_) {
      status = ContactsStatus.denied;
      error = 'Could not read contacts.';
    }
  }
}
