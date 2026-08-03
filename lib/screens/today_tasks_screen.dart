import 'package:flutter/material.dart';

import '../models.dart';

class TodayTasksScreen extends StatefulWidget {
  const TodayTasksScreen({super.key});

  @override
  State<TodayTasksScreen> createState() => _TodayTasksScreenState();
}

class _TodayTasksScreenState extends State<TodayTasksScreen> {
  DateTime _selectedDate = DateTime.now();

  String _date(DateTime d) {
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  String _time(DateTime d) {
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  List<DailyTaskEvent> _eventsOfDay(DateTime day) {
    final events = AppStore.dailyTaskEvents
        .where((e) => AppStore.isSameDay(e.at, day))
        .toList();
    events.sort((a, b) => b.at.compareTo(a.at));
    return events;
  }

  @override
  Widget build(BuildContext context) {
    final events = _eventsOfDay(_selectedDate);
    final activationEvents = events.where((e) => e.type == 'activation').toList();
    final debtPaymentEvents =
        events.where((e) => e.type == 'debt_payment' && e.amount > 0).toList();

    final activationCases = activationEvents.length;
    final debtPaymentCases = debtPaymentEvents.length;

    final activationCollected = activationEvents.fold<double>(
      0,
      (sum, e) => sum + e.amount,
    );
    final paymentsCollected = debtPaymentEvents.fold<double>(
      0,
      (sum, e) => sum + e.amount,
    );
    final totalCollected = activationCollected + paymentsCollected;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('المهام اليومية'),
          centerTitle: true,
          actions: [
            IconButton(
              tooltip: 'اختيار التاريخ',
              icon: const Icon(Icons.date_range_outlined),
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _selectedDate,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2100),
                );
                if (picked != null) {
                  setState(() => _selectedDate = picked);
                }
              },
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.today_outlined),
                    const SizedBox(width: 8),
                    Text(
                      'التاريخ المحدد: ${_date(_selectedDate)}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _selectedDate,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) {
                          setState(() => _selectedDate = picked);
                        }
                      },
                      icon: const Icon(Icons.edit_calendar_outlined),
                      label: const Text('تغيير'),
                    ),
                  ],
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: const [
                    Icon(Icons.info_outline, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'يتم تحديث التاريخ تلقائياً كل يوم، ويمكن الرجوع للسجل حتى آخر 30 يوم.',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _summaryCard(
                  title: 'حالات التفعيل',
                  value: activationCases.toString(),
                  icon: Icons.check_circle_outline,
                  color: Colors.green,
                ),
                _summaryCard(
                  title: 'حالات تسديد الديون',
                  value: debtPaymentCases.toString(),
                  icon: Icons.paid_outlined,
                  color: Colors.blue,
                ),
                _summaryCard(
                  title: 'الواصل من التفعيل',
                  value: activationCollected.toStringAsFixed(0),
                  icon: Icons.point_of_sale_outlined,
                  color: Colors.teal,
                ),
                _summaryCard(
                  title: 'الواصل من التسديد',
                  value: paymentsCollected.toStringAsFixed(0),
                  icon: Icons.account_balance_wallet_outlined,
                  color: Colors.orange,
                ),
                _summaryCard(
                  title: 'المجموع الواصل اليوم',
                  value: totalCollected.toStringAsFixed(0),
                  icon: Icons.calculate_outlined,
                  color: Colors.deepPurple,
                ),
              ],
            ),
            const SizedBox(height: 14),
            _sectionTitle('حالات التفعيل خلال اليوم'),
            const SizedBox(height: 6),
            if (activationEvents.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('لا توجد حالات تفعيل في هذا التاريخ'),
                ),
              )
            else
              ...activationEvents.map((e) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.verified_outlined, color: Colors.green),
                      title: Text(e.subscriberName),
                      subtitle: Text('المستخدم: ${e.subscriberUser} | الوقت: ${_time(e.at)}'),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            'الواصل: ${e.amount.toStringAsFixed(0)}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          if (e.note.trim().isNotEmpty)
                            Text(
                              e.note,
                              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                            ),
                        ],
                      ),
                    ),
                  )),
            const SizedBox(height: 14),
            _sectionTitle('حالات تسديد المبالغ المترتبة'),
            const SizedBox(height: 6),
            if (debtPaymentEvents.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('لا توجد حالات تسديد ديون في هذا التاريخ'),
                ),
              )
            else
              ...debtPaymentEvents.map((e) {
                final fullySettled = e.remainingAfter <= 0.0001;
                return Card(
                  child: ListTile(
                    leading: Icon(
                      fullySettled ? Icons.task_alt_outlined : Icons.payments_outlined,
                      color: fullySettled ? Colors.green : Colors.blue,
                    ),
                    title: Text(e.subscriberName),
                    subtitle: Text('المستخدم: ${e.subscriberUser} | الوقت: ${_time(e.at)}'),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          'الواصل: ${e.amount.toStringAsFixed(0)}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          fullySettled
                              ? 'الحالة: مسدد بالكامل'
                              : 'المتبقي: ${e.remainingAfter.toStringAsFixed(0)}',
                          style: TextStyle(
                            fontSize: 11,
                            color: fullySettled ? Colors.green.shade700 : Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
    );
  }

  Widget _summaryCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      width: 220,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
