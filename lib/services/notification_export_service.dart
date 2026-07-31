import 'dart:convert';
import '../models.dart';

class NotificationGroup {
  NotificationGroup({required this.id, required this.title, required this.recipients});

  final String id;
  final String title;
  final List<Subscriber> recipients;
}

List<NotificationGroup> buildAutomaticNotificationPlan(List<Subscriber> subscribers) {
  final now = DateTime.now();
  final all = subscribers.where((s) => s.phone.trim().isNotEmpty).toList();

  final debt = all.where((s) => s.remaining > 0.0001).toList();
  final nearExpiry = all.where((s) {
    if (s.disabled || s.expired) return false;
    final days = s.endDate.difference(now).inDays;
    return days >= 0 && days <= 3;
  }).toList();
  final expired = all.where((s) {
    final days = s.endDate.difference(now).inDays;
    return days < 0;
  }).toList();

  return [
    NotificationGroup(id: 'debt', title: 'المديونين', recipients: debt),
    NotificationGroup(id: 'nearExpiry', title: 'القريبين من الانتهاء', recipients: nearExpiry),
    NotificationGroup(id: 'expired', title: 'المنتهية اشتراكاتهم', recipients: expired),
  ];
}

String exportSubscribersToCsv(List<Subscriber> subscribers) {
  final rows = <String>[];
  rows.add('الرقم,اسم المشترك,اسم المستخدم,الهاتف,الباقة,السعر,المدفوع,المتبقي,تاريخ البداية,تاريخ الانتهاء,ملاحظات');
  for (var i = 0; i < subscribers.length; i++) {
    final s = subscribers[i];
    String escape(String value) => '"${value.replaceAll('"', '""')}"';
    rows.add([
      '${i + 1}',
      escape(s.name),
      escape(s.user),
      escape(s.phone),
      escape(s.packageDisplay),
      escape(s.price.toStringAsFixed(0)),
      escape(s.paid.toStringAsFixed(0)),
      escape(s.remaining.toStringAsFixed(0)),
      escape('${s.startDate.day.toString().padLeft(2, '0')}/${s.startDate.month.toString().padLeft(2, '0')}/${s.startDate.year}'),
      escape('${s.endDate.day.toString().padLeft(2, '0')}/${s.endDate.month.toString().padLeft(2, '0')}/${s.endDate.year}'),
      escape(s.notes),
    ].join(','));
  }
  return rows.join('\n');
}

String exportSubscribersToExcel(List<Subscriber> subscribers) {
  return exportSubscribersToCsv(subscribers);
}

String exportSubscribersToJson(List<Subscriber> subscribers) {
  final payload = subscribers.map((s) => s.toJson()).toList();
  return const JsonEncoder.withIndent('  ').convert(payload);
}
