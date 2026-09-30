import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:untitled/models.dart';

Subscriber _subscriber({double price = 100, double paid = 0}) {
  return Subscriber(
    user: 'u1',
    name: 'Test User',
    phone: '',
    address: '',
    ip: '',
    type: 'basic',
    price: price,
    paid: paid,
    startDate: DateTime(2026, 1, 1),
    endDate: DateTime(2026, 2, 1),
  );
}

void main() {
  setUp(() {
    AppStore.dailyTaskEvents.clear();
    AppStore.accountingActivations.clear();
  });

  test('partial payment reduces remaining automatically', () {
    final s = _subscriber(price: 100, paid: 20);

    final applied = s.applyPartialPayment(30, at: DateTime(2026, 7, 30));

    expect(applied, 30);
    expect(s.paid, 50);
    expect(s.remaining, 50);
    expect(s.payments.length, 2);
    expect(s.paymentsTotal, 50);
    expect(s.payments.last.amount, 30);
  });

  test('partial payment cannot exceed remaining', () {
    final s = _subscriber(price: 100, paid: 90);

    final applied = s.applyPartialPayment(50, at: DateTime(2026, 7, 30));

    expect(applied, 10);
    expect(s.paid, 100);
    expect(s.remaining, 0);
    expect(s.payments.length, 2);
    expect(s.paymentsTotal, 100);
    expect(s.payments.last.amount, 10);
  });

  test('setDebtAmounts clamps paid to subscription amount', () {
    final s = _subscriber(price: 120, paid: 30);

    s.setDebtAmounts(subscriptionAmount: 80, paidAmount: 150);

    expect(s.price, 80);
    expect(s.paid, 80);
    expect(s.remaining, 0);
  });

  test('registerInvoiceFromPayment stores invoice with month key', () {
    final s = _subscriber(price: 100, paid: 0);
    final at = DateTime(2026, 7, 30);
    s.paid = 40;

    final invoice = s.registerInvoiceFromPayment(
      receiptNumber: 120,
      amount: 40,
      at: at,
      note: 'فاتورة تسديد جزئي',
    );

    expect(s.invoices.length, 1);
    expect(invoice!.receiptNumber, 120);
    expect(invoice.monthKey, '2026-07');
    expect(invoice.amount, 40);
    expect(invoice.subscriptionAmountSnapshot, 100);
    expect(invoice.paidAmountSnapshot, 40);
    expect(invoice.remainingAmountSnapshot, 60);
    expect(invoice.packageSnapshot, 'basic');

    s
      ..price = 150
      ..paid = 90;
    final restored = InvoiceRecord.fromJson(invoice.toJson());
    expect(restored.subscriptionAmountSnapshot, 100);
    expect(restored.paidAmountSnapshot, 40);
    expect(restored.remainingAmountSnapshot, 60);
  });

  test('negative payment corrections do not create receipt invoices', () {
    final s = _subscriber(price: 100, paid: 0);

    final invoice = s.registerInvoiceFromPayment(
      receiptNumber: 121,
      amount: -20,
      at: DateTime(2026, 7, 30),
      note: 'تصحيح تخفيض الواصل',
    );

    expect(invoice, isNull);
    expect(s.invoices, isEmpty);
  });

  test('monthly totals are grouped by month', () {
    final s = _subscriber(price: 500, paid: 0);

    s.applyPartialPayment(100, at: DateTime(2026, 7, 1));
    s.applyPartialPayment(50, at: DateTime(2026, 7, 15));
    s.applyPartialPayment(80, at: DateTime(2026, 8, 5));

    s.registerInvoiceFromPayment(
      receiptNumber: 1,
      amount: 100,
      at: DateTime(2026, 7, 1),
    );
    s.registerInvoiceFromPayment(
      receiptNumber: 2,
      amount: 50,
      at: DateTime(2026, 7, 15),
    );
    s.registerInvoiceFromPayment(
      receiptNumber: 3,
      amount: 80,
      at: DateTime(2026, 8, 5),
    );

    expect(s.monthlyPaidTotals['2026-07'], 150);
    expect(s.monthlyPaidTotals['2026-08'], 80);
    expect(s.monthlyInvoiceTotals['2026-07'], 150);
    expect(s.monthlyInvoiceTotals['2026-08'], 80);
  });

  test('adding debt then paying part keeps all balances consistent', () {
    final s = _subscriber(price: 100, paid: 20);

    s.price += 50;
    s.normalizeDebtFields();
    final applied = s.applyPartialPayment(30, at: DateTime(2026, 8, 11));

    expect(s.price, 150);
    expect(s.paid, 50);
    expect(s.remaining, 100);
    expect(applied, 30);
  });

  test('partial subscription collection adds remaining debt to daily tasks', () {
    final s = _subscriber(price: 0, paid: 0);
    final at = DateTime(2026, 9, 29, 10);

    final adjustment = s.adjustDebtAmounts(
      subscriptionAmount: 35000,
      paidAmount: 15000,
      at: at,
    );
    final events = [
      if (adjustment.paymentDelta > 0)
        DailyTaskEvent(
          type: DailyTaskEvent.debtEntryCollectionType,
          subscriberUser: s.user,
          subscriberName: s.name,
          at: at,
          amount: adjustment.paymentDelta,
          remainingAfter: s.remaining,
        ),
      if (adjustment.addedDebt > 0)
        DailyTaskEvent(
          type: 'debt_added',
          subscriberUser: s.user,
          subscriberName: s.name,
          at: at,
          amount: adjustment.addedDebt,
          remainingAfter: s.remaining,
        ),
      DailyTaskEvent(
        type: 'debt_payment',
        subscriberUser: s.user,
        subscriberName: s.name,
        at: at.add(const Duration(hours: 1)),
        amount: 5000,
        remainingAfter: 15000,
      ),
    ];

    final debtToday = DailyTaskSummary.fromEvents(events.take(2));
    final afterRepayment = DailyTaskSummary.fromEvents(events);
    expect(adjustment.paymentDelta, 15000);
    expect(adjustment.addedDebt, 20000);
    expect(s.paid, 15000);
    expect(s.remaining, 20000);
    expect(debtToday.debtPaymentsCollected, 15000);
    expect(debtToday.debtAddedTotal, 20000);
    expect(debtToday.netDebtMovement, 20000);
    expect(afterRepayment.debtPaymentsCollected, 20000);
    expect(afterRepayment.debtAddedTotal, 20000);
    expect(afterRepayment.debtRepaymentsTotal, 5000);
    expect(afterRepayment.netDebtMovement, 15000);
  });

  test('daily summary separates added debt from collected cash', () {
    final events = <DailyTaskEvent>[
      DailyTaskEvent(
        type: 'activation',
        subscriberUser: 'u1',
        subscriberName: 'User 1',
        at: DateTime(2026, 8, 11, 9),
        amount: 25000,
      ),
      DailyTaskEvent(
        type: 'debt_payment',
        subscriberUser: 'u2',
        subscriberName: 'User 2',
        at: DateTime(2026, 8, 11, 10),
        amount: 5000,
        remainingAfter: 10000,
      ),
      DailyTaskEvent(
        type: 'debt_added',
        subscriberUser: 'u2',
        subscriberName: 'User 2',
        at: DateTime(2026, 8, 11, 11),
        amount: 7000,
        remainingAfter: 17000,
      ),
    ];

    final summary = DailyTaskSummary.fromEvents(events);

    expect(summary.activationCases, 1);
    expect(summary.debtPaymentCases, 1);
    expect(summary.activationCollected, 25000);
    expect(summary.debtPaymentsCollected, 5000);
    expect(summary.totalCollected, 30000);
    expect(summary.debtAddedTotal, 7000);
  });

  test('monthly net debt movement offsets repayments without erasing prior debt', () {
    final events = <DailyTaskEvent>[
      DailyTaskEvent(
        type: 'debt_added',
        subscriberUser: 'u1',
        subscriberName: 'User 1',
        at: DateTime(2026, 8, 31, 18),
        amount: 30000,
        remainingAfter: 30000,
      ),
      DailyTaskEvent(
        type: 'debt_added',
        subscriberUser: 'u1',
        subscriberName: 'User 1',
        at: DateTime(2026, 9, 2, 9),
        amount: 5000,
        remainingAfter: 35000,
      ),
      DailyTaskEvent(
        type: 'debt_payment',
        subscriberUser: 'u1',
        subscriberName: 'User 1',
        at: DateTime(2026, 9, 3, 10),
        amount: 10000,
        remainingAfter: 25000,
      ),
    ];

    final september = DailyTaskSummary.fromEvents(
      events.where((event) => event.at.year == 2026 && event.at.month == 9),
    );

    expect(september.debtAddedTotal, 5000);
    expect(september.debtPaymentsCollected, 10000);
    expect(september.netDebtMovement, -5000);
    expect(events.first.remainingAfter, 30000);
  });

  test('daily task history retains events from the previous month', () {
    final previousMonthEvent = DailyTaskEvent(
      type: 'debt_added',
      subscriberUser: 'u1',
      subscriberName: 'User 1',
      at: DateTime.now().subtract(const Duration(days: 35)),
      amount: 30000,
      remainingAfter: 30000,
    );
    AppStore.dailyTaskEvents.add(previousMonthEvent);

    final payload = AppStore.buildDailyTaskEventsPayload();

    expect(
      payload.values.map((event) => event['type']),
      contains('debt_added'),
    );
  });

  test('daily summary can recover a legacy zero activation amount', () {
    final event = DailyTaskEvent(
      type: 'activation',
      subscriberUser: 'u1',
      subscriberName: 'User 1',
      at: DateTime(2026, 8, 11),
      amount: 0,
    );

    final summary = DailyTaskSummary.fromEvents([
      event,
    ], amountOf: (_) => 20000);

    expect(summary.activationCollected, 20000);
    expect(summary.totalCollected, 20000);
  });

  test('fully paid activation records cash once and adds no debt', () {
    final events = DailyTaskEvent.activationSettlement(
      subscriberUser: 'u1',
      subscriberName: 'User 1',
      at: DateTime(2026, 9, 3),
      collected: 35000,
      remaining: 0,
      note: 'تفعيل',
    );

    final summary = DailyTaskSummary.fromEvents(events);

    expect(events, hasLength(1));
    expect(summary.activationCollected, 35000);
    expect(summary.debtPaymentsCollected, 0);
    expect(summary.debtAddedTotal, 0);
    expect(summary.totalCollected, 35000);
  });

  test('reactivation does not count the previous paid balance as new cash', () {
    final events = DailyTaskEvent.activationSettlement(
      subscriberUser: 'u1',
      subscriberName: 'User 1',
      at: DateTime(2026, 9, 4),
      collected: 35000,
      remaining: 0,
      note: 'إعادة تفعيل',
      isReactivation: true,
    );

    final summary = DailyTaskSummary.fromEvents(events);

    expect(summary.activationCases, 1);
    expect(summary.activationCollected, 0);
    expect(summary.totalCollected, 0);
  });

  test('reactivation does not count the previous paid balance as new cash', () {
    final events = DailyTaskEvent.activationSettlement(
      subscriberUser: 'u1',
      subscriberName: 'User 1',
      at: DateTime(2026, 9, 4),
      collected: 35000,
      remaining: 0,
      note: 'إعادة تفعيل',
      isReactivation: true,
    );

    final summary = DailyTaskSummary.fromEvents(events);

    expect(summary.activationCases, 1);
    expect(summary.activationCollected, 0);
    expect(summary.totalCollected, 0);
  });

  test('unpaid activation adds only the actual remaining debt', () {
    final events = DailyTaskEvent.activationSettlement(
      subscriberUser: 'u1',
      subscriberName: 'User 1',
      at: DateTime(2026, 9, 3),
      collected: 0,
      remaining: 35000,
      note: 'تفعيل',
    );

    final summary = DailyTaskSummary.fromEvents(events);

    expect(events, hasLength(2));
    expect(summary.activationCases, 1);
    expect(summary.activationCollected, 0);
    expect(summary.debtPaymentsCollected, 0);
    expect(summary.debtAddedTotal, 35000);
    expect(summary.totalCollected, 0);
  });

  test('activation does not add a debt balance already recorded', () {
    final subscriber = Subscriber(
      user: 'u1',
      name: 'User 1',
      phone: '',
      address: '',
      ip: '',
      type: '',
      price: 35000,
      paid: 0,
      startDate: DateTime(2026, 9, 4),
      endDate: DateTime(2026, 10, 4),
      notes: '',
      paymentDate: '',
    );
    AppStore.dailyTaskEvents.add(
      DailyTaskEvent(
        type: 'debt_added',
        subscriberUser: 'u1',
        subscriberName: 'User 1',
        at: DateTime(2026, 9, 4, 16, 19),
        amount: 35000,
        remainingAfter: 35000,
      ),
    );

    final debtAlreadyRecorded = AppStore.hasRecordedCurrentDebt(subscriber);
    final events = DailyTaskEvent.activationSettlement(
      subscriberUser: subscriber.user,
      subscriberName: subscriber.name,
      at: DateTime(2026, 9, 4, 16, 21),
      collected: subscriber.paid,
      remaining: subscriber.remaining,
      note: 'تفعيل',
      addRemainingDebtEvent: !debtAlreadyRecorded,
    );

    expect(debtAlreadyRecorded, isTrue);
    expect(events.where((event) => event.type == 'debt_added'), isEmpty);
    expect(events.where((event) => event.type == 'activation'), hasLength(1));
    expect(events.single.remainingAfter, 35000);
  });

  test('activation does not re-add debt adjusted by an earlier payment', () {
    final subscriber = Subscriber(
      user: 'u1',
      name: 'User 1',
      phone: '',
      address: '',
      ip: '',
      type: '',
      price: 35000,
      paid: 5000,
      startDate: DateTime(2026, 9, 4),
      endDate: DateTime(2026, 10, 4),
      notes: '',
      paymentDate: '',
    );
    AppStore.dailyTaskEvents.addAll([
      DailyTaskEvent(
        type: 'debt_payment',
        subscriberUser: 'u1',
        subscriberName: 'User 1',
        at: DateTime(2026, 9, 4, 16, 20),
        amount: 5000,
        remainingAfter: 30000,
      ),
      DailyTaskEvent(
        type: 'debt_added',
        subscriberUser: 'u1',
        subscriberName: 'User 1',
        at: DateTime(2026, 9, 4, 16, 19),
        amount: 35000,
        remainingAfter: 35000,
      ),
    ]);

    expect(AppStore.hasRecordedCurrentDebt(subscriber), isTrue);
  });

  test('partial activation and later payment are not double counted', () {
    final activationEvents = DailyTaskEvent.activationSettlement(
      subscriberUser: 'u1',
      subscriberName: 'User 1',
      at: DateTime(2026, 9, 3, 9),
      collected: 20000,
      remaining: 15000,
      note: 'تفعيل',
    );
    final events = [
      ...activationEvents,
      DailyTaskEvent(
        type: 'debt_payment',
        subscriberUser: 'u1',
        subscriberName: 'User 1',
        at: DateTime(2026, 9, 3, 12),
        amount: 5000,
        remainingAfter: 10000,
      ),
    ];

    final summary = DailyTaskSummary.fromEvents(events);

    expect(summary.activationCollected, 20000);
    expect(summary.debtPaymentsCollected, 5000);
    expect(summary.debtAddedTotal, 15000);
    expect(summary.totalCollected, 25000);
  });

  test('a new local subscriber has no recorded activation yet', () {
    final subscriber = _subscriber(price: 35000, paid: 35000);

    expect(subscriber.active, isTrue);
    expect(AppStore.hasRecordedActivation(subscriber), isFalse);
  });

  test('an expired subscriber with activation history can record payments', () {
    final subscriber = _subscriber(price: 35000, paid: 0)
      ..endDate = DateTime(2025, 1, 1);
    AppStore.dailyTaskEvents.add(
      DailyTaskEvent(
        type: 'activation',
        subscriberUser: subscriber.user,
        subscriberName: subscriber.name,
        at: DateTime(2025, 1, 1),
      ),
    );

    expect(subscriber.isActive, isFalse);
    expect(AppStore.hasRecordedActivation(subscriber), isTrue);
  });

  test('SAS source alone does not prove a recorded activation', () {
    final subscriber = _subscriber(price: 35000, paid: 0)..source = 'sas';

    expect(AppStore.hasRecordedActivation(subscriber), isFalse);
  });

  test('added debt is based on remaining increase, not subscription price', () {
    expect(
      DailyTaskEvent.addedDebtAmount(previousRemaining: 0, currentRemaining: 0),
      0,
    );
    expect(
      DailyTaskEvent.addedDebtAmount(
        previousRemaining: 0,
        currentRemaining: 35000,
      ),
      35000,
    );
    expect(
      DailyTaskEvent.addedDebtAmount(
        previousRemaining: 0,
        currentRemaining: 15000,
      ),
      15000,
    );
    expect(
      DailyTaskEvent.addedDebtAmount(
        previousRemaining: 35000,
        currentRemaining: 0,
      ),
      0,
    );
  });

  test('Windows debts payload keeps existing payment rows when remote is partial', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final existingPayment = PaymentRecord(
        amount: 20,
        at: DateTime(2026, 8, 1, 10),
        note: 'old payment',
      );
      final subscriber = _subscriber(price: 100, paid: 20)
        ..payments = [existingPayment];
      AppStore.subscribers
        ..clear()
        ..add(subscriber);

      AppStore.applyDebtsPayload({
        'u1': {
          'user': 'u1',
          'subscriptionAmount': 100,
          'paidAmount': 50,
          'remainingAmount': 50,
          'payments': [
            {
              'amount': 30,
              'at': DateTime(2026, 8, 2, 10).toIso8601String(),
              'note': 'new payment',
            },
          ],
        },
      });

      expect(subscriber.payments.length, 2);
      expect(subscriber.payments.map((payment) => payment.amount), [20, 30]);
      expect(subscriber.paid, 50);
      expect(subscriber.remaining, 50);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
