import 'package:flutter/material.dart';
import '../models.dart';
import '../services/finance_ledger.dart';
import '../services/voucher_store.dart';

typedef ActivationPayment = ({
  double saleAmount,
  double collected,
  ActivationSettlement settlement,
  bool alreadyRecorded,
  String? cardPin,
});

class ActivationPaymentDialog extends StatefulWidget {
  const ActivationPaymentDialog({
    super.key,
    required this.subscriber,
    required this.suggestedPrice,
    this.recordedAmount = 0,
    this.cardActivationAvailable = false,
    this.loadUnusedCards,
  });

  final Subscriber subscriber;
  final double suggestedPrice;

  /// مبلغ الاشتراك المسجل وواصله كاملاً قبل التفعيل.
  final double recordedAmount;

  /// عند توفّره يظهر اختيار طريقة التفعيل (رصيد / بطاقة) — otto-isp فقط.
  final bool cardActivationAvailable;

  /// يجلب الكروت غير المستخدمة لاختيار واحدٍ منها بدل الإدخال اليدوي.
  /// غيابه يُبقي حقل الـ PIN قابلاً للكتابة.
  final Future<List<CardPin>> Function()? loadUnusedCards;

  @override
  State<ActivationPaymentDialog> createState() =>
      _ActivationPaymentDialogState();
}

class _ActivationPaymentDialogState extends State<ActivationPaymentDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _priceController;
  final _partialController = TextEditingController();
  final _cardController = TextEditingController();
  ActivationSettlement _settlement = ActivationSettlement.paidOnActivation;
  late bool _useRecorded;

  /// طريقة التفعيل المختارة: false=رصيد، true=بطاقة.
  bool _useCard = false;

  /// الكارت المختار من قائمة غير المستخدمة (لعرض قيمته/سلسلته).
  CardPin? _pickedCard;

  /// يُفعَّل عند فشل جلب الكروت ليُسمح بإدخال الـ PIN يدوياً.
  bool _manualPin = false;

  bool get _hasCardPicker =>
      widget.loadUnusedCards != null && !_manualPin;

  @override
  void initState() {
    super.initState();
    _useRecorded = widget.recordedAmount > 0.0001;
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
    _cardController.dispose();
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
      saleAmount: _useRecorded ? widget.recordedAmount : _price,
      collected: _useRecorded ? widget.recordedAmount : _collected,
      settlement: _useRecorded
          ? ActivationSettlement.paidOnActivation
          : _settlement,
      alreadyRecorded: _useRecorded,
      cardPin: _useCard ? _cardController.text.trim() : null,
    );
    Navigator.pop(context, payment);
  }

  /// يفتح قائمة الكروت غير المستخدمة لاختيار واحدٍ منها.
  Future<void> _pickCard() async {
    final loader = widget.loadUnusedCards;
    if (loader == null) return;
    FocusScope.of(context).unfocus();
    final result = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _UnusedCardsSheet(load: loader),
    );
    if (!mounted || result == null) return;
    if (result is CardPin) {
      setState(() {
        _pickedCard = result;
        _cardController.text = result.pin;
      });
    } else if (result == _manualEntrySignal) {
      setState(() {
        _manualPin = true;
        _pickedCard = null;
        _cardController.clear();
      });
    }
  }

  Widget _summaryRow(String label, double amount, Color? color) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(label),
      Text(
        moneyText(amount),
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
                  'دين سابق: ${moneyText(subscriber.carriedDebt)}',
                  style: TextStyle(color: Colors.orange.shade800),
                ),
              if (_useRecorded) ...[
                const SizedBox(height: 12),
                _summaryRow(
                  'واصل عند التفعيل',
                  widget.recordedAmount,
                  Colors.green.shade700,
                ),
                const SizedBox(height: 6),
                const Text('المبلغ مسجل مسبقاً، ولن يُضاف مرة ثانية.'),
                TextButton(
                  onPressed: () => setState(() => _useRecorded = false),
                  child: const Text('هذا اشتراك جديد بمبلغ آخر'),
                ),
              ] else ...[
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
                  validator: (_) => _price <= 0 ? 'أدخل مبلغ الاشتراك' : null,
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
                _summaryRow(
                  'يُسجل في الواصل',
                  _collected,
                  Colors.green.shade700,
                ),
                _summaryRow('يُسجل في الديون', newDebt, Colors.red.shade700),
              ],
              if (widget.cardActivationAvailable) ...[
                const SizedBox(height: 16),
                const Divider(),
                const Text(
                  'طريقة التفعيل',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('رصيد'),
                      selected: !_useCard,
                      onSelected: (_) => setState(() => _useCard = false),
                    ),
                    ChoiceChip(
                      key: const Key('activation-card-chip'),
                      label: const Text('بطاقة'),
                      selected: _useCard,
                      onSelected: (_) => setState(() => _useCard = true),
                    ),
                  ],
                ),
                if (_useCard) ...[
                  const SizedBox(height: 10),
                  TextFormField(
                    key: const Key('activation-card-pin'),
                    controller: _cardController,
                    readOnly: _hasCardPicker,
                    autofocus: !_hasCardPicker,
                    keyboardType: TextInputType.number,
                    onTap: _hasCardPicker ? _pickCard : null,
                    decoration: InputDecoration(
                      labelText: 'رقم البطاقة (PIN)',
                      border: const OutlineInputBorder(),
                      helperText: _hasCardPicker
                          ? 'اضغط لاختيار كارت غير مستخدم'
                          : 'أدخل الرقم المطبوع على بطاقة الشحن',
                      suffixIcon: _hasCardPicker
                          ? const Icon(Icons.arrow_drop_down)
                          : null,
                    ),
                    validator: (_) {
                      if (!_useCard) return null;
                      final v = _cardController.text.trim();
                      if (v.isEmpty) {
                        return _hasCardPicker
                            ? 'اختر كارتاً من القائمة'
                            : 'أدخل رقم البطاقة';
                      }
                      if (!RegExp(r'^[0-9]{4,}$').hasMatch(v)) {
                        return 'رقم البطاقة أرقام فقط';
                      }
                      return null;
                    },
                  ),
                  if (_hasCardPicker && _pickedCard != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'القيمة: ${moneyText(_pickedCard!.value.toDouble())}'
                      ' · السلسلة: ${_pickedCard!.series}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ],
                ],
              ],
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

