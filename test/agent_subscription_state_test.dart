import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';

void main() {
  final now = DateTime(2026, 11, 2, 12);

  tearDown(() {
    AppStore.subscriptionEndsAt = null;
    AppStore.subscriptionStatus = 'inactive';
  });

  group('renewal notice', () {
    String? noticeFor(Duration remaining) {
      AppStore.subscriptionEndsAt = now.add(remaining);
      return AppStore.renewalNotice(now);
    }

    test('stays quiet more than seven days before the end', () {
      expect(noticeFor(const Duration(days: 8)), isNull);
    });

    test('counts the days during the last week', () {
      expect(noticeFor(const Duration(days: 7)), contains('7'));
      expect(noticeFor(const Duration(days: 3)), contains('3'));
    });

    test('warns on the last day', () {
      expect(noticeFor(const Duration(hours: 5)), contains('يوم واحد'));
    });

    test('says nothing after the end or without a subscription', () {
      expect(noticeFor(const Duration(hours: -1)), isNull);
      AppStore.subscriptionEndsAt = null;
      expect(AppStore.renewalNotice(now), isNull);
    });
  });

  group('blocked subscription', () {
    test('an active subscription is not blocked', () {
      AppStore.subscriptionStatus = 'active';

      expect(AppStore.isSubscriptionBlocked, isFalse);
    });

    test('an expired subscription is blocked even offline', () {
      AppStore.subscriptionStatus = 'expired';

      expect(AppStore.isSubscriptionBlocked, isTrue);
    });

    test('an unread subscription does not lock the agent out', () {
      AppStore.subscriptionStatus = 'inactive';

      expect(AppStore.isSubscriptionBlocked, isFalse);
    });
  });
}
