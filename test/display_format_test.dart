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

    test('writes only the SAS-style calendar day count', () {
      // اليوم=0، غداً=1، بعد غد=2 ... (فرق التقويم، يتجاهل الساعة).
      expect(
        remainingTimeText(now.add(const Duration(hours: 7)), now),
        '0', // ينتهي اليوم
      );
      expect(
        remainingTimeText(now.add(const Duration(minutes: 20)), now),
        '0',
      );
      expect(
        remainingTimeText(now.add(const Duration(days: 1)), now),
        '1', // غداً
      );
      expect(
        remainingTimeText(now.add(const Duration(days: 2)), now),
        '2', // بعد غد
      );
      expect(
        remainingTimeText(now.add(const Duration(days: 6, hours: 5)), now),
        '6',
      );
      expect(
        remainingTimeText(now.add(const Duration(days: 29)), now),
        '29',
      );
      // ساعات تعبر منتصف الليل تُحسب يوماً تقويمياً إضافياً (ينتهي بعد 30 يوماً).
      expect(
        remainingTimeText(now.add(const Duration(days: 29, hours: 23)), now),
        '30',
      );
    });

    test('a date already in the past is a negative count', () {
      expect(
        remainingTimeText(now.subtract(const Duration(days: 1)), now),
        '-1',
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
