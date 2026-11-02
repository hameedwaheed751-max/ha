import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';
import 'package:untitled/services/app_notifications.dart';

void main() {
  final now = DateTime(2026, 11, 2, 12);

  AccountingActivationRecord activation(String user, DateTime at) =>
      AccountingActivationRecord(
        subscriberUser: user,
        subscriberName: 'علي',
        packageName: 'FIBER',
        saleAmount: 35000,
        sasDeduction: 0,
        at: at,
      );

  DailyTaskEvent event(String type, DateTime at, {String user = 'ali'}) =>
      DailyTaskEvent(
        type: type,
        subscriberUser: user,
        subscriberName: 'علي',
        at: at,
      );

  Subscriber subscriber(DateTime end, {bool disabled = false}) => Subscriber(
    user: 'hassan',
    name: 'حسن',
    phone: '',
    address: '',
    ip: '',
    type: 'basic',
    price: 0,
    startDate: end.subtract(const Duration(days: 30)),
    endDate: end,
    disabled: disabled,
  );

  List<AppNotification> build({
    List<AccountingActivationRecord> activations = const [],
    List<DailyTaskEvent> events = const [],
    List<Subscriber> subscribers = const [],
  }) => AppNotifications.build(
    activations: activations,
    events: events,
    subscribers: subscribers,
    now: now,
  );

  test('an activation shows its name and time', () {
    final at = now.subtract(const Duration(hours: 2));
    final items = build(activations: [activation('ali', at)]);

    expect(items.single.title, 'تم تفعيل المشترك علي بنجاح');
    expect(items.single.at, at);
  });

  test('a notification remembers its subscriber', () {
    expect(
      build(activations: [activation('ali', now)]).single.subscriberUser,
      'ali',
    );
    expect(
      build(
        subscribers: [subscriber(now.subtract(const Duration(hours: 1)))],
      ).single.subscriberUser,
      'hassan',
    );
  });

  test('one activation recorded twice appears once', () {
    final at = now.subtract(const Duration(hours: 2));

    expect(
      build(
        activations: [activation('ali', at)],
        events: [event('activation', at)],
      ),
      hasLength(1),
    );
  });

  test('other movements are not activations', () {
    expect(build(events: [event('debt_payment', now)]), isEmpty);
  });

  test('an expired subscription shows the moment it ended', () {
    final end = now.subtract(const Duration(hours: 5));
    final items = build(subscribers: [subscriber(end)]);

    expect(items.single.title, 'انتهى اشتراك حسن');
    expect(items.single.at, end);
  });

  test('a subscription ending later today is announced ahead', () {
    final items = build(
      subscribers: [subscriber(now.add(const Duration(hours: 3)))],
    );

    expect(items.single.title, 'ينتهي اشتراك حسن اليوم');
  });

  test('ignores tomorrow, old expiries and disabled subscribers', () {
    expect(
      build(
        subscribers: [
          subscriber(now.add(const Duration(days: 1))),
          subscriber(now.subtract(const Duration(days: 8))),
          subscriber(now.subtract(const Duration(hours: 1)), disabled: true),
        ],
      ),
      isEmpty,
    );
  });

  test('the newest item comes first', () {
    final older = now.subtract(const Duration(hours: 5));
    final newer = now.subtract(const Duration(hours: 1));
    final items = build(
      activations: [activation('ali', older)],
      subscribers: [subscriber(newer)],
    );

    expect(items.map((item) => item.at), [newer, older]);
  });

  test('unread items are the ones after the last visit', () {
    final items = build(
      activations: [
        activation('a', now.subtract(const Duration(hours: 5))),
        activation('b', now.subtract(const Duration(hours: 1))),
      ],
      subscribers: [subscriber(now.add(const Duration(hours: 1)))],
    );

    expect(AppNotifications.unreadCount(items, seenAt: null, now: now), 2);
    expect(
      AppNotifications.unreadCount(
        items,
        seenAt: now.subtract(const Duration(hours: 2)),
        now: now,
      ),
      1,
    );
  });
}
