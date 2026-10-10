import 'package:flutter/material.dart';

import '../models.dart';

class ActivityLogScreen extends StatefulWidget {
  const ActivityLogScreen({super.key});

  @override
  State<ActivityLogScreen> createState() => _ActivityLogScreenState();
}

class _ActivityLogScreenState extends State<ActivityLogScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _typeFilter = 'all';
  DateTime? _dateFilter;

  static const Map<String, String> _typeLabels = {
    'all': 'كل العمليات',
    'activation': 'تفعيل',
    'debt_added': 'إضافة دين',
    'debt_payment': 'تسديد دين',
    DailyTaskEvent.debtEntryCollectionType: 'تحصيل عند التفعيل',
    DailyTaskEvent.debtEditType: 'تعديل مبالغ',
    DailyTaskEvent.subscriberCreatedType: 'إضافة مشترك',
    DailyTaskEvent.subscriberUpdatedType: 'تعديل بيانات مشترك',
    DailyTaskEvent.subscriberDeletedType: 'حذف مشترك',
    DailyTaskEvent.subscriberPackageChangedType: 'تغيير باقة',
    DailyTaskEvent.subscriberDisabledType: 'تعطيل مشترك',
    DailyTaskEvent.subscriberEnabledType: 'إلغاء تعطيل مشترك',
    DailyTaskEvent.subscriberExtendedType: 'تمديد اشتراك',
    DailyTaskEvent.activationRequestedType: 'طلب تفعيل FTTH',
    'payment_approved': 'قبول طلب دفع',
    'payment_rejected': 'رفض طلب دفع',
  };

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _formatDate(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}/'
      '${value.month.toString().padLeft(2, '0')}/'
      '${value.year}  '
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';

  List<DailyTaskEvent> _filteredEvents() {
    final query = _searchController.text.trim().toLowerCase();
    final events = AppStore.dailyTaskEvents.where((event) {
      if (_typeFilter != 'all' && event.type != _typeFilter) return false;
      if (_dateFilter != null && !AppStore.isSameDay(event.at, _dateFilter!)) {
        return false;
      }
      if (query.isNotEmpty) {
        final searchable =
            '${event.subscriberName} ${event.subscriberUser} ${event.note}'
                .toLowerCase();
        if (!searchable.contains(query)) return false;
      }
      return true;
    }).toList()..sort((a, b) => b.at.compareTo(a.at));
    return events;
  }

  Future<void> _selectDate() async {
    final now = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: _dateFilter ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 1),
    );
    if (selected != null && mounted) {
      setState(() => _dateFilter = selected);
    }
  }

  String _eventTitle(DailyTaskEvent event) =>
      _typeLabels[event.type] ?? 'عملية';

  Color _eventColor(DailyTaskEvent event) {
    switch (event.type) {
      case 'debt_added':
        return Colors.red;
      case 'debt_payment':
      case DailyTaskEvent.debtEntryCollectionType:
        return Colors.green;
      case 'activation':
      case DailyTaskEvent.debtEditType:
      case DailyTaskEvent.subscriberCreatedType:
      case DailyTaskEvent.subscriberUpdatedType:
      case DailyTaskEvent.subscriberPackageChangedType:
      case DailyTaskEvent.subscriberEnabledType:
      case DailyTaskEvent.subscriberExtendedType:
      case DailyTaskEvent.activationRequestedType:
        return Colors.blue;
      case DailyTaskEvent.subscriberDeletedType:
      case DailyTaskEvent.subscriberDisabledType:
      case 'payment_rejected':
        return Colors.red;
      case 'payment_approved':
        return Colors.green;
      default:
        return Colors.blueGrey;
    }
  }

  IconData _eventIcon(DailyTaskEvent event) {
    switch (event.type) {
      case 'debt_added':
        return Icons.add_card_outlined;
      case 'debt_payment':
      case DailyTaskEvent.debtEntryCollectionType:
        return Icons.payments_outlined;
      case 'activation':
        return Icons.check_circle_outline_rounded;
      case DailyTaskEvent.debtEditType:
        return Icons.edit_note_rounded;
      case DailyTaskEvent.subscriberCreatedType:
        return Icons.person_add_alt_1_outlined;
      case DailyTaskEvent.subscriberUpdatedType:
        return Icons.manage_accounts_outlined;
      case DailyTaskEvent.subscriberDeletedType:
        return Icons.person_remove_outlined;
      case DailyTaskEvent.subscriberPackageChangedType:
        return Icons.swap_horiz_rounded;
      case DailyTaskEvent.subscriberDisabledType:
        return Icons.person_off_outlined;
      case DailyTaskEvent.subscriberEnabledType:
        return Icons.person_outline_rounded;
      case DailyTaskEvent.subscriberExtendedType:
        return Icons.autorenew_rounded;
      case DailyTaskEvent.activationRequestedType:
        return Icons.play_circle_outline_rounded;
      case 'payment_approved':
        return Icons.verified_outlined;
      case 'payment_rejected':
        return Icons.cancel_outlined;
      default:
        return Icons.history_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final events = _filteredEvents();
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('سجل العمليات'),
          centerTitle: true,
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
              child: Column(
                children: [
                  TextField(
                    controller: _searchController,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'ابحث باسم المشترك أو اسم المستخدم',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _searchController.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'مسح البحث',
                              onPressed: () {
                                _searchController.clear();
                                setState(() {});
                              },
                              icon: const Icon(Icons.close_rounded),
                            ),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _typeFilter,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'نوع العملية',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: _typeLabels.entries
                              .map(
                                (entry) => DropdownMenuItem<String>(
                                  value: entry.key,
                                  child: Text(entry.value),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _typeFilter = value);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _selectDate,
                        icon: const Icon(Icons.calendar_month_outlined),
                        label: Text(
                          _dateFilter == null
                              ? 'كل التواريخ'
                              : '${_dateFilter!.day.toString().padLeft(2, '0')}/'
                                    '${_dateFilter!.month.toString().padLeft(2, '0')}/'
                                    '${_dateFilter!.year}',
                        ),
                      ),
                      if (_dateFilter != null)
                        IconButton(
                          tooltip: 'إلغاء فلتر التاريخ',
                          onPressed: () => setState(() => _dateFilter = null),
                          icon: const Icon(Icons.filter_alt_off_outlined),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Align(
                alignment: Alignment.centerRight,
                child: Text('عدد العمليات: ${events.length}'),
              ),
            ),
            Expanded(
              child: events.isEmpty
                  ? const Center(child: Text('لا توجد عمليات مطابقة للبحث.'))
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                      itemCount: events.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 4),
                      itemBuilder: (context, index) {
                        final event = events[index];
                        final color = _eventColor(event);
                        final isEdit = event.type == DailyTaskEvent.debtEditType;
                        return Card(
                          margin: EdgeInsets.zero,
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: color.withValues(alpha: 0.12),
                              child: Icon(_eventIcon(event), color: color),
                            ),
                            title: Text(
                              '${_eventTitle(event)}${event.subscriberName.isEmpty ? '' : ' • ${event.subscriberName}'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${_formatDate(event.at)}'
                              '${event.subscriberUser.isEmpty ? '' : ' • ${event.subscriberUser}'}'
                              '${event.note.trim().isEmpty ? '' : '\n${event.note.trim().replaceAll(' | ', '\n')}' }'
                              '${event.remainingAfter > 0 ? '\nالمتبقي ${event.remainingAfter.toStringAsFixed(0)} د.ع' : ''}',
                              maxLines: isEdit ? 5 : 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: isEdit || event.amount == 0
                                ? null
                                : Text(
                                    '${event.amount.toStringAsFixed(0)} د.ع',
                                    style: TextStyle(
                                      color: color,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                            isThreeLine: isEdit,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}