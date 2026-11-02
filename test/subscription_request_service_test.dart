import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/services/payment_request_service.dart';
import 'package:untitled/services/subscription_request_service.dart';

void main() {
  group('SubscriptionRequestService', () {
    test('trial and paid plans return expected labels and durations', () {
      expect(SubscriptionRequestService.isTrialPlan('trial'), isTrue);
      expect(SubscriptionRequestService.planLabel('3m'), '3 أشهر');

      final start = DateTime(2024, 1, 1);
      final end = SubscriptionRequestService.endDateForPlan('3m', from: start);
      expect(end, DateTime(2024, 4, 1));
    });

    group('review claim', () {
      final now = DateTime.utc(2026, 11, 2, 12);
      bool isOpen(Map<String, dynamic> request) =>
          SubscriptionRequestService.isOpenForReview(request, now: now);

      test('a pending request is open', () {
        expect(isOpen({'status': 'pending'}), isTrue);
      });

      test('a fresh claim stays closed until its timeout passes', () {
        final fresh = now.subtract(const Duration(minutes: 1));
        final stale = now.subtract(const Duration(minutes: 2));

        expect(
          isOpen({
            'status': 'reviewing',
            'reviewedAt': fresh.toIso8601String(),
          }),
          isFalse,
        );
        expect(
          isOpen({
            'status': 'reviewing',
            'reviewedAt': stale.toIso8601String(),
          }),
          isTrue,
        );
      });

      test('a claim with no time can still be reviewed', () {
        expect(isOpen({'status': 'reviewing'}), isTrue);
      });

      test('decided requests are closed', () {
        expect(isOpen({'status': 'approved'}), isFalse);
        expect(isOpen({'status': 'rejected'}), isFalse);
      });
    });

    group('deleting a request', () {
      test('an approved request is the payment record and stays', () {
        expect(
          SubscriptionRequestService.canDelete({'status': 'approved'}),
          isFalse,
        );
      });

      test('pending and rejected requests can be deleted', () {
        expect(
          SubscriptionRequestService.canDelete({'status': 'pending'}),
          isTrue,
        );
        expect(
          SubscriptionRequestService.canDelete({'status': 'rejected'}),
          isTrue,
        );
      });

      test('a request being approved right now cannot be deleted', () {
        expect(
          SubscriptionRequestService.canDelete({
            'status': 'reviewing',
            'reviewedAt': DateTime.now().toIso8601String(),
          }),
          isFalse,
        );
      });
    });

    group('administrator subscription changes', () {
      final now = DateTime.utc(2026, 11, 2);

      test('a plan change keeps the start date and recalculates the end', () {
        final changed = SubscriptionRequestService.subscriptionWithPlan(
          {
            'plan': 'three_months',
            'status': 'active',
            'startDate': DateTime.utc(2026, 10, 1).toIso8601String(),
            'endDate': DateTime.utc(2027, 1, 1).toIso8601String(),
            'lastPaymentId': 'r1',
          },
          plan: 'one_year',
          now: now,
        );

        expect(changed['plan'], 'one_year');
        expect(changed['status'], 'active');
        expect(changed['endDate'], DateTime.utc(2027, 10, 1).toIso8601String());
        expect(changed['lastPaymentId'], 'r1');
      });

      test('a free trial with numeric dates can move to a paid plan', () {
        final changed = SubscriptionRequestService.subscriptionWithPlan(
          {
            'plan': 'free_15_days',
            'status': 'active',
            'startDate': DateTime.utc(2026, 11, 1).millisecondsSinceEpoch,
            'endDate': DateTime.utc(2026, 11, 16).millisecondsSinceEpoch,
          },
          plan: 'three_months',
          now: now,
        );

        expect(
          changed['startDate'],
          DateTime.utc(2026, 11, 1).toIso8601String(),
        );
        expect(changed['endDate'], DateTime.utc(2027, 2, 1).toIso8601String());
      });

      test('a shorter plan that already ended marks it expired', () {
        final changed = SubscriptionRequestService.subscriptionWithPlan(
          {'startDate': DateTime.utc(2026, 1, 1).toIso8601String()},
          plan: 'three_months',
          now: now,
        );

        expect(changed['status'], 'expired');
      });

      test('an extension adds days after the remaining period', () {
        final extended = SubscriptionRequestService.extendedSubscription(
          {
            'status': 'active',
            'startDate': DateTime.utc(2026, 11, 1).toIso8601String(),
            'endDate': DateTime.utc(2026, 11, 12).toIso8601String(),
          },
          days: 10,
          now: now,
        );

        expect(
          extended['endDate'],
          DateTime.utc(2026, 11, 22).toIso8601String(),
        );
        expect(
          extended['startDate'],
          DateTime.utc(2026, 11, 1).toIso8601String(),
        );
        expect(extended['durationDays'], 21);
      });

      test('an extension of an ended subscription starts today', () {
        final extended = SubscriptionRequestService.extendedSubscription(
          {
            'status': 'expired',
            'startDate': DateTime.utc(2026, 1, 1).toIso8601String(),
            'endDate': DateTime.utc(2026, 4, 1).toIso8601String(),
          },
          days: 30,
          now: now,
        );

        expect(extended['status'], 'active');
        expect(extended['startDate'], now.toIso8601String());
        expect(
          extended['endDate'],
          DateTime.utc(2026, 12, 2).toIso8601String(),
        );
        expect(extended['durationDays'], 30);
      });
    });

    group('subscription start', () {
      final now = DateTime.utc(2026, 11, 2);
      final later = DateTime.utc(2026, 11, 12);

      test('keeps the remaining days of an active subscription', () {
        expect(
          SubscriptionRequestService.subscriptionStartDate(
            existing: {'status': 'active', 'endDate': later.toIso8601String()},
            now: now,
          ),
          later,
        );
      });

      test('reads the numeric end date of a free trial', () {
        expect(
          SubscriptionRequestService.subscriptionStartDate(
            existing: {
              'status': 'active',
              'endDate': later.millisecondsSinceEpoch,
            },
            now: now,
          ),
          later,
        );
      });

      test('starts now when nothing is left to keep', () {
        final past = DateTime.utc(2026, 10, 1).toIso8601String();
        DateTime startFrom(Object? existing) =>
            SubscriptionRequestService.subscriptionStartDate(
              existing: existing,
              now: now,
            );

        expect(startFrom(null), now);
        expect(startFrom({'status': 'active', 'endDate': past}), now);
        expect(
          startFrom({'status': 'expired', 'endDate': later.toIso8601String()}),
          now,
        );
      });
    });
  });

  group('open request lookup', () {
    test('finds a waiting request and whether it has a receipt', () {
      final open = PaymentRequestService.openRequestIn({
        'old': {'uid': 'u1', 'status': 'rejected'},
        'r1': {'uid': 'u1', 'status': 'pending', 'receiptImageUrl': ''},
      }, 'u1');

      expect(open?.requestId, 'r1');
      expect(open?.hasReceipt, isFalse);
    });

    test('a request held for review still counts as waiting', () {
      final open = PaymentRequestService.openRequestIn({
        'r1': {'uid': 'u1', 'status': 'reviewing', 'receiptImageUrl': 'x'},
      }, 'u1');

      expect(open?.hasReceipt, isTrue);
    });

    test('ignores decided requests and other accounts', () {
      expect(
        PaymentRequestService.openRequestIn({
          'r1': {'uid': 'u1', 'status': 'approved'},
          'r2': {'uid': 'u2', 'status': 'pending'},
        }, 'u1'),
        isNull,
      );
      expect(PaymentRequestService.openRequestIn(null, 'u1'), isNull);
    });
  });
}
