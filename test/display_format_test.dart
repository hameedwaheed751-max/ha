import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';

void main() {
  group('moneyText', () {
    test('groups thousands', () {
      expect(moneyText(35000), '35,000 د.ع');
      expect(moneyText(1250000), '1,250,000 د.ع');
    });

    test('leaves small amounts as they are', () {
      expect(moneyText(0), '0 د.ع');
      expect(moneyText(750), '750 د.ع');
    });

    test('rounds and keeps the sign', () {
      expect(moneyText(999.6), '1,000 د.ع');
      expect(moneyText(-5000), '-5,000 د.ع');
      expect(moneyText(-0.2), '0 د.ع');
    });
  });

  group('errorText', () {
    test('shows a state error message without its prefix', () {
      expect(errorText(StateError('رسالة')), 'رسالة');
    });

    test('explains a refused permission', () {
      expect(
        errorText(
          FirebaseException(plugin: 'database', code: 'permission-denied'),
        ),
        contains('صلاحية'),
      );
    });

    test('hides other technical errors', () {
      expect(errorText(Exception('socket closed')), isNot(contains('socket')));
    });
  });
}
