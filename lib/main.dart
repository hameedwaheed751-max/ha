import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'models.dart';
import 'screens/login_screen.dart';
import 'services/app_startup.dart';

class _ImmediatePageTransitionsBuilder extends PageTransitionsBuilder {
  const _ImmediatePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

const _immediatePageTransitions = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: _ImmediatePageTransitionsBuilder(),
    TargetPlatform.iOS: _ImmediatePageTransitionsBuilder(),
    TargetPlatform.windows: _ImmediatePageTransitionsBuilder(),
    TargetPlatform.macOS: _ImmediatePageTransitionsBuilder(),
    TargetPlatform.linux: _ImmediatePageTransitionsBuilder(),
  },
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(AppStartup.initialize());

  if (kDebugMode) {
    debugPrintSynchronously(
      '[SAS DEBUG][TERMINAL PROBE] logger_output_visible=true '
      'network_request=false activation_request=false',
    );
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppStore.themeModeChange,
      builder: (context, isDark, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'وكيل نت',
          themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
          theme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: const Color(0xFF2E7D32),
            pageTransitionsTheme: _immediatePageTransitions,
            scaffoldBackgroundColor: const Color(0xfff5f7fb),
            cardTheme: const CardThemeData(
              elevation: 1,
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(16)),
              ),
            ),
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFF2E7D32),
              foregroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              centerTitle: true,
            ),
            elevatedButtonTheme: ElevatedButtonThemeData(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            outlinedButtonTheme: OutlinedButtonThemeData(
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF2E7D32),
                side: const BorderSide(color: Color(0xFF2E7D32), width: 1.3),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF2E7D32),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
            ),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: const Color(0xFFF8FAFC),
              labelStyle: const TextStyle(color: Color(0xFF1E293B)),
              hintStyle: const TextStyle(color: Color(0xFF64748B)),
              prefixIconColor: const Color(0xFF2E7D32),
              suffixIconColor: const Color(0xFF2E7D32),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.green.shade200, width: 1.2),
              ),
              focusedBorder: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(12)),
                borderSide: BorderSide(color: Color(0xFF2E7D32), width: 1.8),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.red, width: 1.2),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.red, width: 1.8),
              ),
            ),
            dropdownMenuTheme: DropdownMenuThemeData(
              menuStyle: MenuStyle(
                backgroundColor: WidgetStatePropertyAll(
                  const Color(0xFFFFFFFF),
                ),
                surfaceTintColor: WidgetStatePropertyAll(
                  Colors.transparent,
                ),
              ),
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: const Color(0xFF2E7D32),
            pageTransitionsTheme: _immediatePageTransitions,
            brightness: Brightness.dark,
            scaffoldBackgroundColor: const Color(0xFF0F172A),
            canvasColor: const Color(0xFF0F172A),
            dividerColor: const Color(0xFF334155),
            cardTheme: const CardThemeData(
              elevation: 1,
              color: Color(0xFF1E293B),
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(16)),
              ),
            ),
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFF2E7D32),
              foregroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              centerTitle: true,
            ),
            elevatedButtonTheme: ElevatedButtonThemeData(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            outlinedButtonTheme: OutlinedButtonThemeData(
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF86EFAC),
                side: const BorderSide(color: Color(0xFF66BB6A), width: 1.3),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF86EFAC),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
            ),
            dialogTheme: const DialogThemeData(
              backgroundColor: Color(0xFF1E293B),
              surfaceTintColor: Colors.transparent,
            ),
            bottomSheetTheme: const BottomSheetThemeData(
              backgroundColor: Color(0xFF1E293B),
              surfaceTintColor: Colors.transparent,
              modalBackgroundColor: Color(0xFF1E293B),
            ),
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: const Color(0xFF1E293B),
              labelStyle: const TextStyle(color: Color(0xFFCBD5E1)),
              hintStyle: const TextStyle(color: Color(0xFF94A3B8)),
              prefixIconColor: const Color(0xFF86EFAC),
              suffixIconColor: const Color(0xFF86EFAC),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF475569)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: Color(0xFF66BB6A),
                  width: 1.8,
                ),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.red, width: 1.2),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.red, width: 1.8),
              ),
            ),
            dropdownMenuTheme: DropdownMenuThemeData(
              menuStyle: MenuStyle(
                backgroundColor: WidgetStatePropertyAll(
                  const Color(0xFF1E293B),
                ),
                surfaceTintColor: WidgetStatePropertyAll(
                  Colors.transparent,
                ),
              ),
            ),
            listTileTheme: const ListTileThemeData(
              textColor: Color(0xFFE2E8F0),
              iconColor: Color(0xFFCBD5E1),
            ),
            popupMenuTheme: const PopupMenuThemeData(
              color: Color(0xFF1E293B),
              surfaceTintColor: Colors.transparent,
              textStyle: TextStyle(color: Color(0xFFE2E8F0)),
            ),
            navigationBarTheme: const NavigationBarThemeData(
              backgroundColor: Color(0xFF1E293B),
              indicatorColor: Color(0xFF2E7D32),
              labelTextStyle: WidgetStatePropertyAll(
                TextStyle(color: Color(0xFFE2E8F0)),
              ),
              iconTheme: WidgetStatePropertyAll(
                IconThemeData(color: Color(0xFFCBD5E1)),
              ),
            ),
            dataTableTheme: const DataTableThemeData(
              headingRowColor: WidgetStatePropertyAll(Color(0xFF263449)),
              dataRowColor: WidgetStatePropertyAll(Color(0xFF1E293B)),
              headingTextStyle: TextStyle(
                color: Color(0xFF86D18F),
                fontWeight: FontWeight.bold,
              ),
              dataTextStyle: TextStyle(color: Color(0xFFE2E8F0)),
              dividerThickness: 0.7,
            ),
          ),
          home: const LoginScreen(),
        );
      },
    );
  }
}
