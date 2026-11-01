import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';

const _user = 'u1';

Subscriber _subscriber({required double price, required double paid}) {
  final now = DateTime.now();
  return Subscriber(
    user: _user,
    name: 'Test User',
    phone: '',
    address: '',
    ip: '',
    type: 'basic',
    price: price,
    paid: paid,
    startDate: now,
    endDate: now.add(const Duration(days: 30)),
    billingMonthKey: Subscriber.monthKeyOf(now),
  );
}

DailyTaskEvent _event(
  String type,
  double amount,
  DateTime at, {
  String? note,
}) => DailyTaskEvent(
  type: type,
  subscriberUser: _user,
  subscriberName: 'Test User',
  at: at,
  amount: amount,
  note: note ?? '',
);

AccountingActivationRecord _sale(double amount, DateTime at) =>
    AccountingActivationRecord(
      subscriberUser: _user,
      subscriberName: 'Test User',
      packageName: 'basic',
      saleAmount: amount,
      sasDeduction: 0,
      at: at,
    );

void main() {
  final recordedAt = DateTime.now();

  setUp(() {
    AppStore.dailyTaskEvents.clear();
    AppStore.accountingActivations.clear();
  });

  test('a fully paid amount recorded before activation is found', () {
    final s = _subscriber(price: 35000, paid: 35000);
    AppStore.dailyTaskEvents.add(
      _event(DailyTaskEvent.debtEntryCollectionType, 35000, recordedAt),
    );

    expect(AppStore.recordedActivationAmount(s), 35000);
  });

  test('merging leaves one movement and keeps the amounts', () {
    final s = _subscriber(price: 35000, paid: 35000);
    final collection = _event(
      DailyTaskEvent.debtEntryCollectionType,
      35000,
      recordedAt,
    );
    final edit = _event(DailyTaskEvent.debtEditType, 35000, recordedAt);
    AppStore.dailyTaskEvents.addAll([collection, edit]);

    final merged = AppStore.mergeRecordedSaleIntoActivation(s);
    final movements = [
      ...AppStore.dailyTaskEvents,
      ...DailyTaskEvent.activationSettlement(
        subscriberUser: _user,
        subscriberName: 'Test User',
        at: recordedAt.add(const Duration(minutes: 1)),
        collected: merged,
        remaining: s.remaining,
        note: 'تفعيل',
        addRemainingDebtEvent: false,
      ),
    ];
    final summary = DailyTaskSummary.fromEvents(movements);

    expect(merged, 35000);
    expect(s.price, 35000);
    expect(s.paid, 35000);
    expect(collection.isMergedIntoActivation, isTrue);
    expect(edit.isMergedIntoActivation, isTrue);
    expect(movements.where((e) => !e.isCancelled), hasLength(1));
    expect(summary.activationCases, 1);
    expect(summary.activationCollected, 35000);
    expect(summary.debtPaymentCases, 0);
    expect(summary.totalCollected, 35000);
  });

  test('an older synced copy cannot bring a merged movement back', () {
    final s = _subscriber(price: 35000, paid: 35000);
    final collection = _event(
      DailyTaskEvent.debtEntryCollectionType,
      35000,
      recordedAt,
    );
    AppStore.dailyTaskEvents.add(collection);
    final stale = collection.toJson();

    AppStore.mergeRecordedSaleIntoActivation(s);
    AppStore.applyDailyTaskEventsPayload({'stale': stale});

    expect(AppStore.dailyTaskEvents.single.isMergedIntoActivation, isTrue);
  });

  test('a repayment of an activation sold on debt is not reused', () {
    final s = _subscriber(price: 35000, paid: 35000);
    AppStore.accountingActivations.add(_sale(35000, recordedAt));
    AppStore.dailyTaskEvents.add(
      _event(DailyTaskEvent.debtEntryCollectionType, 35000, recordedAt),
    );

    expect(AppStore.recordedActivationAmount(s), 0);
  });

  test('an unpaid remainder keeps the normal activation flow', () {
    final s = _subscriber(price: 35000, paid: 10000);
    AppStore.dailyTaskEvents.add(
      _event(DailyTaskEvent.debtEntryCollectionType, 10000, recordedAt),
    );

    expect(AppStore.recordedActivationAmount(s), 0);
  });

  test('a paid purchase is not treated as a subscription amount', () {
    final s = _subscriber(price: 0, paid: 0);
    AppStore.dailyTaskEvents.add(
      DailyTaskEvent(
        type: DailyTaskEvent.debtEntryCollectionType,
        subscriberUser: _user,
        subscriberName: 'Test User',
        at: recordedAt,
        amount: 5000,
        category: DailyTaskEvent.purchaseCategory,
      ),
    );

    expect(AppStore.recordedActivationAmount(s), 0);
  });

  test('a paid amount without matching movements is left alone', () {
    final s = _subscriber(price: 35000, paid: 35000);

    expect(AppStore.recordedActivationAmount(s), 0);
    expect(AppStore.mergeRecordedSaleIntoActivation(s), 0);
  });
}
