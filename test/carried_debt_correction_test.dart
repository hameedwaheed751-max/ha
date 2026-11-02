import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';
import 'package:untitled/screens/dashboard_widgets.dart';
import 'package:untitled/screens/partial_payment_flow.dart';

Subscriber _subscriber(double carriedDebt) {
  final now = DateTime.now();
  return Subscriber(
    user: 'u',
    name: 'سالم',
    phone: '',
    address: '',
    ip: '',
    type: 'Normal',
    price: 0,
    startDate: now,
    endDate: now.add(const Duration(days: 30)),
    carriedDebt: carriedDebt,
  );
}

void main() {
  Future<List<CarriedDebtCorrection?>> pumpDialog(WidgetTester tester) async {
    final results = <CarriedDebtCorrection?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              results.add(
                await showDialog<CarriedDebtCorrection>(
                  context: context,
                  builder: (_) => const CarriedDebtCorrectionDialog(
                    subscriberName: 'سالم',
                    currentAmount: 50000,
                  ),
                ),
              );
            },
            child: const Text('فتح'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('فتح'));
    await tester.pumpAndSettle();
    return results;
  }

  testWidgets('the reason is required', (tester) async {
    final results = await pumpDialog(tester);
    await tester.enterText(find.byType(TextFormField).first, '20000');
    await tester.tap(find.text('حفظ'));
    await tester.pump();

    expect(find.text('سبب التصحيح مطلوب'), findsOneWidget);
    expect(results, isEmpty);
  });

  testWidgets('a lower amount is announced as collected', (tester) async {
    final results = await pumpDialog(tester);
    await tester.enterText(find.byType(TextFormField).first, '20,000');
    await tester.pump();
    expect(find.textContaining('30,000 د.ع في الواصل'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).last, 'دفعة قديمة');
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();

    expect(results.single?.newAmount, 20000);
    expect(results.single?.reason, 'دفعة قديمة');
  });

  testWidgets('a higher amount is announced as added debt', (tester) async {
    await pumpDialog(tester);
    await tester.enterText(find.byType(TextFormField).first, '60000');
    await tester.pump();

    expect(find.textContaining('10,000 د.ع إلى الديون'), findsOneWidget);
  });

  Future<void> openMenu(WidgetTester tester, double carriedDebt) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DebtOperationsMenu(
            subscriber: _subscriber(carriedDebt),
            onCorrectCarriedDebt: (_) async {},
          ),
        ),
      ),
    );
    await tester.tap(find.byType(DebtOperationsMenu));
    await tester.pumpAndSettle();
  }

  testWidgets('the menu offers the correction for carried debt', (
    tester,
  ) async {
    await openMenu(tester, 50000);
    expect(find.text('تصحيح الدين المرحّل'), findsOneWidget);
  });

  testWidgets('the menu hides the correction without carried debt', (
    tester,
  ) async {
    await openMenu(tester, 0);
    expect(find.text('تصحيح الدين المرحّل'), findsNothing);
  });
}
