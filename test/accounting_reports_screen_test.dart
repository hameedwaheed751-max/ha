import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:untitled/models.dart';
import 'package:untitled/screens/accounting_reports_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppStore.accountingActivations.clear();
    AppStore.dailyTaskEvents.clear();
  });

  tearDown(() {
    AppStore.accountingActivations.clear();
    AppStore.dailyTaskEvents.clear();
  });

  testWidgets('report fits a phone and shows the payment status', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final now = DateTime.now();
    final at = DateTime(now.year, now.month, 1, 10);
    AppStore.accountingActivations.add(
      AccountingActivationRecord(
        subscriberUser: 'ali.fiber',
        subscriberName: 'علي حسن عبد الأمير',
        packageName: 'Fiber 35',
        saleAmount: 35000,
        sasDeduction: 29000,
        at: at,
      ),
    );
    AppStore.dailyTaskEvents.addAll(
      DailyTaskEvent.activationSettlement(
        subscriberUser: 'ali.fiber',
        subscriberName: 'علي حسن عبد الأمير',
        at: at,
        collected: 10000,
        remaining: 25000,
        note: 'تفعيل',
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(home: AccountingReportsScreen()),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('المبيعات والربح'), findsOneWidget);
    expect(find.text('واصل عند التفعيل'), findsOneWidget);
    expect(find.text('الربح'), findsOneWidget);
    expect(find.text('6,000 د.ع'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('تسديد جزء'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('تسديد جزء'), findsOneWidget);
    expect(find.text('واصل 10,000 د.ع · دين 25,000 د.ع'), findsOneWidget);
    // المبالغ القديمة المحيرة لم تعد ظاهرة.
    expect(find.text('فرق الفواتير عن صافي الدفعات'), findsNothing);
    expect(find.text('الدفعات الموجبة المسجلة'), findsNothing);

    final exception = tester.takeException();
    expect(
      exception,
      isNull,
      reason: exception is FlutterError
          ? exception.toStringDeep()
          : '$exception',
    );
  });
}
