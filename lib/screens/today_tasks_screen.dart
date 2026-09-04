import 'package:flutter/material.dart';

import '../models.dart';

enum _DailyTaskFilter { all, activation, payment, debtAdded }

class TodayTasksScreen extends StatefulWidget {
  const TodayTasksScreen({super.key});

  @override
  State<TodayTasksScreen> createState() => _TodayTasksScreenState();
}

class _TodayTasksScreenState extends State<TodayTasksScreen> {
  DateTime _selectedDate = DateTime.now();
  _DailyTaskFilter _filter = _DailyTaskFilter.all;

  String _date(DateTime d) {
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  String _time(DateTime d) {
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  String _money(double amount) => '${amount.toStringAsFixed(0)} د.ع';

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
    final summary = DailyTaskSummary.fromEvents(events);
    final filteredEvents = events.where((event) {
      return switch (_filter) {
        _DailyTaskFilter.all => true,
        _DailyTaskFilter.activation => event.type == 'activation',
        _DailyTaskFilter.payment =>
          event.type == 'debt_payment' && event.amount > 0,
        _DailyTaskFilter.debtAdded =>
          event.type == 'debt_added' && event.amount > 0,
      };
    }).toList();

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('المهام اليومية')),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final horizontalPadding = constraints.maxWidth < 600 ? 12.0 : 24.0;
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                16,
                horizontalPadding,
                32,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1180),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _reportHeader(summary),
                      const SizedBox(height: 16),
                      _summaryGrid(summary),
                      const SizedBox(height: 24),
                      _activityHeader(events.length),
                      const SizedBox(height: 12),
                      if (filteredEvents.isEmpty)
                        _emptyState()
                      else
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: Column(
                            children: [
                              for (
                                var i = 0;
                                i < filteredEvents.length;
                                i++
                              ) ...[
                                _activityRow(filteredEvents[i]),
                                if (i < filteredEvents.length - 1)
                                  const Divider(height: 1, indent: 72),
                              ],
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) setState(() => _selectedDate = picked);
  }

  Widget _reportHeader(DailyTaskSummary summary) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF12372A),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        spacing: 24,
        runSpacing: 18,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'تقرير ${_date(_selectedDate)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'إجمالي النقد الواصل خلال اليوم',
                style: TextStyle(color: Colors.white.withValues(alpha: 0.72)),
              ),
              const SizedBox(height: 4),
              Text(
                _money(summary.totalCollected),
                style: const TextStyle(
                  color: Color(0xFF7DE2B8),
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          OutlinedButton.icon(
            onPressed: _pickDate,
            icon: const Icon(Icons.calendar_month_outlined),
            label: const Text('تغيير التاريخ'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.45)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryGrid(DailyTaskSummary summary) {
    final items = [
      (
        'حالات التفعيل',
        summary.activationCases.toString(),
        Icons.check_circle_outline,
        Colors.green,
      ),
      (
        'حالات تسديد الديون',
        summary.debtPaymentCases.toString(),
        Icons.paid_outlined,
        Colors.blue,
      ),
      (
        'الواصل من التفعيل',
        _money(summary.activationCollected),
        Icons.point_of_sale_outlined,
        Colors.teal,
      ),
      (
        'الواصل من التسديد',
        _money(summary.debtPaymentsCollected),
        Icons.account_balance_wallet_outlined,
        Colors.orange,
      ),
      (
        'المجموع الواصل اليوم',
        _money(summary.totalCollected),
        Icons.calculate_outlined,
        Colors.deepPurple,
      ),
      (
        'المضاف إلى الديون',
        _money(summary.debtAddedTotal),
        Icons.add_card_outlined,
        Colors.red,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 920
            ? 3
            : constraints.maxWidth >= 520
            ? 2
            : 1;
        final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final item in items)
              SizedBox(
                width: width,
                child: _summaryTile(
                  title: item.$1,
                  value: item.$2,
                  icon: item.$3,
                  color: item.$4,
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _summaryTile({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      constraints: const BoxConstraints(minHeight: 112),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _activityHeader(int count) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'سجل العمليات',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
            Text(
              '$count عملية',
              style: const TextStyle(color: Color(0xFF64748B)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<_DailyTaskFilter>(
            segments: const [
              ButtonSegment(value: _DailyTaskFilter.all, label: Text('الكل')),
              ButtonSegment(
                value: _DailyTaskFilter.activation,
                label: Text('التفعيل'),
              ),
              ButtonSegment(
                value: _DailyTaskFilter.payment,
                label: Text('التسديد'),
              ),
              ButtonSegment(
                value: _DailyTaskFilter.debtAdded,
                label: Text('إضافة دين'),
              ),
            ],
            selected: {_filter},
            onSelectionChanged: (value) =>
                setState(() => _filter = value.first),
            showSelectedIcon: false,
          ),
        ),
      ],
    );
  }

  Widget _activityRow(DailyTaskEvent event) {
    final isActivation = event.type == 'activation';
    final isPayment = event.type == 'debt_payment';
    final color = isActivation
        ? const Color(0xFF087F5B)
        : isPayment
        ? const Color(0xFF1769AA)
        : const Color(0xFFC2413B);
    final icon = isActivation
        ? Icons.bolt_outlined
        : isPayment
        ? Icons.payments_outlined
        : Icons.add_card_outlined;
    final label = isActivation
        ? 'تفعيل'
        : isPayment
        ? 'تسديد دين'
        : 'إضافة دين';
    final amountLabel = isPayment || isActivation ? 'الواصل' : 'المضاف';
    final amount = event.amount;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 21),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      event.subscriberName,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      label,
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${event.subscriberUser}  •  ${_time(event.at)}'
                  '${event.note.trim().isEmpty ? '' : '  •  ${event.note}'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$amountLabel: ${_money(amount)}',
                style: TextStyle(color: color, fontWeight: FontWeight.w800),
              ),
              if (!isActivation)
                Text(
                  'المتبقي: ${_money(event.remainingAfter)}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF64748B),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 44),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: const Column(
        children: [
          Icon(Icons.inbox_outlined, size: 38, color: Color(0xFF94A3B8)),
          SizedBox(height: 10),
          Text(
            'لا توجد عمليات ضمن هذا التصنيف',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