/// إشارة يُعيدها قائمة الكروت لطلب الإدخال اليدوي بدلاً من الاختيار.
const String _manualEntrySignal = 'manual';

/// ورقة سفلية تعرض الكروت غير المستخدمة لاختيار واحد. عند تعذّر الجلب أو
/// عدم وجود كروت، تتيح زرّ الإدخال اليدوي (تعيد [_manualEntrySignal]).
class _UnusedCardsSheet extends StatefulWidget {
  const _UnusedCardsSheet({required this.load});

  final Future<List<CardPin>> Function() load;

  @override
  State<_UnusedCardsSheet> createState() => _UnusedCardsSheetState();
}

class _UnusedCardsSheetState extends State<_UnusedCardsSheet> {
  late Future<List<CardPin>> _future = widget.load();

  void _retry() => setState(() => _future = widget.load());

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    Icon(Icons.credit_card, color: Colors.indigo),
                    SizedBox(width: 8),
                    Text(
                      'اختر كارتاً غير مستخدم',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: FutureBuilder<List<CardPin>>(
                  future: _future,
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    if (snap.hasError) {
                      return _message(
                        icon: Icons.error_outline,
                        color: Colors.red.shade700,
                        text: 'تعذّر جلب الكروت. تحقق من الاتصال.',
                        showRetry: true,
                      );
                    }
                    final cards = snap.data ?? const <CardPin>[];
                    if (cards.isEmpty) {
                      return _message(
                        icon: Icons.inbox_outlined,
                        color: Colors.grey.shade600,
                        text: 'لا توجد كروت غير مستخدمة. اشترِ كروتاً أولاً.',
                      );
                    }
                    return ListView.separated(
                      shrinkWrap: true,
                      itemCount: cards.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final c = cards[i];
                        return ListTile(
                          key: Key('unused-card-${c.pin}'),
                          leading: const Icon(Icons.confirmation_number_outlined),
                          title: Text(
                            c.pin,
                            style: const TextStyle(
                              fontFeatures: [FontFeature.tabularFigures()],
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            'القيمة: ${moneyText(c.value.toDouble())}'
                            '${c.series.isNotEmpty ? ' · السلسلة: ${c.series}' : ''}',
                          ),
                          onTap: () => Navigator.pop(context, c),
                        );
                      },
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(8),
                child: TextButton.icon(
                  onPressed: () =>
                      Navigator.pop(context, _manualEntrySignal),
                  icon: const Icon(Icons.keyboard),
                  label: const Text('إدخال رقم الكارت يدوياً'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _message({
    required IconData icon,
    required Color color,
    required String text,
    bool showRetry = false,
  }) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 40),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
          if (showRetry) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _retry,
              icon: const Icon(Icons.refresh),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ],
      ),
    );
  }
}
