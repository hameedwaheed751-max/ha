import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';
import '../models.dart';

class AppStartup {
  static Future<void>? _initialization;

  static Future<void> initialize() {
    return _initialization ??= _initialize();
  }

  static Future<void> get ready => initialize();

  static Future<void> _initialize() async {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } catch (e) {
      debugPrint('Firebase initialization failed: $e');
    }

    try {
      await AppStore.load().timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('AppStore startup load failed: $e');
    }
  }
}