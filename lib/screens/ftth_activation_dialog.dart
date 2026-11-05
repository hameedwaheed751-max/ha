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
    this.renewal = false,
    this.topUp,
  });

  final String subscriberName;

  /// يعبّئ محفظة المشترك برمز كارت ويعيد رصيدها الجديد.
  final Future<double?> Function(FtthActivationQuote quote, String cardPin)?
  topUp;

  /// المشترك فعّال، فالعملية تجديد (تمديد) لا تفعيل.
  final bool renewal;
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
  bool _toppingUp = false;
  String? _topUpMessage;
  bool _topUpFailed = false;

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

  Future<void> _topUp() async {
    final quote = _quote;
    final topUp = widget.topUp;
    if (quote == null || topUp == null || _toppingUp) return;
    final pin = await showDialog<String>(
      context: context,
      builder: (_) => const _CardPinDialog(),
    );
    if (pin == null || !mounted) return;
    setState(() {
      _toppingUp = true;
      _topUpMessage = null;
    });
    try {
      final balance = await topUp(quote, pin);
      if (!mounted) return;
      setState(() {
        final updated = _quote!.withCustomerBalance(balance);
        _quote = updated;
        _method = null;
        _pickMethod(updated);
        _topUpMessage = balance == null
            ? 'تمت التعبئة، لكن تعذرت قراءة الرصيد الجديد'
            : 'تمت التعبئة. الرصيد: ${formatIqd(balance)}';
        _topUpFailed = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _topUpMessage = 'فشلت التعبئة: $error';
        _topUpFailed = true;
      });
    } finally {
      if (mounted) setState(() => _toppingUp = false);
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
        !quote.order.renew
            ? 'العملية: تغيير الخطة'
            : quote.detail.expired
            ? 'العملية: تجديد'
            : 'العملية: تمديد — تُضاف المدة لاشتراك فعّال',
        style: TextStyle(color: colors.onSurfaceVariant),
      ),
      // تغيير خطة مشترك فعّال ليس تمديداً، وقد يبدأ الخطة الجديدة من الآن.
      if (!quote.order.renew && !quote.detail.expired)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'المشترك فعّال: للتمديد أبقِ خطته الحالية. تغيير الخطة قد يبدأ '
            'الخطة الجديدة من الآن بدل إضافتها بعد تاريخ الانتهاء.',
            style: TextStyle(color: colors.error),
          ),
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
        title: Text(widget.renewal ? 'تجديد اشتراك FTTH' : 'تفعيل اشتراك FTTH'),
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
                      if (widget.topUp != null &&
                          quote.detail.customerId.isNotEmpty) ...[
                        OutlinedButton.icon(
                          onPressed: _toppingUp || _pricing ? null : _topUp,
                          icon: _toppingUp
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.credit_card),
                          label: const Text('تعبئة رصيد المشترك بكارت'),
                        ),
                        if (_topUpMessage != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              _topUpMessage!,
                              style: TextStyle(
                                color: _topUpFailed
                                    ? colors.error
                                    : Colors.green.shade700,
                              ),
                            ),
                          ),
                      ],
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

/// يطلب رمز الكارت ويؤكد قبل الإرسال، لأن الكارت يُستهلك عند نجاح التعبئة.
class _CardPinDialog extends StatefulWidget {
  const _CardPinDialog();

  @override
  State<_CardPinDialog> createState() => _CardPinDialogState();
}

class _CardPinDialogState extends State<_CardPinDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _pin =>
      SasProjectNationalService.normalizeCardPin(_controller.text);

  @override
  Widget build(BuildContext context) {
    final ok = _pin.length >= 10;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('تعبئة رصيد المشترك'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                labelText: 'رمز الكارت',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            const Text(
              'يُضاف مبلغ الكارت إلى محفظة المشترك في FTTH ويُستهلك الكارت، '
              'ثم اختر "رصيد المشترك" للتفعيل.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: ok ? () => Navigator.pop(context, _pin) : null,
            child: const Text('تعبئة'),
          ),
        ],
      ),
    );
  }
}
