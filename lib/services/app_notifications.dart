import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';

enum AppNotificationType { activated, expired, expiresToday }

class AppNotification {
  const AppNotification({
    required this.type,
    required this.subscriberName,
    required this.subscriberUser,
    required this.at,
  });

  final AppNotificationType type;
  final String subscriberName;
  final String subscriberUser;
  final DateTime at;

  String get title => switch (type) {
    AppNotificationType.activated => 'تم تفعيل المشترك $subscriberName بنجاح',
    AppNotificationType.expired => 'انتهى اشتراك $subscriberName',
    AppNotificationType.expiresToday => 'ينتهي اشتراك $subscriberName اليوم',
  };
}

/// تُبنى من التفعيلات المسجلة وتواريخ انتهاء المشتركين، فلا تحتاج إلى تخزين
/// خاص، ويختفي انتهاء المشترك تلقائياً إذا جُدد اشتراكه.
class AppNotifications {
  static const Duration window = Duration(days: 7);

  static List<AppNotification> build({
    required Iterable<AccountingActivationRecord> activations,
    required Iterable<DailyTaskEvent> events,
    required Iterable<Subscriber> subscribers,
    required DateTime now,
  }) {
    final from = now.subtract(window);
    bool isRecent(DateTime at) => at.isAfter(from) && !at.isAfter(now);
    String activationKey(String user, String name, DateTime at) {
      final subscriber = user.trim().toLowerCase().isNotEmpty
          ? user.trim().toLowerCase()
          : name.trim().toLowerCase();
      return '$subscriber|${at.toUtc().microsecondsSinceEpoch}';
    }

    final activated = <String, AppNotification>{};
    void addActivation(String user, String name, DateTime at) {
      if (!isRecent(at)) return;
      activated.putIfAbsent(
        activationKey(user, name, at),
        () => AppNotification(
          type: AppNotificationType.activated,
          subscriberName: name.trim().isNotEmpty ? name.trim() : user.trim(),
          subscriberUser: user.trim(),
          at: at,
        ),
      );
    }

    for (final record in activations) {
      addActivation(record.subscriberUser, record.subscriberName, record.at);
    }
    for (final event in events) {
      if (event.type != 'activation' || event.isCancelled) continue;
      addActivation(event.subscriberUser, event.subscriberName, event.at);
    }

    final items = activated.values.toList();
    for (final subscriber in subscribers) {
      if (subscriber.disabled) continue;
      final end = subscriber.endDate;
      final name = subscriber.name.trim().isNotEmpty
          ? subscriber.name.trim()
          : subscriber.user.trim();
      if (isRecent(end)) {
        items.add(
          AppNotification(
            type: AppNotificationType.expired,
            subscriberName: name,
            subscriberUser: subscriber.user.trim(),
            at: end,
          ),
        );
      } else if (end.isAfter(now) && AppStore.isSameDay(end, now)) {
        items.add(
          AppNotification(
            type: AppNotificationType.expiresToday,
            subscriberName: name,
            subscriberUser: subscriber.user.trim(),
            at: end,
          ),
        );
      }
    }
    items.sort((a, b) => b.at.compareTo(a.at));
    return items;
  }

  static List<AppNotification> current({DateTime? now}) => build(
    activations: AppStore.accountingActivations,
    events: AppStore.dailyTaskEvents,
    subscribers: AppStore.subscribers,
    now: now ?? DateTime.now(),
  );

  /// الانتهاء القادم اليوم تنبيه مسبق، فلا يُعد غير مقروء قبل وقوعه.
  static int unreadCount(
    Iterable<AppNotification> items, {
    required DateTime? seenAt,
    required DateTime now,
  }) => items
      .where(
        (item) =>
            !item.at.isAfter(now) &&
            (seenAt == null || item.at.isAfter(seenAt)),
      )
      .length;

  static String _seenKey(String uid) => 'appNotificationsSeenAt:$uid';

  static Future<DateTime?> loadSeenAt(String uid) async {
    final preferences = await SharedPreferences.getInstance();
    final millis = preferences.getInt(_seenKey(uid));
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  static Future<void> markSeen(String uid, DateTime at) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(_seenKey(uid), at.millisecondsSinceEpoch);
  }
}
