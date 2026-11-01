import 'dart:convert';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models.dart';
import '../services/subscriber_financial_ledger.dart';
import 'add_subscriber_screen.dart';
import 'dashboard_widgets.dart';
import 'manual_entry_flow.dart';
import 'receipt_screen.dart';

class CancelEntryDialog extends StatefulWidget {
  const CancelEntryDialog({
    super.key,
    required this.description,
    required this.amount,
  });

  final String description;
  final double amount;

  @override
  State<CancelEntryDialog> createState() => _CancelEntryDialogState();
}

class _CancelEntryDialogState extends State<CancelEntryDialog> {
  final _formKey = GlobalKey<FormState>();
  final _reasonController = TextEditingController();

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(context, _reasonController.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        scrollable: true,
        title: const Text('إلغاء العملية'),
        content: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${widget.description} - ${widget.amount.toStringAsFixed(0)} د.ع',
              ),
              const SizedBox(height: 4),
              const Text('تبقى العملية ظاهرة بعلامة ملغاة، ويعود الدين كما كان.'),
              const SizedBox(height: 12),
              TextFormField(
                controller: _reasonController,
                autofocus: true,
                maxLength: 200,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'سبب الإلغاء',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'اكتب سبب الإلغاء'
                    : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('رجوع'),
          ),
          FilledButton(onPressed: _submit, child: const Text('إلغاء العملية')),
        ],
      ),
    );
  }
}

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
  State<SubscriberDetailsScreen> createState() =>
      _SubscriberDetailsScreenState();
}

