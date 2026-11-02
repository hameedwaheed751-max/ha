import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/screens/plan_prices_admin_screen.dart';
import 'package:untitled/services/payment_request_service.dart';

void main() {
  tearDown(() => PaymentPlanCatalog.applyPrices(null));

  group('plan prices', () {
    test('a paid plan has no price until the administrator sets one', () {
      expect(PaymentPlanCatalog.amount('three_months'), '');
      expect(PaymentPlanCatalog.amount('trial'), 'مجاني');
    });

    test('saved prices are read for current and old plan names', () {
      PaymentPlanCatalog.applyPrices({
        'three_months': '25000',
        'six_months': 40000,
        'one_year': 'not a price',
      });

      expect(PaymentPlanCatalog.amount('3m'), '25000');
      expect(PaymentPlanCatalog.amount('six_months'), '40000');
      expect(PaymentPlanCatalog.amount('one_year'), '');
    });

    test('the payment account is read and trimmed', () {
      PaymentPlanCatalog.applyPaymentAccount({
        'accountNumber': ' 1234 ',
        'cardNumber': 5678,
      });

      expect(PaymentPlanCatalog.accountNumber, '1234');
      expect(PaymentPlanCatalog.cardNumber, '5678');

      PaymentPlanCatalog.applyPaymentAccount(null);

      expect(PaymentPlanCatalog.accountNumber, '');
    });

    test('typed prices are stored as plain digits', () {
      expect(PaymentPlanCatalog.normalizePrice('٤٥,٠٠٠'), '45000');
      expect(PaymentPlanCatalog.normalizePrice(' 20 000 '), '20000');
      expect(PaymentPlanCatalog.normalizePrice('0'), isNull);
      expect(PaymentPlanCatalog.normalizePrice('-500'), isNull);
      expect(PaymentPlanCatalog.normalizePrice('12.5'), isNull);
      expect(PaymentPlanCatalog.normalizePrice(''), isNull);
    });
  });

  group('prices screen', () {
    Future<List<Map<String, String>>> open(WidgetTester tester) async {
      final saved = <Map<String, String>>[];
      tester.view
        ..physicalSize = const Size(1000, 2000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanPricesAdminScreen(
              loadPrices: () async => PaymentPlanCatalog.applyPrices({
                'three_months': '20000',
                'six_months': '30000',
                'one_year': '45000',
              }),
              savePrices: (prices) async => saved.add(prices),
              savePaymentAccount: (account) async => saved.add(account),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return saved;
    }

    testWidgets('shows the saved prices and saves the edited ones', (
      tester,
    ) async {
      final saved = await open(tester);

      expect(find.text('20000'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).first, '٢٥,٠٠٠');
      await tester.enterText(find.byType(TextFormField).at(3), ' 1234 ');
      await tester.enterText(find.byType(TextFormField).at(4), '5678');
      await tester.tap(find.text('حفظ'));
      await tester.pumpAndSettle();

      expect(saved, [
        {'three_months': '25000', 'six_months': '30000', 'one_year': '45000'},
        {'accountNumber': '1234', 'cardNumber': '5678'},
      ]);
    });

    testWidgets('refuses an invalid price', (tester) async {
      final saved = await open(tester);

      await tester.enterText(find.byType(TextFormField).first, '0');
      await tester.tap(find.text('حفظ'));
      await tester.pumpAndSettle();

      expect(find.text('أدخل مبلغاً صحيحاً'), findsOneWidget);
      expect(saved, isEmpty);
    });
  });
}
