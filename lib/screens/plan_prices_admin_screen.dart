import 'package:flutter/material.dart';

import '../services/payment_request_service.dart';

class PlanPricesAdminScreen extends StatefulWidget {
  const PlanPricesAdminScreen({
    super.key,
    this.loadPrices = PaymentPlanCatalog.loadPrices,
    this.savePrices = PaymentPlanCatalog.savePrices,
    this.savePaymentAccount = PaymentPlanCatalog.savePaymentAccount,
  });

  final Future<void> Function() loadPrices;
  final Future<void> Function(Map<String, String>) savePrices;
  final Future<void> Function(Map<String, String>) savePaymentAccount;

  @override
  State<PlanPricesAdminScreen> createState() => _PlanPricesAdminScreenState();
}

class _PlanPricesAdminScreenState extends State<PlanPricesAdminScreen> {
  final _formKey = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{
    for (final plan in PaymentPlanCatalog.paidPlans)
      plan: TextEditingController(),
  };
  final _accountController = TextEditingController();
  final _cardController = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _accountController.dispose();
    _cardController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      await widget.loadPrices();
      _controllers.forEach((plan, controller) {
        controller.text = PaymentPlanCatalog.amount(plan);
      });
      _accountController.text = PaymentPlanCatalog.accountNumber;
      _cardController.text = PaymentPlanCatalog.cardNumber;
    } catch (e) {
      _loadError = 'تعذر جلب الأسعار: $e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    String message;
    try {
      await widget.savePrices({
        for (final entry in _controllers.entries)
          entry.key: PaymentPlanCatalog.normalizePrice(entry.value.text)!,
      });
      await widget.savePaymentAccount({
        'accountNumber': _accountController.text.trim(),
        'cardNumber': _cardController.text.trim(),
      });
      message = 'تم حفظ الأسعار وبيانات الدفع';
    } catch (e) {
      message = 'تعذر حفظ الأسعار: $e';
    }
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('الأسعار وبيانات الدفع'),
          centerTitle: true,
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_loadError!, textAlign: TextAlign.center),
                    TextButton(
                      onPressed: _load,
                      child: const Text('إعادة المحاولة'),
                    ),
                  ],
                ),
              )
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Form(
                    key: _formKey,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        const Text(
                          'يظهر السعر للوكلاء عند التسجيل والتجديد، ويطبق على الطلبات الجديدة فقط.',
                        ),
                        const SizedBox(height: 16),
                        for (final entry in _controllers.entries) ...[
                          TextFormField(
                            controller: entry.value,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: PaymentPlanCatalog.label(entry.key),
                              suffixText: 'دينار',
                              border: const OutlineInputBorder(),
                            ),
                            validator: (value) =>
                                PaymentPlanCatalog.normalizePrice(
                                      value ?? '',
                                    ) ==
                                    null
                                ? 'أدخل مبلغاً صحيحاً'
                                : null,
                          ),
                          const SizedBox(height: 12),
                        ],
                        const Divider(height: 28),
                        const Text('يظهر للوكيل في شاشة الدفع ليحوّل عليه.'),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _accountController,
                          maxLength: 64,
                          decoration: const InputDecoration(
                            labelText: 'رقم الحساب',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _cardController,
                          maxLength: 64,
                          decoration: const InputDecoration(
                            labelText: 'رقم البطاقة',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: const Icon(Icons.save_outlined),
                          label: Text(_saving ? 'جاري الحفظ...' : 'حفظ'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
