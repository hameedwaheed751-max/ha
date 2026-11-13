import 'package:flutter/material.dart';

import '../models.dart';
import '../sas_api_service.dart';
import '../services/voucher_store.dart';

/// شاشة الكروت (otto-isp): رصيد المكتب، شراء كروت جديدة، وسجل الشراء.
/// الشراء يخصم من الرصيد ويولّد كروتاً بأرقام PIN جديدة في SAS.
class CardsScreen extends StatefulWidget {
  const CardsScreen({super.key, required this.api, this.companyLabel = ''});

  final VoucherApi api;
  final String companyLabel;

  @override
  State<CardsScreen> createState() => _CardsScreenState();
}

class _CardsScreenState extends State<CardsScreen> {
  final _valueController = TextEditingController(text: '20000');
  final _qtyController = TextEditingController(text: '1');

  double? _balance;
  List<VoucherPurchase> _purchases = const [];
  bool _loading = true;
  bool _buying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _valueController.dispose();
    _qtyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.api.fetchVoucherBalance(),
        widget.api.fetchVoucherPurchases(),
      ]);
      if (!mounted) return;
      setState(() {
        _balance = results[0] as double?;
        _purchases = results[1] as List<VoucherPurchase>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is SasApiException ? e.message : 'تعذّر جلب بيانات الكروت';
        _loading = false;
      });
    }
  }

  int get _cardValue => int.tryParse(_valueController.text.trim()) ?? 0;
  int get _quantity => int.tryParse(_qtyController.text.trim()) ?? 0;

  /// قيم الكروت المقترحة: الموجودة في السجل + الافتراضية.
  List<int> get _suggestedValues {
    final set = <int>{20000, 23000, ..._purchases.map((p) => p.cardValue)};
    final list = set.where((v) => v > 0).toList()..sort();
    return list;
  }

  Future<void> _buy() async {
    final value = _cardValue;
    final qty = _quantity;
    if (value <= 0) {
      _snack('أدخل قيمة الكارت');
      return;
    }
    if (qty <= 0) {
      _snack('أدخل عدداً صحيحاً للكروت');
      return;
    }
    final total = value * qty;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تأكيد شراء الكروت'),
          content: Text(
            'سيُخصم ${moneyText(total.toDouble())} من رصيدك مقابل '
            '$qty كارت بقيمة ${moneyText(value.toDouble())} لكلٍّ منها.\n\n'
            'تتولّد كروت جديدة بأرقام PIN. هل تريد المتابعة؟',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('شراء'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _buying = true);
    try {
      final message = await widget.api.buyVouchers(
        cardValue: value,
        quantity: qty,
      );
      if (!mounted) return;
      _snack(message);
      await _load();
    } catch (e) {
      if (!mounted) return;
      _snack(e is SasApiException ? e.message : 'تعذّر شراء الكروت');
    } finally {
      if (mounted) setState(() => _buying = false);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.companyLabel.trim().isEmpty
        ? 'الكروت'
        : 'الكروت — ${widget.companyLabel.trim()}';
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          actions: [
            IconButton(
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'تحديث',
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_error != null) _errorBanner(_error!),
                    _balanceCard(),
                    const SizedBox(height: 16),
                    _buyCard(),
                    const SizedBox(height: 20),
                    const Text(
                      'سجل الشراء',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    if (_purchases.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: Text('لا توجد عمليات شراء بعد')),
                      )
                    else
                      ..._purchases.map(_purchaseTile),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _errorBanner(String message) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.red.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Colors.red.shade200),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline, color: Colors.red),
        const SizedBox(width: 8),
        Expanded(child: Text(message)),
      ],
    ),
  );

  Widget _balanceCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          const Icon(Icons.account_balance_wallet_rounded, size: 32),
          const SizedBox(width: 12),
          const Text('رصيد المكتب', style: TextStyle(fontSize: 16)),
          const Spacer(),
          Text(
            _balance == null ? '—' : moneyText(_balance!),
            key: const Key('cards-balance'),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    ),
  );

  Widget _buyCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'شراء كروت',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final v in _suggestedValues)
                ChoiceChip(
                  label: Text(moneyText(v.toDouble())),
                  selected: _cardValue == v,
                  onSelected: (_) =>
                      setState(() => _valueController.text = '$v'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('cards-value'),
            controller: _valueController,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'قيمة الكارت',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('cards-qty'),
            controller: _qtyController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'عدد الكروت',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const Key('cards-buy'),
            onPressed: _buying ? null : _buy,
            icon: _buying
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_card_rounded),
            label: Text(_buying ? 'جارٍ الشراء…' : 'شراء'),
          ),
        ],
      ),
    ),
  );

  Widget _purchaseTile(VoucherPurchase p) {
    final complete = p.isComplete;
    return Card(
      child: ListTile(
        leading: Icon(
          Icons.credit_card_rounded,
          color: complete ? Colors.green.shade700 : Colors.orange.shade700,
        ),
        title: Text('${p.qty} × ${moneyText(p.cardValue.toDouble())}'),
        subtitle: Text(p.createdAt),
        trailing: Text(
          p.statusLabel,
          style: TextStyle(
            color: complete ? Colors.green.shade700 : Colors.orange.shade700,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
