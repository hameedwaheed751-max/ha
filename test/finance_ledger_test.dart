import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/services/finance_ledger.dart';
import 'package:untitled/services/finance_service.dart';

class _MemoryFinanceStore implements FinanceStore {
  final Map<String, List<FinanceEntry>> entries = {};
  int nextReceiptNumber = 412;

  @override
  Future<List<FinanceEntry>> readEntries(String subscriberId) async =>
      List.of(entries[subscriberId] ?? const <FinanceEntry>[]);

  @override
  Future<int> allocateReceiptNumber() async => nextReceiptNumber++;

  @override
  Future<List<FinanceEntry>> commit(
    String subscriberId,
    FinancePlan plan,
  ) async {
    final planned = plan(await readEntries(subscriberId));
    entries.putIfAbsent(subscriberId, () => []).addAll(planned);
    return planned;
  }
}

const _ali = FinanceSubscriberRef(id: 'sub-1', user: 'ali', name: 'علي حسن');
const _agent = 'agent-1';

void main() {
  late _MemoryFinanceStore store;
  late DateTime now;
  late FinanceService service;
  var operation = 0;

  String nextOperation() => 'op${operation++}';

  FinanceAccount account([String subscriberId = 'sub-1']) =>
      FinanceAccount.fromEntries(store.entries[subscriberId] ?? const []);

  Future<List<FinanceEntry>> activate(
    FinanceSaleInput input, {
    FinanceSubscriberRef subscriber = _ali,
  }) => service.recordSale(
    operationId: nextOperation(),
    subscriber: subscriber,
    input: input,
    createdBy: _agent,
  );

  Future<List<FinanceEntry>> pay(int amount) => service.recordPayment(
    operationId: nextOperation(),
    subscriber: _ali,
    amount: amount,
    createdBy: _agent,
  );

  setUp(() {
    store = _MemoryFinanceStore();
    now = DateTime(2026, 10, 2, 10);
    service = FinanceService(store: store, clock: () => now);
  });

  group('activation outcomes', () {
    test('paid on activation leaves no debt and issues one receipt', () async {
      final entries = await activate(
        const FinanceSaleInput(
          packageName: 'باقة 35',
          salePrice: 35000,
          settlement: ActivationSettlement.paidOnActivation,
        ),
      );

      expect(account().balance, 0);
      final payment = entries.singleWhere(
        (entry) => entry.type == FinanceEntryType.payment,
      );
      expect(payment.amount, 35000);
      expect(payment.note, 'واصل عند التفعيل');
      expect(payment.receiptNumber, 412);
    });

    test('a partial payment leaves the rest as debt', () async {
      await activate(
        const FinanceSaleInput(
          packageName: 'باقة 45',
          salePrice: 45000,
          settlement: ActivationSettlement.partialPayment,
          partialAmount: 20000,
        ),
      );

      expect(account().balance, 25000);
      expect(account().openItems.single.outstanding, 25000);
    });

    test('full debt records the whole amount without a receipt', () async {
      final entries = await activate(
        const FinanceSaleInput(
          packageName: 'باقة 45',
          salePrice: 45000,
          settlement: ActivationSettlement.fullDebt,
        ),
      );

      expect(account().balance, 45000);
      expect(entries.single.type, FinanceEntryType.subscriptionSale);
      expect(store.nextReceiptNumber, 412);
    });

    test('a partial amount must stay below the sale price', () async {
      for (final partial in [0, 45000, 50000]) {
        await expectLater(
          activate(
            FinanceSaleInput(
              packageName: 'باقة 45',
              salePrice: 45000,
              settlement: ActivationSettlement.partialPayment,
              partialAmount: partial,
            ),
          ),
          throwsA(
            isA<FinancePolicyException>().having(
              (error) => error.code,
              'code',
              FinancePolicyCode.invalidAmount,
            ),
          ),
        );
      }
      expect(store.entries, isEmpty);
    });

    test('two activations in one month are both charged', () async {
      const fullDebt = FinanceSaleInput(
        packageName: 'باقة 35',
        salePrice: 35000,
        settlement: ActivationSettlement.fullDebt,
      );
      await activate(fullDebt);
      now = DateTime(2026, 10, 31, 10);
      await activate(fullDebt);

      expect(account().balance, 70000);
    });

    test('an extension is recorded as a subscription sale', () async {
      await activate(
        const FinanceSaleInput(
          packageName: 'باقة 35',
          salePrice: 35000,
          settlement: ActivationSettlement.fullDebt,
          saleKind: FinanceSaleKind.extension,
        ),
      );

      final summary = FinanceSummary.forPeriod(
        store.entries['sub-1']!,
        FinancePeriod.month(DateTime(2026, 10)),
      );
      expect(summary.subscriptionSales, 35000);
      expect(summary.extensionCount, 1);
      expect(summary.activationCount, 0);
    });
  });

  group('purchases', () {
    Future<void> buy(int paid) => service.recordPurchase(
      operationId: nextOperation(),
      subscriber: _ali,
      input: FinancePurchaseInput(
        description: 'راوتر',
        amount: 15000,
        paidAmount: paid,
      ),
      createdBy: _agent,
    );

    test('a paid purchase leaves no debt', () async {
      await buy(15000);
      expect(account().balance, 0);
      expect(store.nextReceiptNumber, 413);
    });

    test('an unpaid purchase becomes debt without a receipt', () async {
      await buy(0);
      expect(account().balance, 15000);
      expect(store.nextReceiptNumber, 412);
    });

    test('a partly paid purchase keeps the rest as debt', () async {
      await buy(5000);
      expect(account().balance, 10000);
    });

    test('a purchase needs a description', () async {
      await expectLater(
        service.recordPurchase(
          operationId: nextOperation(),
          subscriber: _ali,
          input: const FinancePurchaseInput(description: ' ', amount: 15000),
          createdBy: _agent,
        ),
        throwsA(isA<FinancePolicyException>()),
      );
    });

    test('a purchase stays out of subscription profit', () async {
      await activate(
        const FinanceSaleInput(
          packageName: 'باقة 45',
          salePrice: 45000,
          sasCost: 36000,
          settlement: ActivationSettlement.paidOnActivation,
          purchase: FinancePurchaseInput(description: 'راوتر', amount: 15000),
        ),
      );

      final summary = FinanceSummary.forPeriod(
        store.entries['sub-1']!,
        FinancePeriod.month(DateTime(2026, 10)),
      );
      expect(account().balance, 15000);
      expect(summary.subscriptionProfit, 9000);
      expect(summary.purchases, 15000);
      expect(summary.totalSales, 60000);
    });
  });

  group('payments', () {
    setUp(() async {
      await activate(
        const FinanceSaleInput(
          packageName: 'باقة 45',
          salePrice: 45000,
          settlement: ActivationSettlement.fullDebt,
        ),
      );
    });

    test('a payment above the debt is blocked without using a receipt', () async {
      await expectLater(
        pay(45001),
        throwsA(
          isA<FinancePolicyException>().having(
            (error) => error.code,
            'code',
            FinancePolicyCode.overpayment,
          ),
        ),
      );
      expect(account().balance, 45000);
      expect(store.nextReceiptNumber, 412);
    });

    test('payments settle the oldest amount first', () async {
      now = DateTime(2026, 10, 20, 10);
      await service.recordPurchase(
        operationId: nextOperation(),
        subscriber: _ali,
        input: const FinancePurchaseInput(description: 'راوتر', amount: 15000),
        createdBy: _agent,
      );
      await pay(50000);

      final open = account().openItems.single;
      expect(open.entry.type, FinanceEntryType.purchase);
      expect(open.outstanding, 10000);
      expect(account().debtAgeInDays(DateTime(2026, 10, 25, 10)), 5);
    });

    test('receipt numbers follow each other', () async {
      final first = await pay(1000);
      final second = await pay(1000);

      expect(first.single.receiptNumber, 412);
      expect(second.single.receiptNumber, 413);
    });

    test('repeating an operation does not record it twice', () async {
      Future<List<FinanceEntry>> repeat() => service.recordPayment(
        operationId: 'retry-1',
        subscriber: _ali,
        amount: 10000,
        createdBy: _agent,
      );

      final first = await repeat();
      final second = await repeat();

      expect(second.single.id, first.single.id);
      expect(account().balance, 35000);
      expect(store.nextReceiptNumber, 413);
    });
  });

  group('corrections and reversals', () {
    late List<FinanceEntry> sale;

    Future<List<FinanceEntry>> reverse(String entryId) => service.reverseEntry(
      operationId: nextOperation(),
      subscriber: _ali,
      entryId: entryId,
      reason: 'خطأ في التسجيل',
      createdBy: _agent,
    );

    setUp(() async {
      sale = await activate(
        const FinanceSaleInput(
          packageName: 'باقة 45',
          salePrice: 45000,
          settlement: ActivationSettlement.fullDebt,
        ),
      );
    });

    test('a correction needs a reason and cannot exceed the debt', () async {
      await expectLater(
        service.recordCorrection(
          operationId: nextOperation(),
          subscriber: _ali,
          amount: -5000,
          reason: '',
          createdBy: _agent,
        ),
        throwsA(isA<FinancePolicyException>()),
      );
      await expectLater(
        service.recordCorrection(
          operationId: nextOperation(),
          subscriber: _ali,
          amount: -45001,
          reason: 'خصم',
          createdBy: _agent,
        ),
        throwsA(
          isA<FinancePolicyException>().having(
            (error) => error.code,
            'code',
            FinancePolicyCode.excessiveCorrection,
          ),
        ),
      );

      await service.recordCorrection(
        operationId: nextOperation(),
        subscriber: _ali,
        amount: -5000,
        reason: 'خصم',
        createdBy: _agent,
      );
      expect(account().balance, 40000);
    });

    test('reversing keeps the original entry and restores the balance', () async {
      final payment = await pay(20000);
      await reverse(payment.single.id);

      expect(account().balance, 45000);
      expect(
        store.entries['sub-1']!.map((entry) => entry.id),
        contains(payment.single.id),
      );
    });

    test('an entry can only be reversed once', () async {
      final payment = await pay(20000);
      await reverse(payment.single.id);

      await expectLater(
        reverse(payment.single.id),
        throwsA(
          isA<FinancePolicyException>().having(
            (error) => error.code,
            'code',
            FinancePolicyCode.entryAlreadyReversed,
          ),
        ),
      );
    });

    test('a paid charge cannot be reversed before its payment', () async {
      final payment = await pay(45000);

      await expectLater(
        reverse(sale.single.id),
        throwsA(
          isA<FinancePolicyException>().having(
            (error) => error.code,
            'code',
            FinancePolicyCode.reversalLeavesCredit,
          ),
        ),
      );

      await reverse(payment.single.id);
      await reverse(sale.single.id);
      expect(account().balance, 0);
    });

    test('reversed operations leave the period totals', () async {
      await reverse(sale.single.id);

      final summary = FinanceSummary.forPeriod(
        store.entries['sub-1']!,
        FinancePeriod.month(DateTime(2026, 10)),
      );
      expect(summary.subscriptionSales, 0);
      expect(summary.activationCount, 0);
      expect(summary.debtAdded, 0);
    });
  });

  group('period summary', () {
    test('a cash activation adds no debt and a debt one still counts', () async {
      await activate(
        const FinanceSaleInput(
          packageName: 'باقة 35',
          salePrice: 35000,
          settlement: ActivationSettlement.paidOnActivation,
        ),
      );
      await activate(
        const FinanceSaleInput(
          packageName: 'باقة 35',
          salePrice: 35000,
          settlement: ActivationSettlement.fullDebt,
        ),
        subscriber: const FinanceSubscriberRef(
          id: 'sub-2',
          user: 'karrar',
          name: 'كرار علي',
        ),
      );

      final summary = FinanceSummary.forPeriod(
        store.entries.values.expand((entries) => entries),
        FinancePeriod.day(DateTime(2026, 10, 2)),
      );
      expect(summary.activationCount, 2);
      expect(summary.collected, 35000);
      expect(summary.debtAdded, 35000);
      expect(summary.debtRepayments, 0);
    });

    test('a working day adds up the way the agent counts it', () async {
      now = DateTime(2026, 9, 1, 9);
      await activate(
        const FinanceSaleInput(
          packageName: 'باقة 60',
          salePrice: 90000,
          settlement: ActivationSettlement.fullDebt,
        ),
      );

      now = DateTime(2026, 10, 31, 9);
      await activate(
        const FinanceSaleInput(
          packageName: 'باقة 45',
          salePrice: 45000,
          settlement: ActivationSettlement.paidOnActivation,
        ),
        subscriber: const FinanceSubscriberRef(
          id: 'sub-2',
          user: 'haider',
          name: 'حيدر سالم',
        ),
      );
      await activate(
        const FinanceSaleInput(
          packageName: 'باقة 35',
          salePrice: 35000,
          settlement: ActivationSettlement.partialPayment,
          partialAmount: 20000,
        ),
        subscriber: const FinanceSubscriberRef(
          id: 'sub-3',
          user: 'huda',
          name: 'هدى رعد',
        ),
      );
      await activate(
        const FinanceSaleInput(
          packageName: 'باقة 35',
          salePrice: 35000,
          settlement: ActivationSettlement.fullDebt,
        ),
        subscriber: const FinanceSubscriberRef(
          id: 'sub-4',
          user: 'karrar',
          name: 'كرار علي',
        ),
      );
      await pay(75000);

      final summary = FinanceSummary.forPeriod(
        store.entries.values.expand((entries) => entries),
        FinancePeriod.day(DateTime(2026, 10, 31)),
      );
      expect(summary.collected, 140000);
      expect(summary.subscriptionSales, 115000);
      expect(summary.debtAdded, 50000);
      expect(summary.debtRepayments, 75000);
      expect(summary.activationCount, 3);
    });
  });

  group('movements appear once', () {
    List<FinanceMovement> octoberMovements() => FinanceMovement.forPeriod(
      store.entries.values.expand((entries) => entries),
      FinancePeriod.month(DateTime(2026, 10)),
    );

    test('a cash activation is one collected movement and no debt', () async {
      await activate(
        const FinanceSaleInput(
          packageName: 'باقة 35',
          salePrice: 35000,
          settlement: ActivationSettlement.paidOnActivation,
        ),
      );

      final movement = octoberMovements().single;
      expect(movement.type, FinanceMovementType.collectedOnActivation);
      expect(movement.amount, 35000);
      expect(movement.note, 'باقة 35');
      expect(movement.receiptNumber, 412);
    });

    test('a partial activation splits into collected and debt', () async {
      await activate(
        const FinanceSaleInput(
          packageName: 'باقة 35',
          salePrice: 35000,
          settlement: ActivationSettlement.partialPayment,
          partialAmount: 20000,
        ),
      );

      final movements = octoberMovements();
      expect(movements, hasLength(2));
      expect(movements.first.type, FinanceMovementType.collectedOnActivation);
      expect(movements.first.amount, 20000);
      expect(movements.last.type, FinanceMovementType.debtAdded);
      expect(movements.last.amount, 15000);
    });

    test('a debt activation is one debt movement', () async {
      await activate(
        const FinanceSaleInput(
          packageName: 'باقة 35',
          salePrice: 35000,
          settlement: ActivationSettlement.fullDebt,
        ),
      );

      final movement = octoberMovements().single;
      expect(movement.type, FinanceMovementType.debtAdded);
      expect(movement.amount, 35000);
    });

    test('each later repayment and reduction is its own movement', () async {
      await activate(
        const FinanceSaleInput(
          packageName: 'باقة 45',
          salePrice: 45000,
          settlement: ActivationSettlement.fullDebt,
        ),
      );
      now = DateTime(2026, 10, 5, 10);
      await pay(10000);
      now = DateTime(2026, 10, 6, 10);
      await pay(5000);
      now = DateTime(2026, 10, 7, 10);
      await service.recordCorrection(
        operationId: nextOperation(),
        subscriber: _ali,
        amount: -3000,
        reason: 'خصم',
        createdBy: _agent,
      );

      expect(
        octoberMovements().map((movement) => (movement.type, movement.amount)),
        [
          (FinanceMovementType.debtAdded, 45000),
          (FinanceMovementType.debtRepayment, 10000),
          (FinanceMovementType.debtRepayment, 5000),
          (FinanceMovementType.debtReduced, 3000),
        ],
      );
    });

    test('a reversed payment disappears from the movements', () async {
      await activate(
        const FinanceSaleInput(
          packageName: 'باقة 45',
          salePrice: 45000,
          settlement: ActivationSettlement.fullDebt,
        ),
      );
      final payment = await pay(10000);
      await service.reverseEntry(
        operationId: nextOperation(),
        subscriber: _ali,
        entryId: payment.single.id,
        reason: 'خطأ في التسجيل',
        createdBy: _agent,
      );

      expect(octoberMovements().single.type, FinanceMovementType.debtAdded);
    });
  });

  group('monthly totals', () {
    Future<void> seedTwoMonths() async {
      await activate(
        const FinanceSaleInput(
          packageName: 'باقة 45',
          salePrice: 45000,
          settlement: ActivationSettlement.partialPayment,
          partialAmount: 20000,
        ),
      );
      now = DateTime(2026, 10, 20, 10);
      await pay(5000);
      now = DateTime(2026, 10, 21, 10);
      await service.recordCorrection(
        operationId: nextOperation(),
        subscriber: _ali,
        amount: -2000,
        reason: 'خصم',
        createdBy: _agent,
      );
      now = DateTime(2026, 11, 3, 10);
      await pay(4000);
    }

    test('totals start from zero each month while the debt stays', () async {
      await seedTwoMonths();
      final entries = store.entries['sub-1']!;

      final october = FinanceSummary.forPeriod(
        entries,
        FinancePeriod.month(DateTime(2026, 10)),
      );
      final november = FinanceSummary.forPeriod(
        entries,
        FinancePeriod.month(DateTime(2026, 11)),
      );
      final december = FinanceSummary.forPeriod(
        entries,
        FinancePeriod.month(DateTime(2026, 12)),
      );

      expect(october.collected, 25000);
      expect(october.debtAdded, 25000);
      expect(october.debtReduced, 2000);
      expect(november.collected, 4000);
      expect(november.debtAdded, 0);
      expect(november.debtReduced, 0);
      expect(december.collected, 0);
      expect(account().balance, 14000);
    });

    test('the days of a month add up to the month', () async {
      await seedTwoMonths();
      final entries = store.entries['sub-1']!;
      final month = FinanceSummary.forPeriod(
        entries,
        FinancePeriod.month(DateTime(2026, 10)),
      );

      final days = [
        for (var day = 1; day <= 31; day++)
          FinanceSummary.forPeriod(
            entries,
            FinancePeriod.day(DateTime(2026, 10, day)),
          ),
      ];
      int sum(int Function(FinanceSummary) field) =>
          days.fold(0, (total, summary) => total + field(summary));

      expect(
        sum((summary) => summary.collectedOnActivation),
        month.collectedOnActivation,
      );
      expect(sum((summary) => summary.debtRepayments), month.debtRepayments);
      expect(sum((summary) => summary.debtAdded), month.debtAdded);
      expect(sum((summary) => summary.debtReduced), month.debtReduced);
    });

    test('the last moment of a month stays in that month', () async {
      now = DateTime(2026, 10, 31, 23, 59, 59);
      await activate(
        const FinanceSaleInput(
          packageName: 'باقة 35',
          salePrice: 35000,
          settlement: ActivationSettlement.fullDebt,
        ),
      );
      final entries = store.entries['sub-1']!;

      expect(
        FinanceSummary.forPeriod(
          entries,
          FinancePeriod.month(DateTime(2026, 10)),
        ).debtAdded,
        35000,
      );
      expect(
        FinanceSummary.forPeriod(
          entries,
          FinancePeriod.month(DateTime(2026, 11)),
        ).debtAdded,
        0,
      );
    });
  });

  test('entries survive a storage round trip unchanged', () {
    final entry = FinanceEntry(
      id: 'op1_2',
      operationId: 'op1',
      subscriberId: 'sub-1',
      subscriberUser: 'ali',
      subscriberName: 'علي حسن',
      type: FinanceEntryType.subscriptionSale,
      amount: 45000,
      at: DateTime(2026, 10, 2, 10, 30),
      createdBy: _agent,
      packageName: 'باقة 45',
      saleKind: FinanceSaleKind.activation,
      settlement: ActivationSettlement.partialPayment,
      sasCost: 36000,
      receiptNumber: 412,
    );

    final decoded = FinanceEntry.fromJson(entry.toJson());

    expect(decoded.toJson(), entry.toJson());
    expect(decoded.at, entry.at);
    expect(decoded.settlement?.label, 'تسديد جزء');
  });
}
