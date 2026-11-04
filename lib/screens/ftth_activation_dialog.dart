import 'package:flutter/material.dart';

import '../sas_project_national_service.dart';

class FtthActivationChoice {
  const FtthActivationChoice({required this.quote, required this.method});

  final FtthActivationQuote quote;
  final FtthPaymentMethod method;
}

String formatIqd(double value) {
  final digits = value.round().toString();
  final grouped = digits.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return '$grouped د.ع';
}

/// خطوات موقع FTTH في نافذة واحدة: الخطة ومدة الالتزام، ثم طريقة الدفع.
class FtthActivationDialog extends StatefulWidget {
  const FtthActivationDialog({
    super.key,
    required this.subscriberName,
    required this.loadQuote,
    required this.priceFor,
  });

  final String subscriberName;
  final Future<FtthActivationQuote> Function() loadQuote;
  final Future<double> Function(
    FtthActivationQuote quote,
    FtthRenewalOrder order,
  )
  priceFor;

  @override
  State<FtthActivationDialog> createState() => _FtthActivationDialogState();
}

class _FtthActivationDialogState extends State<FtthActivationDialog> {
  FtthActivationQuote? _quote;
  Object? _error;
  Object? _priceError;
  FtthPaymentMethod? _method;
  FtthPlan? _plan;
  int _months = 1;
  bool _pricing = false;
  int _priceRequest = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _quote = null;
      _error = null;
      _priceError = null;
    });
    try {
      final quote = await widget.loadQuote();
      if (!mounted) return;
      setState(() {
        _quote = quote;
        _plan = quote.defaultPlan;
        _months = quote.order.commitmentPeriodValue;
        _pickMethod(quote);
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  void _pickMethod(FtthActivationQuote quote) {
    if (_method != null && quote.canUse(_method!)) return;
    _method = quote.canUse(FtthPaymentMethod.customerWallet)
        ? FtthPaymentMethod.customerWallet
        : quote.canUse(FtthPaymentMethod.card)
        ? FtthPaymentMethod.card
        : null;
  }

  Future<void> _reprice({FtthPlan? plan, int? months}) async {
    final quote = _quote;
    if (quote == null) return;
    final nextPlan = plan ?? _plan;
    final nextMonths = months ?? _months;
    final order = quote.orderFor(nextPlan, nextMonths);
    final request = ++_priceRequest;
    setState(() {
      _plan = nextPlan;
      _months = nextMonths;
      _pricing = true;
      _priceError = null;
    });
    try {
      final price = await widget.priceFor(quote, order);
      if (!mounted || request != _priceRequest) return;
      setState(() {
        _quote = quote.withOrder(order, price);
        _pickMethod(_quote!);
      });
    } catch (error) {
      if (mounted && request == _priceRequest) {
        setState(() => _priceError = error);
      }
    } finally {
      if (mounted && request == _priceRequest) {
        setState(() => _pricing = false);
      }
    }
  }

  String _subtitle(FtthActivationQuote quote, FtthPaymentMethod method) {
    if (!method.available) return 'سيُفعَّل بعد التأكد من طريقة الموقع';
    if (method == FtthPaymentMethod.card) {
      return 'يفتح صفحة الدفع، ويتم التفعيل بعد إكمال الدفع';
    }
    final balance = quote.balanceFor(method);
    if (balance == null) return 'تعذرت قراءة الرصيد';
    final text = 'الرصيد: ${formatIqd(balance)}';
    return quote.canUse(method) ? text : '$text — غير كافٍ';
  }

  List<Widget> _planFields(FtthActivationQuote quote, ColorScheme colors) {
    final periods = quote.commitmentPeriods.isEmpty
        ? [quote.order.commitmentPeriodValue]
        : quote.commitmentPeriods;
    return [
      if (!quote.currentPlanSold)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'خطة المشترك الحالية (${quote.detail.basePlanId}) لم تعد تُباع، '
            'فيُنقل إلى الخطة التي تختارها.',
            style: TextStyle(color: colors.tertiary),
          ),
        ),
      if (quote.plans.isNotEmpty) ...[
        DropdownButtonFormField<FtthPlan>(
          initialValue: _plan,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'الخطة',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final plan in quote.plans)
              DropdownMenuItem(value: plan, child: Text(plan.label)),
          ],
          onChanged: _pricing
              ? null
              : (plan) {
                  if (plan != null && plan != _plan) _reprice(plan: plan);
                },
        ),
        const SizedBox(height: 12),
      ],
      DropdownButtonFormField<int>(
        initialValue: periods.contains(_months) ? _months : null,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'مدة الالتزام',
          border: OutlineInputBorder(),
        ),
        items: [
          for (final m in periods)
            DropdownMenuItem(
              value: m,
              child: Text(m == 1 ? 'شهر واحد' : '$m أشهر'),
            ),
        ],
        onChanged: _pricing
            ? null
            : (m) {
                if (m != null && m != _months) _reprice(months: m);
              },
      ),
      const SizedBox(height: 8),
      Text(
        quote.order.renew ? 'العملية: تجديد' : 'العملية: تغيير الخطة',
        style: TextStyle(color: colors.onSurfaceVariant),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final quote = _quote;
    final colors = Theme.of(context).colorScheme;
    final ready = quote != null && !_pricing && _priceError == null;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('تفعيل اشتراك FTTH'),
        content: SizedBox(
          width: 420,
          child: _error != null
              ? Text(
                  'تعذرت قراءة بيانات التفعيل من FTTH:\n$_error',
                  style: TextStyle(color: colors.error),
                )
              : quote == null
              ? const SizedBox(
                  height: 120,
                  child: Center(child: CircularProgressIndicator()),
                )
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(widget.subscriberName),
                      const SizedBox(height: 12),
                      ..._planFields(quote, colors),
                      const SizedBox(height: 8),
                      if (_priceError != null)
                        Text(
                          'تعذر حساب السعر من FTTH:\n$_priceError',
                          style: TextStyle(color: colors.error),
                        )
                      else
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'سعر FTTH: ${formatIqd(quote.price)}',
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            if (_pricing)
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                          ],
                        ),
                      const SizedBox(height: 12),
                      for (final method in FtthPaymentMethod.values)
                        Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          color: _method == method
                              ? colors.primaryContainer
                              : null,
                          child: ListTile(
                            enabled: ready && quote.canUse(method),
                            leading: Icon(
                              _method == method
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                            ),
                            title: Text(method.label),
                            subtitle: Text(_subtitle(quote, method)),
                            onTap: () => setState(() => _method = method),
                          ),
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
          if (_error != null)
            TextButton(onPressed: _load, child: const Text('إعادة المحاولة')),
          if (_priceError != null)
            TextButton(
              onPressed: () => _reprice(),
              child: const Text('إعادة الحساب'),
            ),
          FilledButton(
            onPressed: !ready || _method == null || !quote.canUse(_method!)
                ? null
                : () => Navigator.pop(
                    context,
                    FtthActivationChoice(quote: quote, method: _method!),
                  ),
            child: const Text('متابعة'),
          ),
        ],
      ),
    );
  }
}
