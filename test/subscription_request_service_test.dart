import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/services/subscription_request_service.dart';

void main() {
  group('SubscriptionRequestService', () {
    test('trial and paid plans return expected labels and durations', () {
      expect(SubscriptionRequestService.isTrialPlan('trial'), isTrue);
      expect(SubscriptionRequestService.planLabel('3m'), '3 أشهر');
      expect(SubscriptionRequestService.planPrice('6m'), '50000');

      final start = DateTime(2024, 1, 1);
      final end = SubscriptionRequestService.endDateForPlan('3m', from: start);
      expect(end, DateTime(2024, 4, 1));
    });
  });
}
