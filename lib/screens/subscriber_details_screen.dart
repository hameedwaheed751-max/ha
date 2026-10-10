import 'dart:convert';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models.dart';
import '../services/subscriber_financial_ledger.dart';
import 'add_subscriber_screen.dart';
import 'dashboard_widgets.dart';
import 'receipt_screen.dart';

class SubscriberDetailsScreen extends StatefulWidget {
  final Subscriber subscriber;
  final Future<void> Function(Subscriber)? onEditDebt;
  final Future<void> Function(Subscriber)? onAddDebtAmount;
  final Future<void> Function(Subscriber)? onPartialDebtPayment;

  const SubscriberDetailsScreen({
    super.key,
    required this.subscriber,
    this.onEditDebt,
    this.onAddDebtAmount,
    this.onPartialDebtPayment,
  });

  @override
  State<SubscriberDetailsScreen> createState() => _SubscriberDetailsScreenState();
}

class _SubscriberDetailsScreenState extends State<SubscriberDetailsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController tabs;
  Subscriber get s => widget.subscriber;
  String _recordsMonthFilter = 'all';
  late DateTime _financialMonth;
  late Future<SubscriberMonthlyLedger> _financialLedgerFuture;

  String f(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  String _monthLabel(String monthKey) {
    final parts = monthKey.split('-');
    if (parts.length != 2) return monthKey;
    final y = parts[0];
    final m = int.tryParse(parts[1]) ?? 0;
    const names = <String>[
      'يناير',
      'فبراير',
      'مارس',
      'ابريل',
      'مايو',
      'يونيو',
      'يوليو',
      'اغسطس',
      'سبتمبر',
      'اكتوبر',
      'نوفمبر',
      'ديسمبر',
    ];
    if (m < 1 || m > 12) return monthKey;
    return '${names[m - 1]} $y';
  }

  List<InvoiceRecord> _sortedInvoices() {
    final list = List<InvoiceRecord>.from(s.invoices);
    list.sort((a, b) => b.at.compareTo(a.at));
    return list;
  }

  List<PaymentRecord> _sortedPayments() {
    final list = List<PaymentRecord>.from(s.payments);
    list.sort((a, b) => b.at.compareTo(a.at));
    return list;
  }

  List<String> _recordsMonthOptions() {
    final keys = <String>{
      ...s.invoices.map((invoice) => invoice.monthKey),
      ...s.payments.map((payment) => Subscriber.monthKeyOf(payment.at)),
    }..removeWhere((key) => key.trim().isEmpty);
    final sortedKeys = keys.toList()..sort((a, b) => b.compareTo(a));
    return <String>['all', ...sortedKeys];
  }

  Widget _recordsMonthSelector({
    required List<String> options,
    required String selectedMonth,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: selectedMonth,
      decoration: const InputDecoration(
        labelText: 'الشهر',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: options
          .map(
            (key) => DropdownMenuItem<String>(
              value: key,
              child: Text(key == 'all' ? 'كل الأشهر' : _monthLabel(key)),
            ),
          )
          .toList(),
      onChanged: (value) {
        if (value != null) setState(() => _recordsMonthFilter = value);
      },
    );
  }

  Widget _paidAndDueSummary(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: _balanceSummaryItem(
            context,
            label: 'إجمالي المدفوع',
            amount: s.paid,
            color: Colors.green,
            icon: Icons.check_circle_outline_rounded,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _balanceSummaryItem(
            context,
            label: 'المتبقي المستحق',
            amount: s.remaining,
            color: s.remaining > 0 ? colors.error : Colors.green,
            icon: s.remaining > 0
                ? Icons.pending_actions_rounded
                : Icons.task_alt_rounded,
          ),
        ),
      ],
    );
  }

  Widget _balanceSummaryItem(
    BuildContext context, {
    required String label,
    required double amount,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(color: color, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${amount.toStringAsFixed(0)} د.ع',
            style: TextStyle(
              color: color,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  String _csvCell(String value) {
    final escaped = value.replaceAll('"', '""');
    return '"$escaped"';
  }

  Future<void> _exportInvoicesCsv(List<InvoiceRecord> invoices, String monthFilter) async {
    if (invoices.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد فواتير للتصدير حسب الفلتر المختار')),
      );
      return;
    }

    try {
      final lines = <String>[
        'receipt_number,date,month,amount,note',
        ...invoices.map((inv) {
          final date = f(inv.at);
          final month = _monthLabel(inv.monthKey);
          return [
            inv.receiptNumber.toString(),
            _csvCell(date),
            _csvCell(month),
            inv.amount.toStringAsFixed(0),
            _csvCell(inv.note),
          ].join(',');
        }),
      ];

      final csv = '\uFEFF${lines.join('\n')}';
      final bytes = Uint8List.fromList(utf8.encode(csv));
      final sanitizedUser = s.user.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final suffix = monthFilter == 'all' ? 'all' : monthFilter;

      await FileSaver.instance.saveFile(
        name: 'invoices_${sanitizedUser}_$suffix',
        bytes: bytes,
        fileExtension: 'csv',
        mimeType: MimeType.csv,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تصدير الفواتير بنجاح')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر تصدير الملف، حاول مرة أخرى')),
      );
    }
  }

  Future<void> _exportPaymentsCsv(List<PaymentRecord> payments, String monthFilter) async {
    if (payments.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد مدفوعات للتصدير حسب الفلتر المختار')),
      );
      return;
    }

    try {
      final lines = <String>[
        'date,month,amount,note',
        ...payments.map((p) {
          final date = f(p.at);
          final month = _monthLabel(Subscriber.monthKeyOf(p.at));
          return [
            _csvCell(date),
            _csvCell(month),
            p.amount.toStringAsFixed(0),
            _csvCell(p.note),
          ].join(',');
        }),
      ];

      final csv = '\uFEFF${lines.join('\n')}';
      final bytes = Uint8List.fromList(utf8.encode(csv));
      final sanitizedUser = s.user.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final suffix = monthFilter == 'all' ? 'all' : monthFilter;

      await FileSaver.instance.saveFile(
        name: 'payments_${sanitizedUser}_$suffix',
        bytes: bytes,
        fileExtension: 'csv',
        mimeType: MimeType.csv,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تصدير المدفوعات بنجاح')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر تصدير الملف، حاول مرة أخرى')),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    tabs = TabController(length: 6, vsync: this);
    final now = DateTime.now();
    _financialMonth = DateTime(now.year, now.month);
    _financialLedgerFuture = _readFinancialLedger();
  }

  Future<SubscriberMonthlyLedger> _readFinancialLedger() =>
      SubscriberFinancialLedger().getSubscriberLedger(
        s.subscriberId,
        _financialMonth,
      );

  List<String> _financialMonthOptions() {
    final now = DateTime.now();
    return List<String>.generate(
      24,
      (index) => Subscriber.monthKeyOf(DateTime(now.year, now.month - index)),
    );
  }

  void _selectFinancialMonth(String monthKey) {
    final parts = monthKey.split('-');
    if (parts.length != 2) return;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    if (year == null || month == null || month < 1 || month > 12) return;
    setState(() {
      _financialMonth = DateTime(year, month);
      _financialLedgerFuture = _readFinancialLedger();
    });
  }

  List<DailyTaskEvent> _matchingSubscriberDebtEvents() {
    final subscriberUser = s.user.trim().toLowerCase();
    final subscriberName = s.name.trim().toLowerCase();
    final operations = AppStore.dailyTaskEvents.where((event) {
      if (event.type != 'debt_added' &&
          event.type != 'debt_payment' &&
          event.type != DailyTaskEvent.debtEntryCollectionType &&
          event.type != DailyTaskEvent.debtEditType) {
        return false;
      }
      final eventUser = event.subscriberUser.trim().toLowerCase();
      if (subscriberUser.isNotEmpty && eventUser.isNotEmpty) {
        return subscriberUser == eventUser;
      }
      return subscriberName.isNotEmpty &&
          event.subscriberName.trim().toLowerCase() == subscriberName;
    }).toList()..sort((a, b) => b.at.compareTo(a.at));
    return operations;
  }

  List<DailyTaskEvent> _subscriberDebtOperations() {
    final events = _matchingSubscriberDebtEvents();
    final editTimestamps = events
        .where((event) => event.type == DailyTaskEvent.debtEditType)
        .map((event) => event.at.toUtc().microsecondsSinceEpoch)
        .toSet();
    return events.where((event) {
      if (event.type == DailyTaskEvent.debtEditType) return true;
      final isDebtMovement =
          event.type == 'debt_added' ||
          event.type == 'debt_payment' ||
          event.type == DailyTaskEvent.debtEntryCollectionType;
      return !isDebtMovement ||
          !editTimestamps.contains(event.at.toUtc().microsecondsSinceEpoch);
    }).toList(growable: false);
  }

  String _formatDebtEditNote(String note) => note
      .split(' | ')
      .map(
        (detail) => detail
            .replaceFirst(': ', ': قبل ')
            .replaceFirst(' -> ', ' | بعد '),
      )
      .join('\n');

  Future<void> _runDebtAction(
    Future<void> Function(Subscriber)? action,
    Subscriber subscriber,
  ) async {
    if (action == null) return;
    await action(subscriber);
    if (mounted) setState(() {});
  }

  Widget _debtOperationsTab() {
    final operations = _subscriberDebtOperations();
    final allEvents = _matchingSubscriberDebtEvents();

    final totalAdded = allEvents
        .where((event) => event.type == 'debt_added')
        .fold<double>(0, (total, event) => total + event.amount);
    final totalCollected = allEvents
        .where(
          (event) =>
              event.type == 'debt_payment' ||
              event.type == DailyTaskEvent.debtEntryCollectionType,
        )
        .fold<double>(0, (total, event) => total + event.amount);

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Row(
          children: [
            Expanded(
              child: _debtOperationTotal(
                label: 'إجمالي الديون المضافة',
                amount: totalAdded,
                color: Colors.red,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _debtOperationTotal(
                label: 'إجمالي التسديدات',
                amount: totalCollected,
                color: Colors.green,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: DebtOperationsMenu(
            subscriber: s,
            onEdit: widget.onEditDebt == null
                ? null
                : (subscriber) => _runDebtAction(widget.onEditDebt, subscriber),
            onAddAmount: widget.onAddDebtAmount == null
                ? null
                : (subscriber) =>
                      _runDebtAction(widget.onAddDebtAmount, subscriber),
            onPartialPayment: widget.onPartialDebtPayment == null
                ? null
                : (subscriber) =>
                      _runDebtAction(widget.onPartialDebtPayment, subscriber),
            showLabel: true,
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'سجل العمليات',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        const SizedBox(height: 8),
        if (operations.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Text('لا توجد عمليات سابقة مسجلة لهذا المشترك.'),
          ),
        ...operations.map((event) {
          final isDebtAdded = event.type == 'debt_added';
          final isDebtEdit = event.type == DailyTaskEvent.debtEditType;
          final color = isDebtEdit
            ? Colors.blue
            : isDebtAdded
            ? Colors.red
            : Colors.green;
          final title = isDebtEdit
            ? 'تعديل مبالغ الاشتراك'
            : isDebtAdded
              ? 'إضافة دين'
              : event.type == DailyTaskEvent.debtEntryCollectionType
              ? 'تحصيل عند التفعيل'
              : 'تسديد دين';
          return Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: color.withValues(alpha: 0.12),
                child: Icon(
                  isDebtEdit
                      ? Icons.edit_note_rounded
                      : isDebtAdded
                      ? Icons.add_card_outlined
                      : Icons.payments_outlined,
                  color: color,
                ),
              ),
              title: Text(title),
              isThreeLine: isDebtEdit,
              subtitle: isDebtEdit
                  ? Text(
                      '${f(event.at)}\n${_formatDebtEditNote(event.note)}',
                      style: const TextStyle(height: 1.45),
                    )
                  : Text(
                      '${f(event.at)}'
                      '${event.remainingAfter > 0 ? ' • المتبقي ${event.remainingAfter.toStringAsFixed(0)} د.ع' : ''}'
                      '${event.note.trim().isNotEmpty ? ' • ${event.note.trim()}' : ''}',
                    ),
              trailing: Text(
                isDebtEdit ? 'تم التعديل' : '${event.amount.toStringAsFixed(0)} د.ع',
                style: TextStyle(color: color, fontWeight: FontWeight.w800),
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _debtOperationTotal({
    required String label,
    required double amount,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            '${amount.toStringAsFixed(0)} د.ع',
            style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }

  String _financialTransactionLabel(FinancialTransactionType type) {
    switch (type) {
      case FinancialTransactionType.debt:
        return 'دين/مطالبة';
      case FinancialTransactionType.payment:
        return 'تسديد';
      case FinancialTransactionType.partialPayment:
        return 'تسديد جزئي';
      case FinancialTransactionType.openingBalance:
        return 'رصيد افتتاحي';
      case FinancialTransactionType.invoice:
        return 'فاتورة';
      case FinancialTransactionType.activation:
        return 'تفعيل';
      case FinancialTransactionType.credit:
        return 'رصيد دائن';
      case FinancialTransactionType.companyDeposit:
        return 'إيداع للشركة';
      case FinancialTransactionType.activationCost:
        return 'كلفة تفعيل';
      case FinancialTransactionType.expense:
        return 'مصروف';
      case FinancialTransactionType.adjustment:
        return 'تسوية';
    }
  }

  Widget _financialLedgerTab() {
    final selectedMonthKey = Subscriber.monthKeyOf(_financialMonth);
    final monthOptions = _financialMonthOptions();
    return FutureBuilder<SubscriberMonthlyLedger>(
      future: _financialLedgerFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Text('تعذر تحميل الحساب المالي: ${snapshot.error}'),
          );
        }
        final ledger = snapshot.data;
        if (ledger == null) {
          return const Center(child: Text('لا توجد بيانات للحساب المالي'));
        }

        return ListView(
          padding: const EdgeInsets.all(14),
          children: [
            DropdownButtonFormField<String>(
              initialValue: monthOptions.contains(selectedMonthKey)
                  ? selectedMonthKey
                  : monthOptions.first,
              decoration: const InputDecoration(
                labelText: 'الشهر',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: monthOptions
                  .map(
                    (key) => DropdownMenuItem<String>(
                      value: key,
                      child: Text(_monthLabel(key)),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) _selectFinancialMonth(value);
              },
            ),
            const SizedBox(height: 12),
            const Text(
              'ملخص الشهر',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Theme.of(context).dividerColor),
              ),
              child: Column(
                children: [
                  _financialSummaryRow('الرصيد الافتتاحي', ledger.openingBalance),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  _financialSummaryRow('إجمالي المطالبات/الديون', ledger.totalCharges),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  _financialSummaryRow('إجمالي التسديدات', ledger.totalPayments),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  _financialSummaryRow(
                    'الرصيد الختامي',
                    ledger.closingBalance,
                    emphasized: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'حركات الشهر',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            if (ledger.transactions.isEmpty)
              const Text('لا توجد حركات مالية لهذا الشهر')
            else
              ...ledger.transactions.map(
                (transaction) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.account_balance_wallet_outlined),
                    title: Text(_financialTransactionLabel(transaction.type)),
                    subtitle: Text(
                      '${f(transaction.date)}'
                      '${transaction.note.trim().isEmpty ? '' : ' • ${transaction.note}'}',
                    ),
                    trailing: Text(
                      '${transaction.amount.toStringAsFixed(0)} د.ع',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _financialSummaryRow(
    String title,
    double amount, {
    bool emphasized = false,
  }) =>
      ListTile(
        dense: true,
        title: Text(
          title,
          style: TextStyle(
            fontWeight: emphasized ? FontWeight.w800 : FontWeight.w500,
          ),
        ),
        trailing: Text(
          '${amount.toStringAsFixed(0)} د.ع',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: emphasized ? Theme.of(context).colorScheme.primary : null,
          ),
        ),
      );

  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  dynamic _pick(List<String> keys) {
    for (final key in keys) {
      final v = s.sasData[key];
      if (v != null && v.toString().trim().isNotEmpty) return v;
    }
    return null;
  }

  String _sas(List<String> keys, [String fallback = '—']) {
    final v = _pick(keys);
    return v == null ? fallback : v.toString();
  }

  String _formatSasBalance(String raw) {
    final n = double.tryParse(raw);
    if (n == null) return raw;
    return n.toStringAsFixed(0);
  }

  Widget infoRow(String label, String value, IconData icon, {Color? valueColor, VoidCallback? onTap}) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: const Color(0xFFE0E0E0)),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF607D8B), size: 21),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: TextStyle(color: Colors.grey.shade700))),
            Flexible(
              child: onTap == null
                  ? Text(
                      value.isEmpty ? '—' : value,
                      textAlign: TextAlign.left,
                      style: TextStyle(fontWeight: FontWeight.w600, color: valueColor),
                    )
                  : InkWell(
                      onTap: onTap,
                      child: Text(
                        value.isEmpty ? '—' : value,
                        textAlign: TextAlign.left,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: valueColor ?? Colors.blue,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      );

  Widget emptyTab(IconData icon, String title, String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 58, color: Colors.blueGrey.shade300),
              const SizedBox(height: 12),
              Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(text, textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade600)),
            ],
          ),
        ),
      );




  @override
  Widget build(BuildContext context) {
    final status = s.disabled ? 'معطل' : s.isActive ? 'فعال' : 'منتهي';
    final online = s.isOnline;
    Color statusColor;
    if (s.disabled) {
      statusColor = Colors.orange;
    } else if (s.endDate.isBefore(DateTime.now())) {
      statusColor = online ? Colors.red : Colors.orange;
    } else {
      statusColor = online ? Colors.blue : Colors.green;
    }
    final isSas = s.source == 'sas';

    final lastConnection = _sas([
      'last_connection', 'last_seen', 'last_login', 'last_online',
      'last_auth', 'last_activity', 'last_connection_date'
    ]);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(title: const Text('معلومات المشترك'), centerTitle: true),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
              color: const Color(0xFF34434D),
              child: Row(
                children: [
                  const CircleAvatar(radius: 34, child: Icon(Icons.person, size: 40)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.name, style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 3),
                        Text(s.user, style: const TextStyle(color: Colors.white70)),
                        const SizedBox(height: 7),
                        Wrap(
                          spacing: 8,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(20)),
                              child: Text(status, style: TextStyle(color: statusColor, fontWeight: FontWeight.bold)),
                            ),
                            if (isSas)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(20)),
                                child: const Text('SAS', style: TextStyle(color: Colors.lightBlueAccent, fontWeight: FontWeight.bold)),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Material(
              color: Theme.of(context).colorScheme.surface,
              child: TabBar(
                controller: tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: const [
                  Tab(text: 'عام'),
                  Tab(text: 'عمليات الديون'),
                  Tab(text: 'فواتير'),
                  Tab(text: 'مدفوعات'),
                  Tab(text: 'الحساب المالي'),
                  Tab(text: 'تعديل'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: tabs,
                children: [
                  ListView(
                    padding: const EdgeInsets.all(14),
                    children: [
                      infoRow('اسم الدخول', s.user, Icons.person_outline),
                      infoRow('رقم الهاتف', s.phone, Icons.phone_outlined),
                      infoRow('العنوان', s.address, Icons.location_on_outlined),
                      infoRow(
                        'IP',
                        s.ip,
                        Icons.language,
                        valueColor: Colors.blue,
                        onTap: () async {
                          final ip = s.ip.trim();
                          if (ip.isEmpty) return;
                          String url;
                          if (ip.contains(':') && !ip.startsWith('[')) {
                            url = 'http://[$ip]';
                          } else {
                            url = 'http://$ip';
                          }
                          final uri = Uri.parse(url);
                          try {
                            await launchUrl(uri, mode: LaunchMode.externalApplication);
                          } catch (_) {}
                        },
                      ),
                      infoRow('الباقة', s.packageDisplay, Icons.inventory_2_outlined),
                      infoRow('تاريخ الانتهاء', f(s.endDate), Icons.event_outlined),
                      infoRow('الحالة', _sas(['status', 'state', 'user_status'], status), Icons.info_outline),
                      if (isSas) infoRow('معرف SAS', s.sasId, Icons.fingerprint),
                      if (isSas) infoRow('تابع إلى', _sas(['parent_name','parent','manager_name','reseller_name']), Icons.account_tree_outlined),
                      if (isSas) infoRow('الأيام المقترضة', _sas(['loan_days','borrowed_days','debt_days'], '0'), Icons.calendar_month_outlined),
                      if (isSas) infoRow('آخر اتصال', lastConnection, Icons.history),
                    ],
                  ),
                  _debtOperationsTab(),
                  Builder(
                    builder: (_) {
                      final allInvoices = _sortedInvoices();
                        final options = _recordsMonthOptions();
                        final effectiveFilter = options.contains(_recordsMonthFilter)
                          ? _recordsMonthFilter
                          : 'all';
                      final invoices = effectiveFilter == 'all'
                          ? allInvoices
                          : allInvoices.where((inv) => inv.monthKey == effectiveFilter).toList();

                      final monthlyTotals = <String, double>{};
                      for (final inv in invoices) {
                        monthlyTotals[inv.monthKey] = (monthlyTotals[inv.monthKey] ?? 0) + inv.amount;
                      }
                      final monthlyInvoices = monthlyTotals.entries.toList()
                        ..sort((a, b) => b.key.compareTo(a.key));

                      return ListView(
                        padding: const EdgeInsets.all(14),
                        children: [
                          infoRow('مبلغ الاشتراك', s.price.toStringAsFixed(0), Icons.receipt_long_outlined),
                          _paidAndDueSummary(context),
                          infoRow('تاريخ التفعيل', f(s.startDate), Icons.event_outlined),
                          infoRow('تاريخ التسديد', s.paymentDate.isEmpty ? 'غير محدد' : s.paymentDate, Icons.event_available_outlined),
                          if (isSas) infoRow('balance', _formatSasBalance(_sas(['balance','credit','user_balance'])), Icons.account_balance_wallet_outlined),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(child: _recordsMonthSelector(
                                options: options,
                                selectedMonth: effectiveFilter,
                              )),
                              const SizedBox(width: 10),
                              FilledButton.icon(
                                onPressed: () => _exportInvoicesCsv(invoices, effectiveFilter),
                                icon: const Icon(Icons.download_outlined),
                                label: const Text('تصدير'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Text('الفواتير الشهرية', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 8),
                          if (monthlyInvoices.isEmpty)
                            const Text('لا توجد فواتير مسجلة بعد')
                          else
                            ...monthlyInvoices.map(
                              (e) => Card(
                                child: ListTile(
                                  leading: const Icon(Icons.calendar_month),
                                  title: Text(_monthLabel(e.key)),
                                  trailing: Text('${e.value.toStringAsFixed(0)} د.ع', style: const TextStyle(fontWeight: FontWeight.bold)),
                                ),
                              ),
                            ),
                          const SizedBox(height: 8),
                          const Text('سجل الفواتير', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 8),
                          if (invoices.isEmpty)
                            const Text('لا يوجد سجل فواتير حتى الآن')
                          else
                            ...invoices.map(
                              (inv) => Card(
                                child: ListTile(
                                  leading: const CircleAvatar(child: Icon(Icons.receipt_long_outlined)),
                                  title: Text('وصل رقم ${inv.receiptNumber.toString().padLeft(6, '0')}'),
                                  subtitle: Text('${f(inv.at)} • ${_monthLabel(inv.monthKey)}${inv.note.isEmpty ? '' : ' • ${inv.note}'}'),
                                  trailing: Text('${inv.amount.toStringAsFixed(0)} د.ع', style: const TextStyle(fontWeight: FontWeight.bold)),
                                  onTap: () async {
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ReceiptScreen(
                                          subscriber: s,
                                          invoice: inv,
                                        ),
                                      ),
                                    );
                                    if (mounted) setState(() {});
                                  },
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  Builder(
                    builder: (_) {
                      final allPayments = _sortedPayments();
                        final options = _recordsMonthOptions();
                        final effectiveFilter = options.contains(_recordsMonthFilter)
                          ? _recordsMonthFilter
                          : 'all';
                      final payments = effectiveFilter == 'all'
                          ? allPayments
                          : allPayments
                              .where((p) => Subscriber.monthKeyOf(p.at) == effectiveFilter)
                              .toList();

                      final monthlyTotals = <String, double>{};
                      for (final p in payments) {
                        final key = Subscriber.monthKeyOf(p.at);
                        monthlyTotals[key] = (monthlyTotals[key] ?? 0) + p.amount;
                      }
                      final monthlyPaid = monthlyTotals.entries.toList()
                        ..sort((a, b) => b.key.compareTo(a.key));

                      return ListView(
                        padding: const EdgeInsets.all(14),
                        children: [
                          _paidAndDueSummary(context),
                          infoRow('تاريخ التسديد', s.paymentDate.isEmpty ? 'غير محدد' : s.paymentDate, Icons.event_available_outlined),
                          if (isSas) infoRow('آخر دفعة SAS', _sas(['last_payment','last_payment_date','payment_date']), Icons.payments_outlined),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(child: _recordsMonthSelector(
                                options: options,
                                selectedMonth: effectiveFilter,
                              )),
                              const SizedBox(width: 10),
                              FilledButton.icon(
                                onPressed: () => _exportPaymentsCsv(payments, effectiveFilter),
                                icon: const Icon(Icons.download_outlined),
                                label: const Text('تصدير'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Text('المدفوعات حسب الأشهر', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 8),
                          if (monthlyPaid.isEmpty)
                            const Text('لا توجد مدفوعات مسجلة بعد')
                          else
                            ...monthlyPaid.map(
                              (e) => Card(
                                child: ListTile(
                                  leading: const Icon(Icons.calendar_today_outlined),
                                  title: Text(_monthLabel(e.key)),
                                  trailing: Text('${e.value.toStringAsFixed(0)} د.ع', style: const TextStyle(fontWeight: FontWeight.bold)),
                                ),
                              ),
                            ),
                          const SizedBox(height: 8),
                          const Text('سجل المدفوعات', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 8),
                          if (payments.isEmpty)
                            const Text('لا يوجد سجل دفعات حتى الآن')
                          else
                            ...payments.map(
                              (p) => Card(
                                child: ListTile(
                                  leading: const CircleAvatar(child: Icon(Icons.payments_outlined)),
                                  title: Text('${p.amount.toStringAsFixed(0)} د.ع', style: const TextStyle(fontWeight: FontWeight.bold)),
                                  subtitle: Text('${f(p.at)} • ${_monthLabel(Subscriber.monthKeyOf(p.at))}${p.note.isEmpty ? '' : ' • ${p.note}'}'),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  _financialLedgerTab(),
                  Center(
                    child: FilledButton.icon(
                      onPressed: () async {
                        final changed = await Navigator.push<bool>(
                          context,
                          MaterialPageRoute(builder: (_) => AddSubscriberScreen(subscriber: s)),
                        );
                        if (changed == true && mounted) setState(() {});
                      },
                      icon: const Icon(Icons.edit),
                      label: const Text('تعديل بيانات المشترك'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
