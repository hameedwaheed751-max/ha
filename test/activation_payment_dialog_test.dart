import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';
import 'package:untitled/screens/activation_payment_dialog.dart';
import 'package:untitled/services/finance_ledger.dart';

void main() {
  final subscriber = Subscriber(
    user: 'u1',
    name: 'Test User',
    phone: '',
    address: '',
    ip: '',
    type: 'باقة 35',
    price: 0,
    startDate: DateTime(2026, 10, 1),
    endDate: DateTime(2026, 11, 1),
  );

  Future<ActivationPayment? Function()> open(
    WidgetTester tester, {
    double suggestedPrice = 35000,
    double recordedAmount = 0,
    bool cardActivationAvailable = false,
  }) async {
    ActivationPayment? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<ActivationPayment>(
                  context: context,
                  builder: (_) => ActivationPaymentDialog(
                    subscriber: subscriber,
                    suggestedPrice: suggestedPrice,
                    recordedAmount: recordedAmount,
                    cardActivationAvailable: cardActivationAvailable,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => result;
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.text('تفعيل'));
    await tester.pumpAndSettle();
  }

  testWidgets('paid on activation collects the suggested price', (
    tester,
  ) async {
    final result = await open(tester);

    await confirm(tester);

    expect(result()?.saleAmount, 35000);
    expect(result()?.collected, 35000);
    expect(
      result()?.settlement,
      ActivationSettlement.paidOnActivation,
    );
  });

  testWidgets('a partial payment collects only the typed amount', (
    tester,
  ) async {
    final result = await open(tester);

    await tester.tap(find.text('تسديد جزء'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(1), '١٥٠٠٠');
    await tester.pumpAndSettle();

    expect(find.text('20,000 د.ع'), findsOneWidget);
    await confirm(tester);

    expect(result()?.saleAmount, 35000);
    expect(result()?.collected, 15000);
  });

  testWidgets('full debt collects nothing', (tester) async {
    final result = await open(tester);

    await tester.tap(find.text('دين كامل المبلغ'));
    await tester.pumpAndSettle();
    await confirm(tester);

    expect(result()?.saleAmount, 35000);
    expect(result()?.collected, 0);
  });

  testWidgets('an amount recorded earlier is not asked for or charged again', (
    tester,
  ) async {
    final result = await open(tester, recordedAmount: 35000);

    expect(find.byType(TextFormField), findsNothing);
    await confirm(tester);

    expect(result()?.alreadyRecorded, isTrue);
    expect(result()?.saleAmount, 35000);
    expect(result()?.collected, 35000);
  });

  testWidgets('the agent can still enter a new sale over a recorded amount', (
    tester,
  ) async {
    final result = await open(tester, recordedAmount: 35000);

    await tester.tap(find.text('هذا اشتراك جديد بمبلغ آخر'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '45000');
    await tester.pumpAndSettle();
    await confirm(tester);

    expect(result()?.alreadyRecorded, isFalse);
    expect(result()?.saleAmount, 45000);
    expect(result()?.collected, 45000);
  });

  testWidgets('activation needs a subscription amount', (tester) async {
    final result = await open(tester, suggestedPrice: 0);

    await confirm(tester);

    expect(find.text('أدخل مبلغ الاشتراك'), findsOneWidget);
    expect(result(), isNull);
  });

  testWidgets('no card option is shown unless card activation is available', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('طريقة التفعيل'), findsNothing);
    expect(find.byKey(const Key('activation-card-chip')), findsNothing);
  });

  testWidgets('the balance path still returns a null card pin', (tester) async {
    final result = await open(tester, cardActivationAvailable: true);

    // الخيار ظاهر، لكن الوكيل بقي على «رصيد».
    expect(find.text('طريقة التفعيل'), findsOneWidget);
    expect(find.byKey(const Key('activation-card-pin')), findsNothing);
    await confirm(tester);

    expect(result()?.cardPin, isNull);
    expect(result()?.saleAmount, 35000);
  });

  testWidgets('choosing card reveals the pin box and returns the pin', (
    tester,
  ) async {
    final result = await open(tester, cardActivationAvailable: true);

    await tester.tap(find.byKey(const Key('activation-card-chip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('activation-card-pin')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('activation-card-pin')),
      '58952087807522',
    );
    await tester.pumpAndSettle();
    await confirm(tester);

    expect(result()?.cardPin, '58952087807522');
    // التسجيل المالي يبقى كما هو إلى جانب البطاقة.
    expect(result()?.saleAmount, 35000);
    expect(result()?.collected, 35000);
  });

  testWidgets('card activation requires a card number before it proceeds', (
    tester,
  ) async {
    final result = await open(tester, cardActivationAvailable: true);

    await tester.tap(find.byKey(const Key('activation-card-chip')));
    await tester.pumpAndSettle();
    await confirm(tester);

    expect(find.text('أدخل رقم البطاقة'), findsOneWidget);
    expect(result(), isNull);
  });
}
