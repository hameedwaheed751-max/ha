import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';

void main() {
  group('Subscriber debt target calculation', () {
    test('uses the total price minus partial payment when no direct target is given', () {
      final target = Subscriber.resolveDebtTargetPaid(
        price: 35000,
        currentPaid: 30000,
        partialAmount: 5000,
      );

      expect(target, 30000);
    });

    test('prefers an explicit direct target over the partial payment input', () {
      final target = Subscriber.resolveDebtTargetPaid(
        price: 35000,
        currentPaid: 30000,
        partialAmount: 5000,
        directTargetPaid: 25000,
      );

      expect(target, 25000);
    });
  });
}
