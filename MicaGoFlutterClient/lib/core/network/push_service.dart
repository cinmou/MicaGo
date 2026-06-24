import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../app_controller.dart';
import 'push_logic.dart';

/// Storage key for the user-owned Firebase client options. C28: MicaGo bakes no
/// google-services.json, so the FCM **background isolate** (a fresh process when
/// the app was killed) has no default Firebase app to attach to. We persist the
/// runtime options here when the foreground initializes Firebase, and the
/// background handler reads them to `Firebase.initializeApp(options:)` — without
/// this, the killed-app background handler can't init Firebase and shows nothing.
const String fcmOptionsStorageKey = 'micago.fcm_options.v1';

/// Pure: the minimal Firebase options map persisted for the background isolate.
Map<String, String> fcmOptionsStorageMap(Map<String, dynamic> cfg) => {
  'apiKey': (cfg['apiKey'] ?? '') as String,
  'appId': (cfg['appId'] ?? '') as String,
  'messagingSenderId': (cfg['messagingSenderId'] ?? '') as String,
  'projectId': (cfg['projectId'] ?? '') as String,
  'storageBucket': (cfg['storageBucket'] ?? '') as String,
};

/// Pure: build [FirebaseOptions] from a persisted/config map. An empty
/// storageBucket maps to null (the field is optional).
FirebaseOptions firebaseOptionsFromMap(Map<String, dynamic> m) {
  final bucket = (m['storageBucket'] as String?)?.trim() ?? '';
  return FirebaseOptions(
    apiKey: (m['apiKey'] ?? '') as String,
    appId: (m['appId'] ?? '') as String,
    messagingSenderId: (m['messagingSenderId'] ?? '') as String,
    projectId: (m['projectId'] ?? '') as String,
    storageBucket: bucket.isEmpty ? null : bucket,
  );
}

/// C22 — BlueBubbles-style FCM wake layered on top of WebSocket + delta sync.
///
/// Faithful to BlueBubbles' model (`cloud_messaging_service.dart`,
/// `method_channel_service.dart` `new-message` handler, `fcmService/index.ts`):
/// the push is a thin **wake/awareness** signal — the real message data always
/// arrives over the socket (foreground) or the delta cursor (catch-up), never
/// from the push body. Firebase is **optional**: when the server has no
/// user-owned config the whole service no-ops and the app stays on WS + delta.
///
/// Dedup rule (BlueBubbles): if the app is alive and the socket is connected,
/// the socket already handled the event, so the FCM message is ignored.
class PushService {
  PushService(this.app);

  final AppController app;

  bool available = false;
  String? token;

