import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/sas_api_service.dart' show SasApiException;
import 'package:untitled/screens/cards_screen.dart';
import 'package:untitled/services/voucher_store.dart';

class _FakeVoucherApi implements VoucherApi {
  _FakeVoucherApi({
    this.balance = 100000,
    List<VoucherPurchase>? purchases,
    List<CardSeries>? series,
    Map<String, List<CardPin>>? cardsBySeries,
    this.buyThrows = false,
  }) : purchases = purchases ?? const [],
       series = series ?? const [],
       cardsBySeries = cardsBySeries ?? const {};

  double? balance;
  List<VoucherPurchase> purchases;
  List<CardSeries> series;
  Map<String, List<CardPin>> cardsBySeries;
  bool buyThrows;
  final List<({int cardValue, int quantity})> buys = [];

  @override
  Future<List<CardSeries>> fetchCardSeries() async => series;

  @override
  Future<List<CardPin>> fetchSeriesCards(String s) async =>
      cardsBySeries[s] ?? const [];

  @override
  Future<double?> fetchVoucherBalance() async => balance;

  @override
  Future<List<VoucherPurchase>> fetchVoucherPurchases() async => purchases;

  @override
  Future<String> buyVouchers({
    required int cardValue,
    required int quantity,
  }) async {
    buys.add((cardValue: cardValue, quantity: quantity));
    if (buyThrows) throw SasApiException('الرصيد غير كافٍ لإتمام الشراء');
    purchases = [
      VoucherPurchase(
        cardValue: cardValue,
        qty: quantity,
        status: 0,
        createdAt: 'now',
      ),
      ...purchases,
    ];
    return 'تم شراء الكروت بنجاح';
  }
}

void main() {
  Future<void> pump(WidgetTester tester, _FakeVoucherApi api) async {
    await tester.pumpWidget(
      MaterialApp(home: CardsScreen(api: api, companyLabel: 'otto')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the balance and the purchase history', (tester) async {
    final api = _FakeVoucherApi(
      balance: 232000,
      purchases: [
        const VoucherPurchase(
          cardValue: 20000,
          qty: 5,
          status: 2,
          createdAt: '2026-11-13',
        ),
      ],
    );
    await pump(tester, api);

    expect(find.byKey(const Key('cards-balance')), findsOneWidget);
    expect(find.text('5 × 20,000 د.ع'), findsOneWidget);
    expect(find.text('مكتمل'), findsOneWidget);
  });

  testWidgets('buying asks for confirmation then calls the api', (
    tester,
  ) async {
    final api = _FakeVoucherApi(balance: 232000);
    await pump(tester, api);

    await tester.enterText(find.byKey(const Key('cards-value')), '20000');
    await tester.enterText(find.byKey(const Key('cards-qty')), '3');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('cards-buy')));
    await tester.pumpAndSettle();

    // حوار التأكيد ظاهر، ولم يُنفَّذ الشراء بعد.
    expect(find.text('تأكيد شراء الكروت'), findsOneWidget);
    expect(api.buys, isEmpty);

    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('شراء'),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.buys.single.cardValue, 20000);
    expect(api.buys.single.quantity, 3);
    expect(find.text('تم شراء الكروت بنجاح'), findsOneWidget);
  });

  testWidgets('cancelling the confirmation does not buy', (tester) async {
    final api = _FakeVoucherApi(balance: 232000);
    await pump(tester, api);

    await tester.tap(find.byKey(const Key('cards-buy')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إلغاء'));
    await tester.pumpAndSettle();

    expect(api.buys, isEmpty);
  });

  testWidgets('a failed purchase surfaces the error', (tester) async {
    final api = _FakeVoucherApi(balance: 1000, buyThrows: true);
    await pump(tester, api);

    await tester.tap(find.byKey(const Key('cards-buy')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('شراء'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('الرصيد غير كافٍ لإتمام الشراء'), findsOneWidget);
  });

  testWidgets('tapping a series opens its card pins', (tester) async {
    final api = _FakeVoucherApi(
      series: const [
        CardSeries(
          series: '2026-819119',
          value: 23000,
          qty: 2,
          used: 1,
          profileName: 'Standard',
          seriesDate: '2026-11-12',
          expiration: '2027-12-31',
        ),
      ],
      cardsBySeries: const {
        '2026-819119': [
          CardPin(
            serialnumber: 'a',
            pin: '55556666777788',
            usedAt: '2026-11-12',
          ),
          CardPin(serialnumber: 'b', pin: '99990000111122', usedAt: ''),
        ],
      },
    );
    await pump(tester, api);

    // السلسلة ظاهرة مع المتاح/الإجمالي.
    expect(find.text('متاح 1/2'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('series-2026-819119')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('series-2026-819119')));
    await tester.pumpAndSettle();

    // أرقام الـ PIN ظاهرة مع حالتها.
    expect(find.text('99990000111122'), findsOneWidget);
    expect(find.text('غير مستعمل'), findsOneWidget);
    expect(find.text('55556666777788'), findsOneWidget);
  });
}
