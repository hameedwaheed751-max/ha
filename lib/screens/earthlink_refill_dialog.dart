import 'package:flutter/material.dart';

import '../earthlink_reseller_service.dart';

/// حوار تعبئة/تجديد مشترك إيرثلنك: بطاقة مسبقة الدفع أو خصم من رصيد الوكيل،
/// مع اختيار الباقة (تغييرها = التعبئة بباقة أخرى) وكلمة مرور التفعيل اليدوية.
///
/// التعبئة تصرف أموالاً، فالتأكيد صريح ولا تُعاد المحاولة تلقائياً.
class EarthlinkRefillDialog extends StatefulWidget {
  const EarthlinkRefillDialog({
    super.key,
    required this.uid,
    required this.subscriberName,
    required this.currentPlan,
    required this.serviceFactory,
  });

  final String uid;
  final String subscriberName;
  final String currentPlan;

  /// تُنشئ خدمة مسجّلة الدخول (تُحقن في الاختبارات).
  final Future<EarthlinkResellerService> Function() serviceFactory;

  @override
  State<EarthlinkRefillDialog> createState() => _EarthlinkRefillDialogState();
}

enum _Mode { card, balance }

class _EarthlinkRefillDialogState extends State<EarthlinkRefillDialog> {
  _Mode _mode = _Mode.card;
  final _cardId = TextEditingController();
  final _cardPass = TextEditingController();
  final _onlinePass = TextEditingController();

  Future<List<EarthlinkPlan>>? _plans;
  EarthlinkResellerService? _service;
  String? _planId;
  bool _busy = false;
  String? _error;
  EarthlinkActionResult? _result;

  @override
  void initState() {
    super.initState();
    _plans = _loadPlans();
  }

  Future<List<EarthlinkPlan>> _loadPlans() async {
    final service = _service ??= await widget.serviceFactory();
    final plans = await service.fetchPlans(widget.uid);
    // اختر الباقة الحالية مبدئياً إن طابقت الاسم.
    final match = plans
        .where((p) => p.name == widget.currentPlan)
        .map((p) => p.id);
    _planId = match.isNotEmpty ? match.first : plans.first.id;
    return plans;
  }

  @override
  void dispose() {
    _cardId.dispose();
    _cardPass.dispose();
    _onlinePass.dispose();
    _service?.dispose();
    super.dispose();
  }

  bool get _canSubmit {
    if (_busy || _planId == null) return false;
    if (_mode == _Mode.card) {
      return _cardId.text.trim().isNotEmpty && _cardPass.text.trim().isNotEmpty;
    }
    return _onlinePass.text.trim().isNotEmpty;
  }

  Future<void> _submit() async {
    final service = _service;
    if (service == null || _planId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = _mode == _Mode.card
          ? await service.refillByCard(
              uid: widget.uid,
              cardId: _cardId.text.trim(),
              cardPassword: _cardPass.text.trim(),
              planId: _planId!,
            )
          : await service.refillByBalance(
              uid: widget.uid,
              planId: _planId!,
              onlinePassword: _onlinePass.text.trim(),
            );
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text('تعبئة إيرثلنك — ${widget.subscriberName}'),
        content: SizedBox(
          width: 360,
          child: _result != null ? _resultView() : _formView(),
        ),
        actions: _result != null
            ? [
                TextButton(
                  onPressed: () => Navigator.pop(context, _result!.success),
                  child: const Text('تم'),
                ),
              ]
            : [
                TextButton(
                  onPressed: _busy ? null : () => Navigator.pop(context, false),
                  child: const Text('إلغاء'),
                ),
                FilledButton(
                  onPressed: _canSubmit ? _submit : null,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('تعبئة'),
                ),
              ],
      ),
    );
  }

  Widget _resultView() {
    final ok = _result!.success;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          ok ? Icons.check_circle : Icons.error,
          color: ok ? Colors.green : Colors.red,
          size: 48,
        ),
        const SizedBox(height: 12),
        Text(_result!.message, textAlign: TextAlign.center),
        if (ok && _result!.newExpiration != null) ...[
          const SizedBox(height: 8),
          Text('الانتهاء الجديد: ${_result!.newExpiration}'),
        ],
      ],
    );
  }

  Widget _formView() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<_Mode>(
            segments: const [
              ButtonSegment(
                value: _Mode.card,
                label: Text('بطاقة'),
                icon: Icon(Icons.credit_card),
              ),
              ButtonSegment(
                value: _Mode.balance,
                label: Text('رصيد'),
                icon: Icon(Icons.account_balance_wallet),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: _busy
                ? null
                : (s) => setState(() => _mode = s.first),
          ),
          const SizedBox(height: 14),
          FutureBuilder<List<EarthlinkPlan>>(
            future: _plans,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(),
                );
              }
              if (snap.hasError) {
                return Text(
                  'تعذّر جلب الباقات: ${snap.error}',
                  style: const TextStyle(color: Colors.red),
                );
              }
              final plans = snap.data ?? const <EarthlinkPlan>[];
              return DropdownButtonFormField<String>(
                initialValue: _planId,
                decoration: const InputDecoration(
                  labelText: 'الباقة',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final p in plans)
                    DropdownMenuItem(value: p.id, child: Text(p.name)),
                ],
                onChanged: _busy ? null : (v) => setState(() => _planId = v),
              );
            },
          ),
          const SizedBox(height: 12),
          if (_mode == _Mode.card) ...[
            TextField(
              controller: _cardId,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'رقم البطاقة',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _cardPass,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'رمز البطاقة',
                border: OutlineInputBorder(),
              ),
            ),
          ] else
            TextField(
              controller: _onlinePass,
              onChanged: (_) => setState(() {}),
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'كلمة مرور التفعيل',
                helperText: 'يدخلها الوكيل يدوياً',
                border: OutlineInputBorder(),
              ),
            ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
        ],
      ),
    );
  }
}
