import 'package:flutter/material.dart';
import '../models.dart';
import '../services/subscriber_financial_ledger.dart';

double? _parseAmount(String raw) {
  final normalized = raw
      .trim()
      .replaceAll(',', '')
      .replaceAll(' ', '')
      .replaceAll('٠', '0')
      .replaceAll('١', '1')
      .replaceAll('٢', '2')
      .replaceAll('٣', '3')
      .replaceAll('٤', '4')
      .replaceAll('٥', '5')
      .replaceAll('٦', '6')
      .replaceAll('٧', '7')
      .replaceAll('٨', '8')
      .replaceAll('٩', '9')
      .replaceAll('٫', '.')
      .replaceAll('٬', '');
  if (normalized.isEmpty) return null;
  return double.tryParse(normalized);
}

String _date(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

/// مسار التسديد الجزئي الوحيد لقائمة الديون وملف المشترك.
Future<void> recordPartialPayment(BuildContext context, Subscriber s) async {
  final amountC = TextEditingController();
  final before = s.remaining;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text('تسديد جزئي - ${s.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'المتبقي الحالي: ${moneyText(before)}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: amountC,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'مبلغ الدفعة',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('تسديد'),
          ),
        ],
      ),
    ),
  );
  if (ok != true) return;
  final amount = _parseAmount(amountC.text.trim()) ?? 0;
  if (amount <= 0 || amount > before) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('مبلغ الدفعة غير صحيح')));
    }
    return;
  }
  await _savePayment(context, s, amount, DateTime.now(), null);
}

/// يسجل الدفعة ووصلها، وترجع القيمة المسجلة فعلاً.
Future<double> _savePayment(
  BuildContext context,
  Subscriber s,
  double amount,
  DateTime now,
  String? note,
) async {
  final allocation = s.applyPayment(amount, at: now, note: note);
  final applied = allocation.totalApplied;
  if (applied <= 0) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تعذر تسجيل الدفعة')));
    }
    return 0;
  }

  final receiptNumber = await AppStore.issueReceiptNumber(persist: false);
  s.registerInvoiceFromPayment(
    receiptNumber: receiptNumber,
    amount: applied,
    at: now,
    note:
        note ??
        (s.remaining <= 0.0001 ? 'فاتورة تسديد كامل' : 'فاتورة تسديد جزئي'),
  );
  if (allocation.appliedToCarriedDebt > 0.0001) {
    await AppStore.addDailyTaskEvent(
      DailyTaskEvent(
        type: 'debt_payment',
        subscriberUser: s.user,
        subscriberName: s.name,
        at: now,
        amount: allocation.appliedToCarriedDebt,
        remainingAfter: s.remaining,
        note: note ?? 'تسديد دين مرحّل من الأشهر السابقة',
      ),
      persist: false,
    );
  }
  if (allocation.appliedToCurrentCharge > 0.0001) {
    await AppStore.addDailyTaskEvent(
      DailyTaskEvent(
        type: DailyTaskEvent.debtEntryCollectionType,
        subscriberUser: s.user,
        subscriberName: s.name,
        at: now,
        amount: allocation.appliedToCurrentCharge,
        remainingAfter: s.remaining,
        note: 'واصل من اشتراك الشهر الحالي',
      ),
      persist: false,
    );
  }
  s.paymentDate = _date(now);
  await AppStore.save();
  try {
    await SubscriberFinancialLedger().addTransaction(
      subscriberId: s.subscriberId,
      date: now,
      type: FinancialTransactionType.payment,
      amount: applied,
      referenceId: 'payment-receipt:$receiptNumber',
      note: note ?? (s.remaining <= 0.0001 ? 'تسديد كامل' : 'تسديد جزئي'),
    );
  } catch (error) {
    debugPrint('Financial ledger write failed: $error');
  }
  if (context.mounted && AppStore.lastSaveSyncError != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم حفظ الدفعة محلياً، لكن تعذرت المزامنة')),
    );
  }
  return applied;
}

typedef CarriedDebtCorrection = ({double newAmount, String reason});

