import 'package:flutter/material.dart';
import '../models.dart';

class QuickReportsScreen extends StatelessWidget {
  const QuickReportsScreen({super.key});

  static Map<String, dynamic> buildReport(List<Subscriber> subscribers) {
    final now = DateTime.now();
    final active = <Subscriber>[];
    final expired = <Subscriber>[];
    final expiringSoon = <Subscriber>[];
    final debtors = <Subscriber>[];

    for (final s in subscribers) {
      if (s.isActive && !s.disabled && !s.expired) {
        active.add(s);
      }
      if (s.expired) {
        expired.add(s);
      }

      if (!s.disabled && !s.expired) {
        final days = s.endDate.difference(now).inDays;
        if (days >= 0 && days <= 3) {
          expiringSoon.add(s);
        }
      }

      if (s.remaining > 0) {
        debtors.add(s);
      }
    }

    expiringSoon.sort((a, b) => a.endDate.compareTo(b.endDate));
    debtors.sort((a, b) => b.remaining.compareTo(a.remaining));

    return {
      'total': subscribers.length,
      'active': active.length,
      'expired': expired.length,
      'expiring3Days': expiringSoon.length,
      'debtors': debtors.length,
      'totalDebt': debtors.fold<double>(0, (sum, s) => sum + s.remaining),
      'expiringSoon': expiringSoon,
      'debtorsList': debtors,
    };
  }

  String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  Widget _statCard({required IconData icon, required Color color, required String title, required String value}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: color.withValues(alpha: 0.12),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final report = buildReport(AppStore.subscribers);
    final expiringSoon = List<Subscriber>.from(report['expiringSoon'] as List<Subscriber>);
    final debtors = List<Subscriber>.from(report['debtorsList'] as List<Subscriber>);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('تقارير سريعة'),
          centerTitle: true,
        ),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _statCard(icon: Icons.groups, color: Colors.blue, title: 'إجمالي المشتركين', value: report['total'].toString()),
            _statCard(icon: Icons.verified_user, color: Colors.green, title: 'المشتركين الفعالين', value: '${report['active']}'),
            _statCard(icon: Icons.event_busy, color: Colors.orange, title: 'المنتهين', value: '${report['expired']}'),
            _statCard(icon: Icons.hourglass_top, color: Colors.deepOrange, title: 'ينتهون خلال 3 أيام', value: '${report['expiring3Days']}'),
            _statCard(icon: Icons.account_balance_wallet, color: Colors.red, title: 'عدد المدينين', value: '${report['debtors']}'),
            _statCard(icon: Icons.attach_money, color: Colors.teal, title: 'إجمالي المتبقي', value: '${report['totalDebt'].toStringAsFixed(0)}'),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('أقرب الانتهاء', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    if (expiringSoon.isEmpty)
                      const Text('لا توجد اشتراكات قريبة من الانتهاء')
                    else
                      ...expiringSoon.take(6).map((s) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(s.name),
                            subtitle: Text('ينتهي: ${_fmt(s.endDate)}'),
                            trailing: Text('${s.endDate.difference(DateTime.now()).inDays} يوم'),
                          )),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('أعلى المدينين', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    if (debtors.isEmpty)
                      const Text('لا توجد ديون حالياً')
                    else
                      ...debtors.take(6).map((s) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(s.name),
                            subtitle: Text(s.user),
                            trailing: Text(s.remaining.toStringAsFixed(0)),
                          )),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
