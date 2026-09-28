import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Registers this device's FCM token in public.device_tokens whenever a user
/// is signed in, so the `notify` edge function can push alerts to it.
///
/// No-op until Firebase is configured for the app: without
/// android/app/google-services.json (+ the com.google.gms.google-services
/// Gradle plugin) or ios/Runner/GoogleService-Info.plist, `Firebase.initializeApp`
/// throws and we just log it. Setup steps: see supabase/functions/notify/README.md.
Future<void> startPushRegistration(SupabaseClient client) async {
  if (kIsWeb) return; // Web push needs a service worker + VAPID key; not wired yet.
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('push: Firebase not configured, skipping registration ($e)');
    return;
  }
  final fcm = FirebaseMessaging.instance;
  final platform = defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  Future<void> register([String? token]) async {
    if (client.auth.currentUser == null) return;
    try {
      token ??= await fcm.getToken();
      if (token == null) return;
      await client.rpc('register_device_token', params: {'p_token': token, 'p_platform': platform});
    } catch (e) {
      debugPrint('push: token registration failed ($e)');
    }
  }

  // Android 13+ / iOS ask the user; a denial just means no pushes.
  unawaited(fcm.requestPermission());
  fcm.onTokenRefresh.listen(register);
  client.auth.onAuthStateChange.listen((s) {
    if (s.event == AuthChangeEvent.signedIn || s.event == AuthChangeEvent.initialSession) {
      register();
    }
  });
}
