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

/// يقرأ سعر FTTH والرصيدين ثم يترك الوكيل يختار طريقة الدفع.
class FtthActivationDialog extends StatefulWidget {
  const FtthActivationDialog({
    super.key,
    required this.subscriberName,
    required this.loadQuote,
  });

  final String subscriberName;
  final Future<FtthActivationQuote> Function() loadQuote;

  @override
  State<FtthActivationDialog> createState() => _FtthActivationDialogState();
}

class _FtthActivationDialogState extends State<FtthActivationDialog> {
  FtthActivationQuote? _quote;
  Object? _error;
  FtthPaymentMethod? _method;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _quote = null;
      _error = null;
    });
    try {
      final quote = await widget.loadQuote();
      if (!mounted) return;
      setState(() {
        _quote = quote;
        _method = quote.canUse(FtthPaymentMethod.customerWallet)
            ? FtthPaymentMethod.customerWallet
            : quote.canUse(FtthPaymentMethod.card)
            ? FtthPaymentMethod.card
            : null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
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

  @override
  Widget build(BuildContext context) {
    final quote = _quote;
    final colors = Theme.of(context).colorScheme;
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
                      const SizedBox(height: 4),
                      Text(
                        'سعر FTTH: ${formatIqd(quote.price)}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      for (final method in FtthPaymentMethod.values)
                        Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          color: _method == method
                              ? colors.primaryContainer
                              : null,
                          child: ListTile(
                            enabled: quote.canUse(method),
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
          FilledButton(
            onPressed: quote == null || _method == null
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
