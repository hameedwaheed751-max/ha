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

  group('remainingTimeText', () {
    final now = DateTime(2026, 11, 2, 10);

    test('shows days and hours', () {
      expect(
        remainingTimeText(now.add(const Duration(days: 6, hours: 5)), now),
        '6 أيام و5 ساعات',
      );
      expect(
        remainingTimeText(now.add(const Duration(days: 1, hours: 2)), now),
        'يوم وساعتان',
      );
      expect(
        remainingTimeText(now.add(const Duration(days: 29, hours: 23)), now),
        '29 يوم و23 ساعة',
      );
    });

    test('drops the empty part', () {
      expect(
        remainingTimeText(now.add(const Duration(days: 3)), now),
        '3 أيام',
      );
      expect(
        remainingTimeText(now.add(const Duration(hours: 7)), now),
        '7 ساعات',
      );
      expect(
        remainingTimeText(now.add(const Duration(minutes: 20)), now),
        'أقل من ساعة',
      );
    });
  });

  group('endsWithinDays', () {
    final now = DateTime(2026, 11, 2, 10);
    Subscriber endingAt(DateTime end) => Subscriber(
      user: 'u',
      name: 'n',
      phone: '',
      address: '',
      ip: '',
      type: '',
      price: 0,
      startDate: now,
      endDate: end,
    );

    test('counts hours past the limit as outside it', () {
      final inside = endingAt(now.add(const Duration(days: 3)));
      final outside = endingAt(now.add(const Duration(days: 3, hours: 1)));
      final past = endingAt(now.subtract(const Duration(hours: 1)));

      expect(inside.endsWithinDays(3, now), isTrue);
      expect(outside.endsWithinDays(3, now), isFalse);
      expect(past.endsWithinDays(3, now), isFalse);
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
