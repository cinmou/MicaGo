import 'package:flutter/material.dart';

import 'app/mica_go_app.dart';
import 'core/app_controller.dart';
import 'core/storage/secure_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final controller = AppController(store: SecureStore());
  await controller.bootstrap();

  runApp(MicaGoApp(controller: controller));
}