/// تملك النافذة حقولها حتى تبقى صالحة طوال حركة الإغلاق.
class CarriedDebtCorrectionDialog extends StatefulWidget {
  const CarriedDebtCorrectionDialog({
    super.key,
    required this.subscriberName,
    required this.currentAmount,
  });

  final String subscriberName;
  final double currentAmount;

  @override
  State<CarriedDebtCorrectionDialog> createState() =>
      _CarriedDebtCorrectionDialogState();
}

class _CarriedDebtCorrectionDialogState
    extends State<CarriedDebtCorrectionDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _amountController = TextEditingController(
    text: widget.currentAmount.toStringAsFixed(0),
  );
  final _reasonController = TextEditingController();

  @override
  void dispose() {
    _amountController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  String get _effectText {
    final amount = _parseAmount(_amountController.text);
    if (amount == null || amount < 0) return '';
    final difference = amount - widget.currentAmount;
    if (difference.abs() < 0.5) return 'لا يوجد تغيير';
    return difference < 0
        ? 'سيسجل ${moneyText(-difference)} في الواصل ويصدر له وصل'
        : 'سيضاف ${moneyText(difference)} إلى الديون';
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop<CarriedDebtCorrection>(context, (
      newAmount: _parseAmount(_amountController.text)!,
      reason: _reasonController.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text('تصحيح الدين المرحّل - ${widget.subscriberName}'),
        content: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'الدين المرحّل الحالي: ${moneyText(widget.currentAmount)}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _amountController,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) => setState(() {}),
                  validator: (value) {
                    final amount = _parseAmount(value ?? '');
                    return amount == null || amount < 0
                        ? 'اكتب مبلغاً صحيحاً'
                        : null;
                  },
                  decoration: const InputDecoration(
                    labelText: 'الدين المرحّل الصحيح',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _reasonController,
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? 'سبب التصحيح مطلوب' : null,
                  decoration: const InputDecoration(
                    labelText: 'سبب التصحيح',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _effectText,
                  style: TextStyle(color: Colors.orange.shade800),
                ),
              ],
            ),
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

/// تخفيض الدين المرحّل مبلغ واصل له وصل، وزيادته دين مضاف.
Future<void> recordCarriedDebtCorrection(
  BuildContext context,
  Subscriber s,
) async {
  final before = s.carriedDebt;
  final correction = await showDialog<CarriedDebtCorrection>(
    context: context,
    builder: (_) => CarriedDebtCorrectionDialog(
      subscriberName: s.name,
      currentAmount: before,
    ),
  );
  if (correction == null) return;
  final difference = correction.newAmount - before;
  if (difference.abs() < 0.5) return;

  final now = DateTime.now();
  final note =
      'تصحيح دين مرحّل من ${moneyText(before)} '
      'إلى ${moneyText(correction.newAmount)}: ${correction.reason}';
  if (difference < 0) {
    final applied = await _savePayment(context, s, -difference, now, note);
    if (applied <= 0) return;
  } else {
    s.carriedDebt += difference;
    await AppStore.addDailyTaskEvent(
      DailyTaskEvent(
        type: 'debt_added',
        subscriberUser: s.user,
        subscriberName: s.name,
        at: now,
        amount: difference,
        remainingAfter: s.remaining,
        note: note,
        category: DailyTaskEvent.manualDebtCategory,
      ),
      persist: false,
    );
    await AppStore.save();
    try {
      await SubscriberFinancialLedger().addTransaction(
        subscriberId: s.subscriberId,
        date: now,
        type: FinancialTransactionType.debt,
        amount: difference,
        referenceId:
            'carried-debt-correction:${s.subscriberId}:${now.toUtc().toIso8601String()}',
        note: note,
      );
    } catch (error) {
      debugPrint('Financial ledger write failed: $error');
    }
  }

  if (!context.mounted) return;
  final syncWarning = AppStore.lastSaveSyncError == null
      ? ''
      : ' | حُفظ محلياً وتعذرت المزامنة';
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        'تم التصحيح | المتبقي ${moneyText(s.remaining)}$syncWarning',
      ),
    ),
  );
}
