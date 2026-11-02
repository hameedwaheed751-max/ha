import 'package:flutter/material.dart';

import '../models.dart';
import '../services/app_notifications.dart';
import 'subscriber_details_screen.dart';
import 'subscribers_screen.dart';

class AppNotificationsScreen extends StatefulWidget {
  const AppNotificationsScreen({super.key});

  @override
  State<AppNotificationsScreen> createState() => _AppNotificationsScreenState();
}

class _AppNotificationsScreenState extends State<AppNotificationsScreen> {
  AppNotificationType? _filter;

  @override
  void initState() {
    super.initState();
    AppStore.subscribersChange.addListener(_refresh);
  }

  @override
  void dispose() {
    AppStore.subscribersChange.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  String _dayLabel(DateTime day, DateTime now) {
    if (AppStore.isSameDay(day, now)) return 'اليوم';
    if (AppStore.isSameDay(day, now.subtract(const Duration(days: 1)))) {
      return 'أمس';
    }
    return '${day.day.toString().padLeft(2, '0')}/${day.month.toString().padLeft(2, '0')}/${day.year}';
  }

  String _time(DateTime at) {
    final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
    return '$hour:${at.minute.toString().padLeft(2, '0')} ${at.hour < 12 ? 'ص' : 'م'}';
  }

  Future<void> _push(Widget screen) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  void _openSubscriber(AppNotification item) {
    final user = item.subscriberUser.toLowerCase();
    for (final subscriber in AppStore.subscribers) {
      if (subscriber.user.trim().toLowerCase() == user) {
        _push(SubscriberDetailsScreen(subscriber: subscriber));
        return;
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('لم يعد هذا المشترك في القائمة')),
    );
  }

  void _renew(AppNotification item) =>
      _push(SubscribersScreen(initialSearch: item.subscriberUser));

  bool _matches(AppNotification item) => switch (_filter) {
    null => true,
    AppNotificationType.activated => item.type == AppNotificationType.activated,
    _ => item.type != AppNotificationType.activated,
  };

  Widget _filterChip(String label, AppNotificationType? value) => ChoiceChip(
    label: Text(label),
    selected: _filter == value,
    onSelected: (_) => setState(() => _filter = value),
  );

  Widget _tile(AppNotification item) {
    final (icon, color) = switch (item.type) {
      AppNotificationType.activated => (
        Icons.check_circle_outline,
        const Color(0xFF2E7D32),
      ),
      AppNotificationType.expired => (
        Icons.event_busy_outlined,
        const Color(0xFFC62828),
      ),
      AppNotificationType.expiresToday => (
        Icons.schedule_rounded,
        const Color(0xFFEF6C00),
      ),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(item.title),
        subtitle: Text(_time(item.at)),
        onTap: () => _openSubscriber(item),
        trailing: item.type == AppNotificationType.activated
            ? null
            : TextButton(
                onPressed: () => _renew(item),
                child: const Text('تجديد'),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final items = AppNotifications.current(now: now).where(_matches).toList();
    final children = <Widget>[];
    DateTime? day;
    for (final item in items) {
      if (day == null || !AppStore.isSameDay(day, item.at)) {
        day = item.at;
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
            child: Text(
              _dayLabel(item.at, now),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        );
      }
      children.add(_tile(item));
    }

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('الإشعارات'), centerTitle: true),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Wrap(
                spacing: 8,
                children: [
                  _filterChip('الكل', null),
                  _filterChip('التفعيلات', AppNotificationType.activated),
                  _filterChip('الانتهاءات', AppNotificationType.expired),
                ],
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('لا توجد إشعارات خلال آخر 7 أيام'))
                  : ListView(
                      padding: const EdgeInsets.all(12),
                      children: children,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
