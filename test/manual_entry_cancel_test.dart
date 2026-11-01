import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:untitled/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final enteredAt = DateTime(2026, 11, 2, 10);
  final later = DateTime(2026, 11, 3, 10);

  Subscriber subscriber({double price = 0, double carriedDebt = 0}) =>
      Subscriber(
        user: 'u1',
        name: 'Test User',
        phone: '',
        address: '',
        ip: '',
        type: 'basic',
        price: price,
        carriedDebt: carriedDebt,
        billingMonthKey: '2026-11',
        startDate: DateTime(2026, 11, 1),
        endDate: DateTime(2026, 12, 1),
      );

  DailyTaskEvent event(
    String type,
    double amount, {
    String category = DailyTaskEvent.purchaseCategory,
    DateTime? at,
  }) => DailyTaskEvent(
    type: type,
    subscriberUser: 'u1',
    subscriberName: 'Test User',
    at: at ?? enteredAt,
    amount: amount,
    note: 'راوتر',
    category: category,
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppStore.subscribers.clear();
    AppStore.dailyTaskEvents.clear();
  });

  tearDown(() {
    AppStore.subscribers.clear();
    AppStore.dailyTaskEvents.clear();
  });

  group('cancelling a manual entry', () {
    test('an unpaid amount is removed from the debt and stays visible', () async {
      final s = subscriber(carriedDebt: 15000);
      AppStore.subscribers.add(s);
      final entry = event('debt_added', 15000);
      AppStore.dailyTaskEvents.add(entry);

      await AppStore.cancelManualEntry(
        s,
        at: enteredAt,
        category: DailyTaskEvent.purchaseCategory,
        reason: 'خطأ في المبلغ',
        now: later,
      );

      expect(s.remaining, 0);
      expect(AppStore.dailyTaskEvents, contains(entry));
      expect(entry.isCancelled, isTrue);
      expect(entry.cancelReason, 'خطأ في المبلغ');
    });

    test('a partly paid purchase is cancelled as one operation', () async {
      final s = subscriber(carriedDebt: 10000);
      s.payments.add(PaymentRecord(amount: 5000, at: enteredAt));
      s.invoices.add(
        InvoiceRecord(
          receiptNumber: 7,
          amount: 5000,
          at: enteredAt,
          monthKey: '2026-11',
        ),
      );
      AppStore.subscribers.add(s);
      final unpaid = event('debt_added', 10000);
      final paid = event(DailyTaskEvent.debtEntryCollectionType, 5000);
      AppStore.dailyTaskEvents.addAll([unpaid, paid]);

      await AppStore.cancelManualEntry(
        s,
        at: enteredAt,
        category: DailyTaskEvent.purchaseCategory,
        reason: 'سجلت لمشترك آخر',
        now: later,
      );

      expect(s.remaining, 0);
      expect(unpaid.isCancelled && paid.isCancelled, isTrue);
      expect(s.invoices.single.cancelled, isTrue);
      expect(s.invoicesTotal, 0);
      expect(s.paymentsTotal, 0);
    });

    test('an amount already repaid cannot be cancelled', () async {
      final s = subscriber(carriedDebt: 5000);
      AppStore.subscribers.add(s);
      final entry = event('debt_added', 15000);
      AppStore.dailyTaskEvents.add(entry);

      await expectLater(
        AppStore.cancelManualEntry(
          s,
          at: enteredAt,
          category: DailyTaskEvent.purchaseCategory,
          reason: 'خطأ',
          now: later,
        ),
        throwsStateError,
      );

      expect(s.remaining, 5000);
      expect(entry.isCancelled, isFalse);
    });

    test('an older cloud copy cannot undo a cancellation', () async {
      final s = subscriber(carriedDebt: 15000);
      AppStore.subscribers.add(s);
      final entry = event('debt_added', 15000);
      AppStore.dailyTaskEvents.add(entry);
      final olderCloudCopy = AppStore.buildDailyTaskEventsPayload();

      await AppStore.cancelManualEntry(
        s,
        at: enteredAt,
        category: DailyTaskEvent.purchaseCategory,
        reason: 'خطأ في المبلغ',
        now: later,
      );
      AppStore.applyDailyTaskEventsPayload(olderCloudCopy);

      final merged = AppStore.dailyTaskEvents.single;
      expect(merged.isCancelled, isTrue);
      expect(merged.cancelReason, 'خطأ في المبلغ');
    });

    test('a subscriber with an earlier debt keeps it after cancelling', () async {
      final s = subscriber(carriedDebt: 20000);
      AppStore.subscribers.add(s);
      s.carriedDebt += 15000;
      s.applyPayment(5000, at: enteredAt);
      s.invoices.add(
        InvoiceRecord(
          receiptNumber: 3,
          amount: 5000,
          at: enteredAt,
          monthKey: '2026-11',
        ),
      );
      AppStore.dailyTaskEvents.addAll([
        event('debt_added', 10000),
        event(DailyTaskEvent.debtEntryCollectionType, 5000),
      ]);
      expect(s.remaining, 30000);

      await AppStore.cancelManualEntry(
        s,
        at: enteredAt,
        category: DailyTaskEvent.purchaseCategory,
        reason: 'خطأ',
        now: later,
      );

      expect(s.remaining, 20000);
    });

    test('a reason is required and an entry cancels only once', () async {
      final s = subscriber(carriedDebt: 15000);
      AppStore.subscribers.add(s);
      AppStore.dailyTaskEvents.add(event('debt_added', 15000));

      Future<void> cancel(String reason) => AppStore.cancelManualEntry(
        s,
        at: enteredAt,
        category: DailyTaskEvent.purchaseCategory,
        reason: reason,
        now: later,
      );

      await expectLater(cancel('  '), throwsStateError);
      await cancel('خطأ');
      await expectLater(cancel('مرة ثانية'), throwsStateError);
      expect(s.remaining, 0);
    });

    test('cancelled movements leave daily and monthly totals', () {
      final cancelled = event('debt_added', 15000)..cancelReason = 'خطأ';
      final kept = event(
        'debt_added',
        20000,
        category: DailyTaskEvent.manualDebtCategory,
      );

      final summary = DailyTaskSummary.fromEvents([cancelled, kept]);

      expect(summary.debtAddedTotal, 20000);
      expect(DailyTaskSummary.outstandingAddedDebt([cancelled, kept]), 20000);
    });

    test('the cancellation survives saving and loading', () {
      final entry = DailyTaskEvent.fromJson(
        (event('debt_added', 15000)..cancelReason = 'خطأ').toJson(),
      );
      final invoice = InvoiceRecord.fromJson(
        InvoiceRecord(
          receiptNumber: 1,
          amount: 5000,
          at: enteredAt,
          monthKey: '2026-11',
          cancelled: true,
        ).toJson(),
      );

      expect(entry.cancelReason, 'خطأ');
      expect(invoice.cancelled, isTrue);
    });
  });

  group('cancelling a payment', () {
    Subscriber paidPartly() {
      final s = subscriber(price: 35000, carriedDebt: 20000);
      final allocation = s.applyPayment(25000, at: enteredAt);
      s.invoices.add(
        InvoiceRecord(
          receiptNumber: 9,
          amount: 25000,
          at: enteredAt,
          monthKey: '2026-11',
        ),
      );
      AppStore.subscribers.add(s);
      AppStore.dailyTaskEvents.addAll([
        event(
          'debt_payment',
          allocation.appliedToCarriedDebt,
          category: '',
        ),
        event(
          DailyTaskEvent.debtEntryCollectionType,
          allocation.appliedToCurrentCharge,
          category: '',
        ),
      ]);
      return s;
    }

    test('the money returns to the debts it had paid', () async {
      final s = paidPartly();
      expect(s.remaining, 30000);

      final total = await AppStore.cancelPayment(
        s,
        at: enteredAt,
        reason: 'سجلت بالخطأ',
        now: later,
      );

      expect(total, 25000);
      expect(s.remaining, 55000);
      expect(s.carriedDebt, 20000);
      expect(s.paid, 0);
      expect(s.paymentsTotal, 0);
      expect(s.invoices.single.cancelled, isTrue);
      expect(s.invoicesTotal, 0);
      expect(
        AppStore.dailyTaskEvents.every((entry) => entry.isCancelled),
        isTrue,
      );
    });

    test('a cancelled payment leaves the totals and stays listed', () async {
      final s = paidPartly();
      await AppStore.cancelPayment(s, at: enteredAt, reason: 'خطأ', now: later);

      final summary = DailyTaskSummary.fromEvents(AppStore.dailyTaskEvents);

      expect(summary.totalCollected, 0);
      expect(AppStore.dailyTaskEvents, hasLength(2));
    });

    test('a payment from an earlier month returns as carried debt', () async {
      final s = paidPartly();

      await AppStore.cancelPayment(
        s,
        at: enteredAt,
        reason: 'خطأ',
        now: DateTime(2026, 12, 5),
      );

      expect(s.billingMonthKey, '2026-12');
      expect(s.remaining, 55000);
      expect(s.paid, 0);
    });

    test('a payment can only be cancelled once', () async {
      final s = paidPartly();
      await AppStore.cancelPayment(s, at: enteredAt, reason: 'خطأ', now: later);

      expect(AppStore.canCancelPayment(s, AppStore.dailyTaskEvents.first), isFalse);
      await expectLater(
        AppStore.cancelPayment(s, at: enteredAt, reason: 'ثانية', now: later),
        throwsStateError,
      );
      expect(s.remaining, 55000);
    });

    test('a reason is required', () async {
      final s = paidPartly();
      await expectLater(
        AppStore.cancelPayment(s, at: enteredAt, reason: ' ', now: later),
        throwsStateError,
      );
      expect(s.remaining, 30000);
    });

    test('cash entered with a new amount is not a standalone payment', () {
      final s = subscriber(price: 35000);
      s.payments.add(PaymentRecord(amount: 15000, at: enteredAt));
      final collected = event(
        DailyTaskEvent.debtEntryCollectionType,
        15000,
        category: '',
      );
      AppStore.subscribers.add(s);
      AppStore.dailyTaskEvents.addAll([
        collected,
        event('debt_added', 20000, category: ''),
      ]);

      expect(AppStore.canCancelPayment(s, collected), isFalse);
    });

    test('a paid purchase is cancelled from its own list, not here', () {
      final s = subscriber();
      s.payments.add(PaymentRecord(amount: 5000, at: enteredAt));
      final collected = event(DailyTaskEvent.debtEntryCollectionType, 5000);
      AppStore.subscribers.add(s);
      AppStore.dailyTaskEvents.add(collected);

      expect(AppStore.canCancelPayment(s, collected), isFalse);
    });
  });

  group('debt age and source', () {
    test('the age comes from the oldest amount still unpaid', () {
      final s = subscriber(price: 30000);
      AppStore.dailyTaskEvents.addAll([
        event(
          'debt_added',
          20000,
          category: '',
          at: DateTime(2026, 10, 1),
        ),
        event('debt_added', 25000, category: '', at: DateTime(2026, 10, 20)),
        event('debt_added', 10000, at: DateTime(2026, 11, 1)),
      ]);

      final breakdown = AppStore.debtBreakdown(s);

      expect(breakdown.since, DateTime(2026, 10, 20));
      expect(breakdown.hasSubscription, isTrue);
      expect(breakdown.hasPurchases, isTrue);
    });

    test('a debt from purchases alone is shown as purchases', () {
      final s = subscriber(carriedDebt: 15000);
      AppStore.dailyTaskEvents.add(event('debt_added', 15000));

      final breakdown = AppStore.debtBreakdown(s);

      expect(breakdown.hasPurchases, isTrue);
      expect(breakdown.hasSubscription, isFalse);
    });

    test('cancelled amounts do not count', () {
      final s = subscriber(price: 10000);
      AppStore.dailyTaskEvents.addAll([
        event('debt_added', 5000)..cancelReason = 'خطأ',
        event('debt_added', 10000, category: '', at: later),
      ]);

      final breakdown = AppStore.debtBreakdown(s);

      expect(breakdown.since, later);
      expect(breakdown.hasPurchases, isFalse);
    });

    test('a debt with no recorded movement falls back to subscription', () {
      final breakdown = AppStore.debtBreakdown(subscriber(price: 10000));

      expect(breakdown.since, isNull);
      expect(breakdown.hasSubscription, isTrue);
    });
  });
}
