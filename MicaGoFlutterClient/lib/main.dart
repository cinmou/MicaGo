import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app/mica_go_app.dart';
import 'core/app_controller.dart';
import 'core/storage/secure_store.dart';
import 'core/theme_controller.dart';
import 'features/contacts/contacts_service.dart';
import 'features/settings/message_display_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LiquidGlassWidgets.initialize();

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
  // C32: and show the contact's avatar in the notification when available.
  controller.contactAvatarResolver = contacts.thumbnailForHandle;

  runApp(
    MicaGoApp(
      controller: controller,
      contacts: contacts,
      theme: theme,
      messageDisplay: messageDisplay,
    ),
  );
}
