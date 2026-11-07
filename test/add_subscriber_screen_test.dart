import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:untitled/models.dart';
import 'package:untitled/screens/add_subscriber_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppStore.packages.clear();
  });

  Future<void> pump(WidgetTester tester, {Subscriber? subscriber}) async {
    tester.view.physicalSize = const Size(390, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: AddSubscriberScreen(subscriber: subscriber)),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('adding a subscriber asks for no amounts', (tester) async {
    await pump(tester);

    expect(find.text('مبلغ الاشتراك'), findsNothing);
    expect(find.text('المبلغ المدفوع عند التسجيل'), findsNothing);
    expect(find.text('تاريخ التسديد'), findsNothing);
    expect(find.text('إضافة إلى SAS'), findsOneWidget);
    expect(find.textContaining('اختياري'), findsNothing);
    expect(find.text('تاريخ بداية الاشتراك'), findsNothing);
    expect(find.text('تاريخ انتهاء الاشتراك'), findsNothing);
  });

  testWidgets('a subscriber added in the app waits for SAS activation', (
    tester,
  ) async {
    AppStore.subscribers.clear();
    addTearDown(AppStore.subscribers.clear);
    await pump(tester);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'new.user');
    await tester.enterText(fields.at(1), 'مشترك جديد');
    await tester.tap(find.text('حفظ المشترك'));
    await tester.pump(const Duration(seconds: 1));

    final s = AppStore.subscribers.single;
    expect(s.active, isFalse);
    expect(s.isActive, isFalse);
    expect(s.awaitingActivation, isTrue);
    expect(s.remaining, 0);
  });

  testWidgets('editing a subscriber still shows the amounts', (tester) async {
    await pump(
      tester,
      subscriber: Subscriber(
        user: 'u1',
        name: 'مشترك',
        phone: '',
        address: '',
        ip: '',
        type: 'Fiber 50',
        price: 25000,
        paid: 10000,
        startDate: DateTime(2026, 11, 1),
        endDate: DateTime(2026, 12, 1),
      ),
    );

    expect(find.text('مبلغ الاشتراك'), findsOneWidget);
    expect(find.text('واصل الشهر الحالي'), findsOneWidget);
    expect(find.text('تاريخ التسديد'), findsOneWidget);
    expect(find.text('إضافة إلى SAS'), findsNothing);
  });
}
