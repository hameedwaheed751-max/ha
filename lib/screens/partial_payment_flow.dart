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
              'المتبقي الحالي: ${before.toStringAsFixed(0)} د.ع',
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
  final now = DateTime.now();
  final allocation = s.applyPayment(amount, at: now);
  final applied = allocation.totalApplied;
  if (applied <= 0) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تعذر تسجيل الدفعة')));
    }
    return;
  }

  final receiptNumber = await AppStore.issueReceiptNumber(persist: false);
  s.registerInvoiceFromPayment(
    receiptNumber: receiptNumber,
    amount: applied,
    at: now,
    note: s.remaining <= 0.0001 ? 'فاتورة تسديد كامل' : 'فاتورة تسديد جزئي',
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
        note: 'تسديد دين مرحّل من الأشهر السابقة',
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
      note: s.remaining <= 0.0001 ? 'تسديد كامل' : 'تسديد جزئي',
    );
  } catch (error) {
    debugPrint('Financial ledger write failed: $error');
  }
  if (context.mounted && AppStore.lastSaveSyncError != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم حفظ الدفعة محلياً، لكن تعذرت المزامنة')),
    );
  }
}
