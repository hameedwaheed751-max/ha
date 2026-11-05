import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';

void main() {
  final at = DateTime(2026, 11, 5, 10, 30);

  AccountingActivationRecord record(String user, {DateTime? when}) =>
      AccountingActivationRecord(
        subscriberUser: user,
        subscriberName: 'name $user',
        packageName: 'Fiber 35',
        saleAmount: 35000,
        sasDeduction: 29000,
        at: when ?? at,
      );

  List<DailyTaskEvent> settle(String user, double collected, double debt) =>
      DailyTaskEvent.activationSettlement(
        subscriberUser: user,
        subscriberName: 'name $user',
        at: at,
        collected: collected,
        remaining: debt,
        note: 'تفعيل',
      );

  test('each activation gets its status from the same daily-task moment', () {
    final records = [
      record('paid'),
      record('part'),
      record('debt'),
      record('none'),
    ];
    final result = ActivationSettlement.of(records, [
      ...settle('paid', 35000, 0),
      ...settle('part', 10000, 25000),
      ...settle('debt', 0, 35000),
      // تسديد لاحق في وقت آخر لا يغيّر حالة التفعيل.
      DailyTaskEvent(
        type: 'debt_payment',
        subscriberUser: 'debt',
        subscriberName: 'name debt',
        at: at.add(const Duration(days: 1)),
        amount: 5000,
        remainingAfter: 30000,
        note: '',
      ),
    ]);

    expect(result[records[0]]!.status, ActivationPaymentStatus.paid);
    expect(result[records[1]]!.status, ActivationPaymentStatus.partial);
    expect(result[records[1]]!.collected, 10000);
    expect(result[records[1]]!.debt, 25000);
    expect(result[records[2]]!.status, ActivationPaymentStatus.debt);
    expect(result[records[3]]!.status, ActivationPaymentStatus.unknown);
  });

  test('events from a different moment are not matched', () {
    final late = record('paid', when: at.add(const Duration(seconds: 1)));
    final result = ActivationSettlement.of([late], settle('paid', 35000, 0));
    expect(result[late]!.status, ActivationPaymentStatus.unknown);
  });
}
