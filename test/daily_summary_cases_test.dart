import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';

final _at = DateTime(2026, 11, 1, 10);

DailyTaskEvent _event(
  String type,
  double amount, {
  String user = 'u1',
  DateTime? at,
  String category = '',
}) => DailyTaskEvent(
  type: type,
  subscriberUser: user,
  subscriberName: user,
  at: at ?? _at,
  amount: amount,
  category: category,
);

AccountingActivationRecord _sale(String user, DateTime at) =>
    AccountingActivationRecord(
      subscriberUser: user,
      subscriberName: user,
      packageName: 'basic',
      saleAmount: 35000,
      sasDeduction: 0,
      at: at,
    );

void main() {
  const entry = DailyTaskEvent.debtEntryCollectionType;

  test('every activation counts once, including one sold on full debt', () {
    final paidAt = _at.add(const Duration(minutes: 5));
    final summary = DailyTaskSummary.fromEvents(
      [
        _event('activation', 35000, user: 'paid', at: paidAt),
        _event('debt_added', 35000, user: 'debt'),
      ],
      activations: [_sale('paid', paidAt), _sale('debt', _at)],
    );

    expect(summary.activationCases, 2);
    expect(summary.activationCollected, 35000);
    expect(summary.totalCollected, 35000);
  });

  test('an old activation without a sale record still counts', () {
    final summary = DailyTaskSummary.fromEvents([_event('activation', 35000)]);

    expect(summary.activationCases, 1);
  });

  test('a repayment counts once and adds to collected repayments', () {
    final summary = DailyTaskSummary.fromEvents([
      _event('debt_payment', 5000),
      _event(entry, 10000),
      _event(entry, 20000, user: 'u2'),
    ]);

    expect(summary.debtPaymentCases, 2);
    expect(summary.debtPaymentsCollected, 35000);
    expect(summary.otherCollected, 0);
  });

  test('a paid purchase stays in the total but is not a repayment', () {
    final summary = DailyTaskSummary.fromEvents([
      _event(entry, 5000, category: DailyTaskEvent.purchaseCategory),
    ]);

    expect(summary.debtPaymentCases, 0);
    expect(summary.debtPaymentsCollected, 0);
    expect(summary.otherCollected, 5000);
    expect(summary.totalCollected, 5000);
  });

  test('a payment entered with a new subscriber is not a repayment', () {
    final summary = DailyTaskSummary.fromEvents([
      _event(DailyTaskEvent.subscriberCreatedType, 0),
      _event(entry, 35000),
    ]);

    expect(summary.debtPaymentCases, 0);
    expect(summary.otherCollected, 35000);
  });

  test('a payment entered with an amount increase is not a repayment', () {
    final summary = DailyTaskSummary.fromEvents([
      _event(DailyTaskEvent.debtEditType, 35000),
      _event(entry, 35000),
    ]);

    expect(summary.debtPaymentCases, 0);
    expect(summary.otherCollected, 35000);
  });

  test('cancelled movements are left out of cases and totals', () {
    final payment = _event('debt_payment', 5000)..cancelReason = 'خطأ';
    final summary = DailyTaskSummary.fromEvents([payment]);

    expect(summary.debtPaymentCases, 0);
    expect(summary.totalCollected, 0);
  });

  test('the day summary reads activations of that day only', () {
    AppStore.dailyTaskEvents.clear();
    AppStore.accountingActivations
      ..clear()
      ..addAll([
        _sale('today', _at),
        _sale('other', _at.subtract(const Duration(days: 1))),
      ]);
    addTearDown(AppStore.accountingActivations.clear);

    expect(AppStore.summaryOfDay(_at).activationCases, 1);
  });
}
