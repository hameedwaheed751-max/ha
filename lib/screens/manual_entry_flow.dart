import 'package:flutter/material.dart';
import '../models.dart';
import '../services/subscriber_financial_ledger.dart';

String _date(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

typedef ManualEntryResult = ({
  String category,
  double amount,
  double paid,
  String description,
});

/// تملك النافذة حقولها حتى تبقى صالحة طوال حركة الإغلاق.
class ManualEntryDialog extends StatefulWidget {
  const ManualEntryDialog({super.key, required this.subscriberName});

  final String subscriberName;

  @override
  State<ManualEntryDialog> createState() => _ManualEntryDialogState();
}

class _ManualEntryDialogState extends State<ManualEntryDialog> {
  final _formKey = GlobalKey<FormState>();
  final _descriptionController = TextEditingController();
  final _amountController = TextEditingController();
  final _paidController = TextEditingController(text: '0');
  String _category = DailyTaskEvent.manualDebtCategory;

  bool get _isPurchase => _category == DailyTaskEvent.purchaseCategory;

  @override
  void dispose() {
    _descriptionController.dispose();
    _amountController.dispose();
    _paidController.dispose();
    super.dispose();
  }

  double? _parseAmount(String raw) {
    var normalized = raw.trim().replaceAll(',', '').replaceAll('٬', '');
    const arabicDigits = '٠١٢٣٤٥٦٧٨٩';
    for (var digit = 0; digit < arabicDigits.length; digit++) {
      normalized = normalized.replaceAll(arabicDigits[digit], '$digit');
    }
    return double.tryParse(normalized);
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final ManualEntryResult result = (
      category: _category,
      amount: _parseAmount(_amountController.text)!,
      paid: _isPurchase ? _parseAmount(_paidController.text)! : 0.0,
      description: _descriptionController.text.trim(),
    );
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        scrollable: true,
        title: Text('إضافة دين أو مشتريات - ${widget.subscriberName}'),
        content: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: DailyTaskEvent.manualDebtCategory,
                    label: Text('دين مضاف'),
                  ),
                  ButtonSegment(
                    value: DailyTaskEvent.purchaseCategory,
                    label: Text('مشتريات'),
                  ),
                ],
                selected: {_category},
                showSelectedIcon: false,
                onSelectionChanged: (selection) =>
                    setState(() => _category = selection.first),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _descriptionController,
                autofocus: true,
                maxLength: 200,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'الوصف',
                  hintText: 'مثال: راوتر أو كيبل أو مبلغ سابق',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'اكتب الوصف'
                    : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'المبلغ',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  final amount = _parseAmount(value ?? '');
                  if (amount == null || !amount.isFinite || amount <= 0) {
                    return 'أدخل مبلغاً أكبر من صفر';
                  }
                  return null;
                },
              ),
              if (_isPurchase) ...[
                const SizedBox(height: 10),
                TextFormField(
                  controller: _paidController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'الواصل منه',
                    helperText: 'صفر يعني أن المبلغ كله دين',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    final paid = _parseAmount(value ?? '');
                    final amount = _parseAmount(_amountController.text);
                    if (paid == null ||
                        !paid.isFinite ||
                        paid < 0 ||
                        (amount != null && paid > amount)) {
                      return 'الواصل يجب أن يكون بين صفر والمبلغ';
                    }
                    return null;
                  },
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(onPressed: _submit, child: const Text('حفظ')),
        ],
      ),
    );
  }
}

/// مسار إضافة الدين والمشتريات الوحيد لملف المشترك وقائمة الديون.
Future<void> recordManualEntry(BuildContext context, Subscriber s) async {
  final entry = await showDialog<ManualEntryResult>(
    context: context,
    builder: (_) => ManualEntryDialog(subscriberName: s.name),
  );
  if (entry == null) return;

  final now = DateTime.now();
  s.rolloverToMonth(now);
  // يُضاف خارج مبلغ الاشتراك حتى لا يدخل في مبيعات الاشتراكات وربحها.
  s.carriedDebt += entry.amount;
  final allocation = s.applyPayment(
    entry.paid,
    at: now,
    note: entry.description,
  );
  final collected = allocation.totalApplied;
  final unpaid = entry.amount - collected;

  int? receiptNumber;
  if (collected > 0.0001) {
    receiptNumber = await AppStore.issueReceiptNumber(persist: false);
    s.registerInvoiceFromPayment(
      receiptNumber: receiptNumber,
      amount: collected,
      at: now,
      note: entry.description,
    );
    s.paymentDate = _date(now);
    await AppStore.addDailyTaskEvent(
      DailyTaskEvent(
        type: DailyTaskEvent.debtEntryCollectionType,
        subscriberUser: s.user,
        subscriberName: s.name,
        at: now,
        amount: collected,
        remainingAfter: s.remaining,
        note: entry.description,
        category: entry.category,
      ),
      persist: false,
    );
  }
  if (unpaid > 0.0001) {
    await AppStore.addDailyTaskEvent(
      DailyTaskEvent(
        type: 'debt_added',
        subscriberUser: s.user,
        subscriberName: s.name,
        at: now,
        amount: unpaid,
        remainingAfter: s.remaining,
        note: entry.description,
        category: entry.category,
      ),
      persist: false,
    );
  }
  await AppStore.save();

  final stamp = now.toUtc().toIso8601String();
  try {
    final ledger = SubscriberFinancialLedger();
    await ledger.addTransaction(
      subscriberId: s.subscriberId,
      date: now,
      type: FinancialTransactionType.debt,
      amount: entry.amount,
      referenceId: 'manual-entry:${s.subscriberId}:$stamp',
      note: entry.description,
    );
    if (receiptNumber != null) {
      await ledger.addTransaction(
        subscriberId: s.subscriberId,
        date: now,
        type: FinancialTransactionType.payment,
        amount: collected,
        referenceId: 'payment-receipt:$receiptNumber',
        note: entry.description,
      );
    }
  } catch (error) {
    debugPrint('Financial ledger write failed: $error');
  }

  if (!context.mounted) return;
  final syncWarning = AppStore.lastSaveSyncError == null
      ? ''
      : ' | حُفظ محلياً وتعذرت المزامنة';
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        'تم الحفظ | المتبقي ${s.remaining.toStringAsFixed(0)} د.ع$syncWarning',
      ),
    ),
  );
}
