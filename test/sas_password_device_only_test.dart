import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:untitled/models.dart';
import 'package:untitled/sas_api_service.dart';
import 'package:untitled/sas_project_national_service.dart';
import 'package:untitled/screens/sas_settings_screen.dart';

SasSettings _sas({String password = '', String id = ''}) => SasSettings(
  serverUrl: 'https://one.example.com',
  username: 'm',
  password: password,
  accountId: id,
  label: 'ساس المنصور',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a linked SAS without a password on this device asks for it', () {
    final missing = _sas();
    expect(missing.isLinked, isTrue);
    expect(missing.isConfigured, isFalse);
    expect(missing.needsPassword, isTrue);
    expect(missing.missingPasswordMessage, contains('ساس المنصور'));

    final ready = _sas(password: 'p');
    expect(ready.needsPassword, isFalse);
    expect(ready.isConfigured, isTrue);
  });

  test('login without a password stops with the clear message', () async {
    final api = SasApiService(_sas());
    addTearDown(api.dispose);
    await expectLater(
      api.login(),
      throwsA(
        isA<SasApiException>().having(
          (e) => e.toString(),
          'message',
          contains('على هذا الجهاز'),
        ),
      ),
    );
  });

  test('FTTH without a password on this device asks for it', () async {
    const settings = SasProjectNationalSettings(
      baseUrl: 'https://admin.ftth.iq',
      username: 'agent',
      password: '',
    );
    expect(settings.needsPassword, isTrue);
    final service = SasProjectNationalService(settings);
    addTearDown(service.dispose);
    await expectLater(
      service.login(),
      throwsA(isA<SasProjectNationalException>()),
    );
  });

  testWidgets('the card shows the missing password and opens edit', (
    tester,
  ) async {
    final picked = <SasCardAction>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SasAccountCard(
            account: _sas(id: 'k2'),
            subscribers: 3,
            onSelected: picked.add,
          ),
        ),
      ),
    );
    expect(find.text('أدخل كلمة المرور على هذا الجهاز'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('needs-password-k2')));
    expect(picked, [SasCardAction.edit]);
  });

  testWidgets('a card with its password shows no warning', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SasAccountCard(
            account: _sas(password: 'p'),
            subscribers: 0,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('أدخل كلمة المرور على هذا الجهاز'), findsNothing);
  });

  testWidgets('the primary SAS stays listed when its password is missing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: SasSettingsScreen(
          loadPrimary: () async => _sas(),
          loadExtras: () async => const [],
          planAllowsExtra: () => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SasAccountCard), findsOneWidget);
    expect(find.text('إضافة ساس آخر'), findsOneWidget);
  });

  test(
    'another account on this device loses the extra SAS passwords',
    () async {
      SharedPreferences.setMockInitialValues({
        'sas_extra_accounts': '{"k2":{"serverUrl":"https://two.example.com"}}',
        'sas_extra_pass_k2': 'secret',
        'sas_label': 'ساس المنصور',
      });
      await AppStore.clearForAccountSwitch(clearStorage: true);
      final p = await SharedPreferences.getInstance();
      expect(p.getString('sas_extra_accounts'), isNull);
      expect(p.getString('sas_extra_pass_k2'), isNull);
      expect(p.getString('sas_label'), isNull);
    },
  );
}
