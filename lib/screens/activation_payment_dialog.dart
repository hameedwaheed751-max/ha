import 'package:flutter/material.dart';
import '../models.dart';
import '../services/finance_ledger.dart';

typedef ActivationPayment = ({
  double saleAmount,
  double collected,
  ActivationSettlement settlement,
});

class ActivationPaymentDialog extends StatefulWidget {
  const ActivationPaymentDialog({
    super.key,
    required this.subscriber,
    required this.suggestedPrice,
  });

  final Subscriber subscriber;
  final double suggestedPrice;

  @override
  State<ActivationPaymentDialog> createState() =>
      _ActivationPaymentDialogState();
}

class _ActivationPaymentDialogState extends State<ActivationPaymentDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _priceController;
  final _partialController = TextEditingController();
  ActivationSettlement _settlement = ActivationSettlement.paidOnActivation;

  @override
  void initState() {
    super.initState();
    _priceController = TextEditingController(
      text: widget.suggestedPrice > 0
          ? widget.suggestedPrice.toStringAsFixed(0)
          : '',
    );
  }

  @override
  void dispose() {
    _priceController.dispose();
    _partialController.dispose();
    super.dispose();
  }

  double _amount(String raw) {
    var normalized = raw.trim().replaceAll(',', '').replaceAll('٬', '');
    const arabicDigits = '٠١٢٣٤٥٦٧٨٩';
    for (var digit = 0; digit < arabicDigits.length; digit++) {
      normalized = normalized.replaceAll(arabicDigits[digit], '$digit');
    }
    final value = double.tryParse(normalized);
    return value != null && value.isFinite ? value : 0;
  }

  double get _price => _amount(_priceController.text);

  double get _collected => switch (_settlement) {
    ActivationSettlement.paidOnActivation => _price,
    ActivationSettlement.partialPayment => _amount(_partialController.text),
    ActivationSettlement.fullDebt => 0,
  };

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final ActivationPayment payment = (
      saleAmount: _price,
      collected: _collected,
      settlement: _settlement,
    );
    Navigator.pop(context, payment);
  }

  Widget _summaryRow(String label, double amount, Color? color) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(label),
      Text(
        '${amount.toStringAsFixed(0)} د.ع',
        style: TextStyle(fontWeight: FontWeight.w800, color: color),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final subscriber = widget.subscriber;
    final newDebt = (_price - _collected).clamp(0, double.infinity).toDouble();
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        scrollable: true,
        title: Text('تفعيل ${subscriber.name}'),
        content: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('الباقة: ${subscriber.packageDisplay}'),
              if (subscriber.carriedDebt > 0.0001)
                Text(
                  'دين سابق: ${subscriber.carriedDebt.toStringAsFixed(0)} د.ع',
                  style: TextStyle(color: Colors.orange.shade800),
                ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _priceController,
                autofocus: widget.suggestedPrice <= 0,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'مبلغ الاشتراك',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
                validator: (_) =>
                    _price <= 0 ? 'أدخل مبلغ الاشتراك' : null,
              ),
              const SizedBox(height: 12),
              const Text(
                'كيف دفع المشترك؟',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final settlement in ActivationSettlement.values)
                    ChoiceChip(
                      label: Text(settlement.label),
                      selected: _settlement == settlement,
                      onSelected: (_) =>
                          setState(() => _settlement = settlement),
                    ),
                ],
              ),
              if (_settlement == ActivationSettlement.partialPayment) ...[
                const SizedBox(height: 10),
                TextFormField(
                  controller: _partialController,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'المبلغ الواصل',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                  validator: (_) {
                    final partial = _amount(_partialController.text);
                    if (partial <= 0 || partial >= _price) {
                      return 'أدخل مبلغاً أقل من مبلغ الاشتراك';
                    }
                    return null;
                  },
                ),
              ],
              const SizedBox(height: 12),
              _summaryRow('يُسجل في الواصل', _collected, Colors.green.shade700),
              _summaryRow('يُسجل في الديون', newDebt, Colors.red.shade700),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(onPressed: _submit, child: const Text('تفعيل')),
        ],
      ),
    );
  }
}
