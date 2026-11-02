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

    group('receipt', () {
      test('a paid request needs a receipt', () {
        expect(
          SubscriptionRequestService.isMissingReceipt({
            'selectedPlan': 'one_year',
            'receiptImageUrl': ' ',
          }),
          isTrue,
        );
        expect(
          SubscriptionRequestService.isMissingReceipt({
            'selectedPlan': 'one_year',
            'receiptImageUrl': 'https://x/y.jpg',
          }),
          isFalse,
        );
      });

      test('a free request needs no receipt', () {
        expect(
          SubscriptionRequestService.isMissingReceipt({
            'selectedPlan': 'free_15_days',
          }),
          isFalse,
        );
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