class _SubscriberDetailsScreenState extends State<SubscriberDetailsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController tabs;
  Subscriber get s => widget.subscriber;
  String _recordsMonthFilter = Subscriber.monthKeyOf(DateTime.now());

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

  String _invoiceMonthKey(InvoiceRecord invoice) => invoice.monthKey.isNotEmpty
      ? invoice.monthKey
      : Subscriber.monthKeyOf(invoice.at);

  List<String> _recordsMonthOptions() {
    final keys = <String>{
      Subscriber.monthKeyOf(DateTime.now()),
      ...s.invoices.map(_invoiceMonthKey),
      ...s.payments.map((payment) => Subscriber.monthKeyOf(payment.at)),
    };
    final sortedKeys = keys.toList()..sort((a, b) => b.compareTo(a));
    return <String>['all', ...sortedKeys];
  }

  InvoiceRecord? _invoiceForPayment(PaymentRecord payment) {
    for (final invoice in s.invoices) {
      if (invoice.at.isAtSameMomentAs(payment.at) &&
          (invoice.amount - payment.amount).abs() <= 0.0001) {
        return invoice;
      }
    }
    return null;
  }

  Future<void> _openInvoice(InvoiceRecord invoice) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReceiptScreen(subscriber: s, invoice: invoice),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _recordsTotal(
    BuildContext context, {
    required String label,
    required String monthFilter,
    required double amount,
    required int count,
    required IconData icon,
  }) {
    final period = monthFilter == 'all'
        ? 'كل الأشهر'
        : _monthLabel(monthFilter);
    return _balanceSummaryItem(
      context,
      label: '$label - $period ($count)',
      amount: amount,
      color: Colors.teal,
      icon: icon,
    );
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
            label: 'واصل الشهر الحالي',
            amount: s.paid,
            color: Colors.green,
            icon: Icons.check_circle_outline_rounded,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _balanceSummaryItem(
            context,
            label: 'إجمالي المتبقي مع الدين المرحّل',
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

  Future<void> _exportInvoicesCsv(
    List<InvoiceRecord> invoices,
    String monthFilter,
  ) async {
    if (invoices.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('لا توجد فواتير للتصدير حسب الفلتر المختار'),
        ),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تم تصدير الفواتير بنجاح')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر تصدير الملف، حاول مرة أخرى')),
      );
    }
  }

  Future<void> _exportPaymentsCsv(
    List<PaymentRecord> payments,
    String monthFilter,
  ) async {
    if (payments.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('لا توجد مدفوعات للتصدير حسب الفلتر المختار'),
        ),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تم تصدير المدفوعات بنجاح')));
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
    tabs = TabController(length: 5, vsync: this);
  }

  List<DailyTaskEvent> _matchingSubscriberDebtEvents() {
    final subscriberUser = s.user.trim().toLowerCase();
    final subscriberName = s.name.trim().toLowerCase();
    final operations = AppStore.dailyTaskEvents.where((event) {
      if (event.type != 'debt_added' &&
          event.type != DailyTaskEvent.debtRemovedType &&
          event.type != 'debt_payment' &&
          event.type != DailyTaskEvent.debtEntryCollectionType &&
          event.type != DailyTaskEvent.debtEditType &&
          event.type != 'activation') {
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
    return _matchingSubscriberDebtEvents()
        .where((event) => event.type != DailyTaskEvent.debtEditType)
        .toList();
  }

  String _formatDebtEditNote(String note) => note
      .split(' | ')
      .map(
        (detail) =>
            detail.replaceFirst(': ', ': قبل ').replaceFirst(' -> ', ' | بعد '),
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

  Future<void> _addManualEntry() async {
    await recordManualEntry(context, s);
    if (mounted) setState(() {});
  }

  Widget _addEntryButton() {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: _addManualEntry,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.add, color: Colors.blueGrey),
            const SizedBox(width: 4),
            Text(
              'إضافة',
              style: TextStyle(
                color: colors.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _manualEntriesSection(List<DailyTaskEvent> entries) {
    final operations = <int, List<DailyTaskEvent>>{};
    for (final event in entries) {
      operations
          .putIfAbsent(event.at.microsecondsSinceEpoch, () => [])
          .add(event);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'الديون المضافة والمشتريات',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        const SizedBox(height: 8),
        if (entries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('لا توجد ديون مضافة أو مشتريات مسجلة.'),
          ),
        ...operations.values.map(_manualEntryCard),
      ],
    );
  }

  Widget _manualEntryCard(List<DailyTaskEvent> operation) {
    final first = operation.first;
    final isPurchase = first.category == DailyTaskEvent.purchaseCategory;
    final isCancelled = operation.any((event) => event.isCancelled);
    final unpaid = operation
        .where((event) => event.type == 'debt_added')
        .fold<double>(0, (sum, event) => sum + event.amount);
    final collected = operation
        .where((event) => event.type != 'debt_added')
        .fold<double>(0, (sum, event) => sum + event.amount);
    final total = unpaid + collected;
    final cancelReason = operation
        .map((event) => event.cancelReason)
        .firstWhere((reason) => reason.isNotEmpty, orElse: () => '');
    final color = isCancelled
        ? Colors.blueGrey
        : unpaid > 0.0001
        ? Colors.red
        : Colors.green;
    TextSpan amountSpan(double amount, Color amountColor) => TextSpan(
      text: '${amount.toStringAsFixed(0)} د.ع',
      style: TextStyle(
        color: isCancelled ? Colors.blueGrey : amountColor,
        fontWeight: FontWeight.w800,
      ),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.12),
              child: Icon(
                isPurchase
                    ? Icons.shopping_bag_outlined
                    : Icons.add_card_outlined,
                color: color,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${isPurchase ? 'مشتريات' : 'دين مضاف'}'
                    '${isCancelled ? ' (ملغاة)' : ''}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text('${f(first.at)} • ${first.note.trim()}'),
                  if (isPurchase)
                    Text.rich(
                      TextSpan(
                        children: [
                          const TextSpan(text: 'الواصل '),
                          amountSpan(collected, Colors.green.shade700),
                          const TextSpan(text: ' • المتبقي '),
                          amountSpan(unpaid, Colors.red.shade700),
                        ],
                      ),
                    ),
                  if (isCancelled)
                    Text(
                      'سبب الإلغاء: $cancelReason',
                      style: const TextStyle(color: Colors.blueGrey),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${total.toStringAsFixed(0)} د.ع',
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w800,
                decoration: isCancelled ? TextDecoration.lineThrough : null,
              ),
            ),
            if (!isCancelled)
              IconButton(
                tooltip: 'إلغاء العملية',
                onPressed: () => _cancelManualEntry(first),
                icon: const Icon(Icons.cancel_outlined, size: 20),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _cancelPayment(DailyTaskEvent event) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => CancelEntryDialog(
        description: 'تسديد بتاريخ ${f(event.at)}',
        amount: event.amount,
      ),
    );
    if (reason == null) return;

    final now = DateTime.now();
    final double total;
    try {
      total = await AppStore.cancelPayment(
        s,
        at: event.at,
        reason: reason,
        now: now,
      );
    } on StateError catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
      return;
    }

    try {
      await SubscriberFinancialLedger().addTransaction(
        subscriberId: s.subscriberId,
        date: now,
        type: FinancialTransactionType.adjustment,
        amount: total,
        referenceId:
            'payment-cancel:${s.subscriberId}:${now.toUtc().toIso8601String()}',
        note: reason,
      );
    } catch (error) {
      debugPrint('Financial ledger write failed: $error');
    }

    if (!mounted) return;
    setState(() {});
    final syncWarning = AppStore.lastSaveSyncError == null
        ? ''
        : ' | حُفظ محلياً وتعذرت المزامنة';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'أُلغي التسديد | المتبقي ${s.remaining.toStringAsFixed(0)} د.ع$syncWarning',
        ),
      ),
    );
  }

  Future<void> _cancelManualEntry(DailyTaskEvent event) async {
    final related = AppStore.dailyTaskEvents.where(
      (entry) =>
          !entry.isCancelled &&
          entry.category == event.category &&
          entry.at.isAtSameMomentAs(event.at) &&
          entry.subscriberUser.trim().toLowerCase() ==
              s.user.trim().toLowerCase(),
    );
    final total = related.fold<double>(0, (sum, entry) => sum + entry.amount);
    final unpaid = related
        .where((entry) => entry.type == 'debt_added')
        .fold<double>(0, (sum, entry) => sum + entry.amount);

    final reason = await showDialog<String>(
      context: context,
      builder: (_) =>
          CancelEntryDialog(description: event.note.trim(), amount: total),
    );
    if (reason == null) return;

    final now = DateTime.now();
    try {
      await AppStore.cancelManualEntry(
        s,
        at: event.at,
        category: event.category,
        reason: reason,
        now: now,
      );
    } on StateError catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
      return;
    }

    if (unpaid > 0.0001) {
      try {
        await SubscriberFinancialLedger().addTransaction(
          subscriberId: s.subscriberId,
          date: now,
          type: FinancialTransactionType.adjustment,
          amount: -unpaid,
          referenceId:
              'manual-cancel:${s.subscriberId}:${now.toUtc().toIso8601String()}',
          note: reason,
        );
      } catch (error) {
        debugPrint('Financial ledger write failed: $error');
      }
    }

    if (!mounted) return;
    setState(() {});
    final syncWarning = AppStore.lastSaveSyncError == null
        ? ''
        : ' | حُفظ محلياً وتعذرت المزامنة';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'أُلغيت العملية | المتبقي ${s.remaining.toStringAsFixed(0)} د.ع$syncWarning',
        ),
      ),
    );
  }

  Widget _debtOperationsTab() {
    final operations = _subscriberDebtOperations();
    final manualEntries = operations
        .where((event) => event.category.isNotEmpty)
        .toList();
    final otherOperations = operations
        .where((event) => event.category.isEmpty)
        .toList();
    final currentMonthKey = Subscriber.monthKeyOf(DateTime.now());
    final monthEvents = operations.where(
      (event) =>
          !event.isCancelled &&
          Subscriber.monthKeyOf(event.at) == currentMonthKey,
    );

    final totalAdded = DailyTaskSummary.outstandingAddedDebt(
      _matchingSubscriberDebtEvents().where(
        (event) => Subscriber.monthKeyOf(event.at) == currentMonthKey,
      ),
    );
    final totalCollected = monthEvents
        .where(
          (event) =>
              event.type == 'debt_payment' ||
              event.type == DailyTaskEvent.debtEntryCollectionType ||
              event.type == 'activation',
        )
        .fold<double>(0, (total, event) => total + event.amount);
    final totalReduced = monthEvents
        .where((event) => event.type == DailyTaskEvent.debtRemovedType)
        .fold<double>(0, (total, event) => total + event.amount);

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        _balanceSummaryItem(
          context,
          label: 'إجمالي الدين على المشترك',
          amount: s.remaining,
          color: s.remaining > 0.0001 ? Colors.red : Colors.green,
          icon: Icons.account_balance_wallet_outlined,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _debtOperationTotal(
                label: 'الديون المضافة هذا الشهر',
                amount: totalAdded,
                color: Colors.red,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _debtOperationTotal(
                label: 'الواصل هذا الشهر',
                amount: totalCollected,
                color: Colors.green,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _debtOperationTotal(
                label: 'تخفيض الدين هذا الشهر',
                amount: totalReduced,
                color: Colors.blueGrey,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            DebtOperationsMenu(
              subscriber: s,
              onEdit: widget.onEditDebt == null
                  ? null
                  : (subscriber) =>
                        _runDebtAction(widget.onEditDebt, subscriber),
              onAddAmount: (_) => _addManualEntry(),
              onPartialPayment: widget.onPartialDebtPayment == null
                  ? null
                  : (subscriber) =>
                        _runDebtAction(widget.onPartialDebtPayment, subscriber),
              showLabel: true,
            ),
            const SizedBox(width: 8),
            _addEntryButton(),
          ],
        ),
        const SizedBox(height: 14),
        _manualEntriesSection(manualEntries),
        const SizedBox(height: 14),
        const Text(
          'سجل العمليات',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        const SizedBox(height: 8),
        if (otherOperations.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Text('لا توجد عمليات سابقة مسجلة لهذا المشترك.'),
          ),
        ...otherOperations.map((event) {
          final isDebtAdded = event.type == 'debt_added';
          final isDebtEdit = event.type == DailyTaskEvent.debtEditType;
          final isDebtRemoved = event.type == DailyTaskEvent.debtRemovedType;
          final isActivation = event.type == 'activation';
          final color = isDebtEdit
              ? Colors.blue
              : isDebtAdded
              ? Colors.red
              : isDebtRemoved
              ? Colors.blueGrey
              : isActivation
              ? Colors.teal
              : Colors.green;
          final title = isDebtEdit
              ? 'تعديل مبالغ الاشتراك'
              : isDebtAdded
              ? 'إضافة دين'
              : isDebtRemoved
              ? 'تخفيض دين'
              : isActivation
              ? 'واصل عند التفعيل'
              : event.type == DailyTaskEvent.debtEntryCollectionType
              ? 'واصل عند التفعيل'
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
                      : isDebtRemoved
                      ? Icons.remove_circle_outline
                      : isActivation
                      ? Icons.check_circle_outline
                      : Icons.payments_outlined,
                  color: color,
                ),
              ),
              title: Text(event.isCancelled ? '$title (ملغاة)' : title),
              isThreeLine: isDebtEdit,
              subtitle: isDebtEdit
                  ? Text(
                      '${f(event.at)}\n${_formatDebtEditNote(event.note)}',
                      style: const TextStyle(height: 1.45),
                    )
                  : Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: f(event.at)),
                          if (event.remainingAfter > 0) ...[
                            const TextSpan(text: ' • المتبقي '),
                            TextSpan(
                              text:
                                  '${event.remainingAfter.toStringAsFixed(0)} د.ع',
                              style: TextStyle(
                                color: Colors.red.shade700,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                          if (event.note.trim().isNotEmpty)
                            TextSpan(text: ' • ${event.note.trim()}'),
                          if (event.isCancelled)
                            TextSpan(
                              text: ' • سبب الإلغاء: ${event.cancelReason}',
                              style: const TextStyle(color: Colors.blueGrey),
                            ),
                        ],
                      ),
                    ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isDebtEdit
                        ? 'تم التعديل'
                        : '${event.amount.toStringAsFixed(0)} د.ع',
                    style: TextStyle(
                      color: event.isCancelled ? Colors.blueGrey : color,
                      fontWeight: FontWeight.w800,
                      decoration: event.isCancelled
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                  if (AppStore.canCancelPayment(s, event))
                    IconButton(
                      tooltip: 'إلغاء التسديد',
                      onPressed: () => _cancelPayment(event),
                      icon: const Icon(Icons.cancel_outlined, size: 20),
                    ),
                ],
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
          Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '${amount.toStringAsFixed(0)} د.ع',
            style: TextStyle(
              color: color,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

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

  Widget infoRow(
    String label,
    String value,
    IconData icon, {
    Color? valueColor,
    VoidCallback? onTap,
  }) => Container(
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
        Expanded(
          child: Text(label, style: TextStyle(color: Colors.grey.shade700)),
        ),
        Flexible(
          child: onTap == null
              ? Text(
                  value.isEmpty ? '—' : value,
                  textAlign: TextAlign.left,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: valueColor,
                  ),
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
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final status = s.disabled
        ? 'معطل'
        : s.isActive
        ? 'فعال'
        : 'منتهي';
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
      'last_connection',
      'last_seen',
      'last_login',
      'last_online',
      'last_auth',
      'last_activity',
      'last_connection_date',
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
                  const CircleAvatar(
                    radius: 34,
                    child: Icon(Icons.person, size: 40),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 21,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          s.user,
                          style: const TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(height: 7),
                        Wrap(
                          spacing: 8,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: statusColor.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                status,
                                style: TextStyle(
                                  color: statusColor,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            if (isSas)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.blue.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Text(
                                  'SAS',
                                  style: TextStyle(
                                    color: Colors.lightBlueAccent,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
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
                            await launchUrl(
                              uri,
                              mode: LaunchMode.externalApplication,
                            );
                          } catch (_) {}
                        },
                      ),
                      infoRow(
                        'الباقة',
                        s.packageDisplay,
                        Icons.inventory_2_outlined,
                      ),
                      infoRow(
                        'تاريخ الانتهاء',
                        f(s.endDate),
                        Icons.event_outlined,
                      ),
                      infoRow(
                        'الحالة',
                        _sas(['status', 'state', 'user_status'], status),
                        Icons.info_outline,
                      ),
                      if (isSas)
                        infoRow('معرف SAS', s.sasId, Icons.fingerprint),
                      if (isSas)
                        infoRow(
                          'تابع إلى',
                          _sas([
                            'parent_name',
                            'parent',
                            'manager_name',
                            'reseller_name',
                          ]),
                          Icons.account_tree_outlined,
                        ),
                      if (isSas)
                        infoRow(
                          'الأيام المقترضة',
                          _sas([
                            'loan_days',
                            'borrowed_days',
                            'debt_days',
                          ], '0'),
                          Icons.calendar_month_outlined,
                        ),
                      if (isSas)
                        infoRow('آخر اتصال', lastConnection, Icons.history),
                    ],
                  ),
                  _debtOperationsTab(),
                  Builder(
                    builder: (_) {
                      final allInvoices = _sortedInvoices();
                      final options = _recordsMonthOptions();
                      final effectiveFilter =
                          options.contains(_recordsMonthFilter)
                          ? _recordsMonthFilter
                          : 'all';
                      final invoices = effectiveFilter == 'all'
                          ? allInvoices
                          : allInvoices
                                .where(
                                  (inv) =>
                                      _invoiceMonthKey(inv) == effectiveFilter,
                                )
                                .toList();
                      final invoicesTotal = invoices
                          .where((inv) => !inv.cancelled)
                          .fold<double>(
                            0,
                            (total, inv) => total + inv.amount,
                          );

                      return ListView(
                        padding: const EdgeInsets.all(14),
                        children: [
                          infoRow(
                            'مبلغ الاشتراك',
                            s.price.toStringAsFixed(0),
                            Icons.receipt_long_outlined,
                          ),
                          _paidAndDueSummary(context),
                          infoRow(
                            'تاريخ التفعيل',
                            f(s.startDate),
                            Icons.event_outlined,
                          ),
                          infoRow(
                            'تاريخ التسديد',
                            s.paymentDate.isEmpty ? 'غير محدد' : s.paymentDate,
                            Icons.event_available_outlined,
                          ),
                          if (isSas)
                            infoRow(
                              'رصيد SAS',
                              _formatSasBalance(
                                _sas(['balance', 'credit', 'user_balance']),
                              ),
                              Icons.account_balance_wallet_outlined,
                            ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: _recordsMonthSelector(
                                  options: options,
                                  selectedMonth: effectiveFilter,
                                ),
                              ),
                              const SizedBox(width: 10),
                              FilledButton.icon(
                                onPressed: () => _exportInvoicesCsv(
                                  invoices,
                                  effectiveFilter,
                                ),
                                icon: const Icon(Icons.download_outlined),
                                label: const Text('تصدير'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _recordsTotal(
                            context,
                            label: 'إجمالي الفواتير',
                            monthFilter: effectiveFilter,
                            amount: invoicesTotal,
                            count: invoices.length,
                            icon: Icons.receipt_long_outlined,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'سجل الفواتير',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (invoices.isEmpty)
                            const Text('لا توجد فواتير في هذه الفترة')
                          else
                            ...invoices.map(
                              (inv) => Card(
                                child: ListTile(
                                  leading: const CircleAvatar(
                                    child: Icon(Icons.receipt_long_outlined),
                                  ),
                                  title: Text(
                                    'وصل رقم ${inv.receiptNumber.toString().padLeft(6, '0')}'
                                    '${inv.cancelled ? ' (ملغى)' : ''}',
                                  ),
                                  subtitle: Text(
                                    '${f(inv.at)}${inv.note.isEmpty ? '' : ' • ${inv.note}'}',
                                  ),
                                  trailing: Text(
                                    '${inv.amount.toStringAsFixed(0)} د.ع',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  onTap: () => _openInvoice(inv),
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
                      final effectiveFilter =
                          options.contains(_recordsMonthFilter)
                          ? _recordsMonthFilter
                          : 'all';
                      final payments = effectiveFilter == 'all'
                          ? allPayments
                          : allPayments
                                .where(
                                  (p) =>
                                      Subscriber.monthKeyOf(p.at) ==
                                      effectiveFilter,
                                )
                                .toList();
                      final paymentsTotal = payments.fold<double>(
                        0,
                        (total, p) => total + p.amount,
                      );

                      return ListView(
                        padding: const EdgeInsets.all(14),
                        children: [
                          _paidAndDueSummary(context),
                          infoRow(
                            'تاريخ التسديد',
                            s.paymentDate.isEmpty ? 'غير محدد' : s.paymentDate,
                            Icons.event_available_outlined,
                          ),
                          if (isSas)
                            infoRow(
                              'آخر دفعة SAS',
                              _sas([
                                'last_payment',
                                'last_payment_date',
                                'payment_date',
                              ]),
                              Icons.payments_outlined,
                            ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: _recordsMonthSelector(
                                  options: options,
                                  selectedMonth: effectiveFilter,
                                ),
                              ),
                              const SizedBox(width: 10),
                              FilledButton.icon(
                                onPressed: () => _exportPaymentsCsv(
                                  payments,
                                  effectiveFilter,
                                ),
                                icon: const Icon(Icons.download_outlined),
                                label: const Text('تصدير'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _recordsTotal(
                            context,
                            label: 'صافي المدفوعات',
                            monthFilter: effectiveFilter,
                            amount: paymentsTotal,
                            count: payments.length,
                            icon: Icons.payments_outlined,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'سجل المدفوعات',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (payments.isEmpty)
                            const Text('لا توجد مدفوعات في هذه الفترة')
                          else
                            ...payments.map((p) {
                              final isCorrection = p.amount < 0;
                              final invoice = _invoiceForPayment(p);
                              return Card(
                                child: ListTile(
                                  leading: CircleAvatar(
                                    child: Icon(
                                      isCorrection
                                          ? Icons.undo_rounded
                                          : Icons.payments_outlined,
                                    ),
                                  ),
                                  title: Text(
                                    isCorrection
                                        ? 'تصحيح واصل ${p.amount.abs().toStringAsFixed(0)} د.ع'
                                        : '${p.amount.toStringAsFixed(0)} د.ع',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: isCorrection ? Colors.red : null,
                                    ),
                                  ),
                                  subtitle: Text(
                                    '${f(p.at)}'
                                    '${invoice == null ? '' : ' • وصل ${invoice.receiptNumber.toString().padLeft(6, '0')}'}'
                                    '${p.note.isEmpty ? '' : ' • ${p.note}'}',
                                  ),
                                  trailing: invoice == null
                                      ? null
                                      : const Icon(Icons.receipt_long_outlined),
                                  onTap: invoice == null
                                      ? null
                                      : () => _openInvoice(invoice),
                                ),
                              );
                            }),
                        ],
                      );
                    },
                  ),
                  Center(
                    child: FilledButton.icon(
                      onPressed: () async {
                        final changed = await Navigator.push<bool>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => AddSubscriberScreen(subscriber: s),
                          ),
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
