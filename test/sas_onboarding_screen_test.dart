import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:untitled/screens/sas_onboarding_screen.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the sync button is disabled until a sas is linked', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SasOnboardingScreen(
          checkLinked: () async => false,
          runSync: () async => (ok: true, message: 'x'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final syncBtn = tester.widget<FilledButton>(
      find.byKey(const Key('onboarding-sync-btn')),
    );
    expect(syncBtn.onPressed, isNull);
    expect(find.text('اربط الساس أولاً لتفعيل زر المزامنة.'), findsOneWidget);
  });

  testWidgets('a successful sync advances past the gate', (tester) async {
    var done = false;
    await tester.pumpWidget(
      MaterialApp(
        home: SasOnboardingScreen(
          checkLinked: () async => true,
          runSync: () async => (ok: true, message: 'تمت'),
          onDone: () => done = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // زر المزامنة مُفعَّل لأن الساس مربوط.
    final syncBtn = tester.widget<FilledButton>(
      find.byKey(const Key('onboarding-sync-btn')),
    );
    expect(syncBtn.onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('onboarding-sync-btn')));
    await tester.pumpAndSettle();

    expect(done, isTrue);
  });

  testWidgets('a failed sync shows the error and stays on the gate', (
    tester,
  ) async {
    var done = false;
    await tester.pumpWidget(
      MaterialApp(
        home: SasOnboardingScreen(
          checkLinked: () async => true,
          runSync: () async => (ok: false, message: 'تعذّرت المزامنة'),
          onDone: () => done = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('onboarding-sync-btn')));
    await tester.pumpAndSettle();

    expect(done, isFalse);
    expect(find.byKey(const Key('onboarding-error')), findsOneWidget);
    expect(find.text('تعذّرت المزامنة'), findsOneWidget);
  });
}
