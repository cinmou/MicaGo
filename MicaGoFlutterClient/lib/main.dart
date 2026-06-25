import 'package:flutter/material.dart';

import 'app/mica_go_app.dart';
import 'core/app_controller.dart';
import 'core/storage/secure_store.dart';
import 'core/theme_controller.dart';
import 'features/contacts/contacts_service.dart';
import 'features/settings/message_display_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final store = SecureStore();
  final controller = AppController(store: store);
  final contacts = ContactsService(store: store);
  final theme = ThemeController(store: store);
  final messageDisplay = MessageDisplayController(store: store);

  await controller.bootstrap();
  await contacts.bootstrap();
  await theme.bootstrap();
  await messageDisplay.bootstrap();

  // C31: let the controller title local notifications with on-device contact
  // names (resolves live against the contacts index; null when matching is off).
  controller.contactNameResolver = contacts.displayNameFor;

  runApp(
    MicaGoApp(
      controller: controller,
      contacts: contacts,
      theme: theme,
      messageDisplay: messageDisplay,
    ),
  );
}
