import 'package:flutter/material.dart';
import 'models.dart';
import 'screens/login_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
  options: DefaultFirebaseOptions.currentPlatform,
);

  // لا نسمح للتخزين المحلي أن يعلّق شاشة Flutter Web قبل أول رسم.
  try {
    await AppStore.load().timeout(const Duration(seconds: 5));
  } catch (_) {
    // يفتح التطبيق حتى لو تعذر التخزين، ويمكن إعادة المحاولة لاحقاً.
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'wakel-iq',
    theme: ThemeData(
      useMaterial3: true,
      colorSchemeSeed: const Color(0xFF2E7D32),
      scaffoldBackgroundColor: const Color(0xfff5f7fb),
      cardTheme: const CardThemeData(elevation: 1),
    ),
    home: const LoginScreen(),
  );
}