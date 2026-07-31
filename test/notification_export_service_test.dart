import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';
import 'package:untitled/services/notification_export_service.dart';

void main() {
  group('Notification export helpers', () {
    test('buildAutomaticNotificationPlan groups debt and expiring subscribers', () {
      final now = DateTime.now();
      final subscribers = [
        Subscriber(
          user: 'u1',
          name: 'أحمد',
          phone: '0790000000',
          address: '',
          ip: '',
          type: 'أساسي',
          price: 100,
          startDate: now.subtract(const Duration(days: 10)),
          endDate: now.add(const Duration(days: 2)),
          paid: 0,
        ),
        Subscriber(
          user: 'u2',
          name: 'سامي',
          phone: '0790000001',
          address: '',
          ip: '',
          type: 'أساسي',
          price: 100,
          startDate: now.subtract(const Duration(days: 10)),
          endDate: now.add(const Duration(days: 5)),
          paid: 50,
        ),
        Subscriber(
          user: 'u3',
          name: 'ليث',
          phone: '0790000002',
          address: '',
          ip: '',
          type: 'أساسي',
          price: 100,
          startDate: now.subtract(const Duration(days: 30)),
          endDate: now.subtract(const Duration(days: 1)),
          paid: 0,
        ),
      ];

      final plan = buildAutomaticNotificationPlan(subscribers);
      final debtGroup = plan.firstWhere((e) => e.id == 'debt');
      final nearGroup = plan.firstWhere((e) => e.id == 'nearExpiry');
      final expiredGroup = plan.firstWhere((e) => e.id == 'expired');

      expect(debtGroup.recipients.map((s) => s.user), contains('u1'));
      expect(nearGroup.recipients.map((s) => s.user), contains('u1'));
      expect(expiredGroup.recipients.map((s) => s.user), contains('u3'));
    });

    test('exportSubscribersToCsv returns a header and escaped values', () {
      final subscriber = Subscriber(
        user: 'u1',
        name: 'أحمد "العمري"',
        phone: '0790000000',
        address: 'العراق',
        ip: '192.168.1.1',
        type: 'أساسي',
        price: 100,
        startDate: DateTime(2024, 1, 1),
        endDate: DateTime(2024, 2, 1),
        paid: 50,
      );

      final csv = exportSubscribersToCsv([subscriber]);
      expect(csv, contains('اسم المشترك'));
      expect(csv, contains('أحمد ""العمري""'));
    });

    test('exportSubscribersToExcel returns an Excel-friendly table', () {
      final subscriber = Subscriber(
        user: 'u1',
        name: 'أحمد',
        phone: '0790000000',
        address: '',
        ip: '',
        type: 'أساسي',
        price: 100,
        startDate: DateTime(2024, 1, 1),
        endDate: DateTime(2024, 2, 1),
        paid: 50,
      );

      final excel = exportSubscribersToExcel([subscriber]);
      expect(excel, contains('اسم المشترك'));
      expect(excel, contains('أحمد'));
    });

    test('exportSubscribersToJson returns valid JSON array', () {
      final subscriber = Subscriber(
        user: 'u1',
        name: 'أحمد',
        phone: '0790000000',
        address: '',
        ip: '',
        type: 'أساسي',
        price: 100,
        startDate: DateTime(2024, 1, 1),
        endDate: DateTime(2024, 2, 1),
        paid: 50,
      );

      final json = exportSubscribersToJson([subscriber]);
      expect(json, contains('"user": "u1"'));
      expect(json, contains('"name": "أحمد"'));
    });
  });
}