  static const _channelId = 'micago_messages';
  static const _channelName = 'Messages';
  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  /// Idempotent start. Safe to call on every (re)connect; only does real work
  /// once Firebase is configured + initialized.
  Future<void> start() async {
    if (available) {
      // Already running: just make sure the latest token is registered.
      await _registerToken();
      return;
    }
    final api = app.api;
    if (api == null) return;

    // 1) Pull the user-owned Firebase client config from the server.
    final cfg = await api.fetchFcmClientConfig();
    if (cfg == null || cfg['configured'] != true) {
      // Firebase not set up → stay on WebSocket + delta sync (graceful).
      return;
    }

    // 2) Initialize Firebase at runtime from that config (no google-services
    //    baked into the APK — BlueBubbles' user-owned-project model). Persist the
    //    options FIRST so the background isolate (a fresh process after a kill)
    //    can re-init Firebase the same way — otherwise killed-app pushes can't
    //    show a notification.
    await _persistOptions(cfg);
    try {
      await Firebase.initializeApp(options: firebaseOptionsFromMap(cfg));
    } catch (e) {
      // Already-initialized is fine; any other failure → degrade to WS/delta.
      if (e is! FirebaseException || e.code != 'duplicate-app') {
        debugPrint('PushService: Firebase init failed ($e); using WS + delta');
        return;
      }
    }

    await _initLocalNotifications();

    // 3) Permission + token.
    final messaging = FirebaseMessaging.instance;
    try {
      await messaging.requestPermission();
      token = await messaging.getToken();
    } catch (e) {
      debugPrint('PushService: token fetch failed ($e); using WS + delta');
      return;
    }
    if (token == null || token!.isEmpty) return;

    available = true;

    // 4) Register the token + react to refreshes.
    await _registerToken();
    messaging.onTokenRefresh.listen((t) {
      token = t;
      unawaited(_registerToken());
    });

    // 5) Handlers (foreground / tap / terminated-launch) + the background isolate
    //    handler. The background registration persists natively, so a later
    //    killed-app delivery still spawns the isolate and runs our handler.
    FirebaseMessaging.onBackgroundMessage(micaGoFirebaseBackgroundHandler);
    FirebaseMessaging.onMessage.listen(_onForegroundMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(_onNotificationTap);
    final initial = await messaging.getInitialMessage();
    if (initial != null) _onNotificationTap(initial);
  }

  Future<void> _persistOptions(Map<String, dynamic> cfg) async {
    try {
      await app.store.writeValue(
        fcmOptionsStorageKey,
        jsonEncode(fcmOptionsStorageMap(cfg)),
      );
    } catch (_) {
      // Best-effort; the foreground init still proceeds. The background isolate
      // will fall back to a default-app init.
    }
  }

  Future<void> _registerToken() async {
    await app.updatePushRegistration(
      provider: 'fcm',
      token: token,
      enabled: token != null && token!.isNotEmpty,
    );
  }

  // Foreground: the socket is usually live and already delivered the row, so we
  // follow BlueBubbles and DON'T raise a system notification (no spam). If the
  // socket happens to be down, run a delta catch-up so the open thread/list
  // still update — GUID dedup prevents duplicate bubbles.
  void _onForegroundMessage(RemoteMessage message) {
    if (!pushShouldCatchUp(realtimeConnected: app.isRealtimeConnected)) {
      return; // socket already handled it (BlueBubbles dedup)
    }
    unawaited(app.runDeltaSync(reason: 'fcm-foreground'));
  }

  // Tap (from background or terminated): delta-sync FIRST so we don't show stale
  // content, then ask the shell to open the conversation.
  void _onNotificationTap(RemoteMessage message) {
    unawaited(app.runDeltaSync(reason: 'fcm-tap'));
    final chatGuid = pushChatGuid(message.data);
    if (chatGuid != null) app.requestOpenChat(chatGuid);
  }

  Future<void> _initLocalNotifications() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _local.initialize(
      const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: (resp) {
        final guid = resp.payload;
        if (guid != null && guid.isNotEmpty) app.requestOpenChat(guid);
      },
    );
    await _local
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            importance: Importance.high,
          ),
        );
  }
}

/// Top-level background handler (runs in its own isolate when the app is
/// backgrounded/killed). It only shows a local notification from the lightweight
/// push data — the actual message fetch happens via delta sync when the app next
/// opens/resumes (the existing `onResume` → `catchUp` path), exactly the
/// BlueBubbles "push wakes, sync fetches" model. Kept dependency-free of the
/// running app so it works without a live AppController.
@pragma('vm:entry-point')
Future<void> micaGoFirebaseBackgroundHandler(RemoteMessage message) async {
  if (!await ensureBackgroundFirebase()) {
    // Firebase couldn't init here; skip the local notification. The missed
    // message is still delivered by delta catch-up on the next resume.
    return;
  }
  await showPushNotification(message);
}

/// Initializes Firebase inside the FCM background isolate. MicaGo bakes no
/// google-services.json, so a killed-app push runs in a fresh process with NO
/// default Firebase app — `Firebase.initializeApp()` (no options) would throw.
/// We prefer the persisted runtime options (written by the foreground), then
/// fall back to any existing/default app. Returns false when Firebase can't be
/// initialized at all.
@pragma('vm:entry-point')
Future<bool> ensureBackgroundFirebase() async {
  if (Firebase.apps.isNotEmpty) return true;
  try {
    final raw = await const FlutterSecureStorage().read(key: fcmOptionsStorageKey);
    if (raw != null && raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        await Firebase.initializeApp(options: firebaseOptionsFromMap(decoded));
        return true;
      }
    }
  } catch (_) {
    // Fall through to a best-effort default init.
  }
  try {
    await Firebase.initializeApp();
    return true;
  } catch (_) {
    return false;
  }
}

/// Shared local-notification display used by the background handler. Deduped by
/// the message GUID as the notification id so the same event can't stack.
Future<void> showPushNotification(RemoteMessage message) async {
  final data = message.data;
  // Single source of truth for "is there anything to show" (test pushes and
  // preview-disabled empty pushes are skipped) — shared with the pure logic test.
  if (!pushShouldNotify(data)) return;
  final title = (data['title'] as String?)?.trim();
  final body = (data['body'] as String?)?.trim();

  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  final chatGuid = data['chatGuid'] as String?;
  final notifId = (data['messageGuid'] as String?)?.hashCode ?? 0;
  await plugin.show(
    notifId,
    title?.isNotEmpty == true ? title : 'New message',
    body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'micago_messages',
        'Messages',
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
    payload: chatGuid,
  );
}
