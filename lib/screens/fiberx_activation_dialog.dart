import 'package:flutter/material.dart';

import '../fiberx_service.dart';

/// حوار تفعيل/تجديد/تغيير باقة لمشترك فايبر اكس. الدفع من محفظة الوكيل فقط
/// (لا بطاقات). اختيار باقة مختلفة = تغيير الباقة. العملية تصرف أموالاً،
/// فالتأكيد صريح مع إظهار المبلغ والانتهاء الجديد المتوقَّع.
class FiberXActivationDialog extends StatefulWidget {
  const FiberXActivationDialog({
    super.key,
    required this.subscriber,
    required this.serviceFactory,
  });

  final FiberXSubscriber subscriber;

  /// تُنشئ خدمة مسجّلة الدخول (تُحقن في الاختبارات).
  final Future<FiberXService> Function() serviceFactory;

  @override
  State<FiberXActivationDialog> createState() => _FiberXActivationDialogState();
}

class _FiberXActivationDialogState extends State<FiberXActivationDialog> {
  Future<List<FiberXPlan>>? _plans;
  FiberXService? _service;
  FiberXPlan? _plan;
  int _durationDays = 30;
  bool _busy = false;
  String? _error;
  FiberXActionResult? _result;

  @override
  void initState() {
    super.initState();
    _plans = _loadPlans();
  }

  Future<List<FiberXPlan>> _loadPlans() async {
    final service = _service ??= await widget.serviceFactory();
    final plans = await service.fetchPlans();
    // اختر الباقة الحالية مبدئياً بالمطابقة على المعرّف ثم الاسم.
    final byId = plans.where(
      (p) => p.billingProfileId == widget.subscriber.billingProfileId,
    );
    final byName = plans.where((p) => p.name == widget.subscriber.planName);
    _plan = byId.isNotEmpty
        ? byId.first
        : (byName.isNotEmpty ? byName.first : (plans.isNotEmpty ? plans.first : null));
    return plans;
  }

  @override
  void dispose() {
    _service?.dispose();
    super.dispose();
  }

  DateTime get _nextExpiry {
    final now = DateTime.now();
    final exp = widget.subscriber.expiration;
    final base = (exp != null && exp.isAfter(now)) ? exp : now;
    return base.add(Duration(days: _durationDays));
  }

  String _fmt(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

  Future<void> _submit() async {
    final service = _service;
    final plan = _plan;
    if (service == null || plan == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await service.activate(
        subscriber: widget.subscriber,
        plan: plan,
        durationDays: _durationDays,
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
    final s = widget.subscriber;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text('فايبر اكس — ${s.name.isNotEmpty ? s.name : s.username}'),
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
                  onPressed: (_busy || _plan == null) ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('تنفيذ'),
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
          Text('الانتهاء الجديد: ${_fmt(_result!.newExpiration!)}'),
        ],
        if (ok && _result!.totalCharged != null) ...[
          const SizedBox(height: 4),
          Text('المبلغ المخصوم: ${_result!.totalCharged}'),
        ],
      ],
    );
  }

  Widget _formView() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FutureBuilder<List<FiberXPlan>>(
            future: _plans,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snap.hasError) {
                return Text(
                  'تعذّر جلب الباقات: ${snap.error}',
                  style: const TextStyle(color: Colors.red),
                );
              }
              final plans = snap.data ?? const <FiberXPlan>[];
              return DropdownButtonFormField<String>(
                initialValue: _plan?.billingProfileId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'الباقة (اختر أخرى لتغيير الباقة)',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final p in plans)
                    DropdownMenuItem(
                      value: p.billingProfileId,
                      child: Text(
                        '${p.name} — ${p.price.toStringAsFixed(0)}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                        final match = plans.where(
                          (p) => p.billingProfileId == v,
                        );
                        _plan = match.isNotEmpty ? match.first : _plan;
                      }),
              );
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            initialValue: '$_durationDays',
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'المدة (أيام)',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) {
              final d = int.tryParse(v.trim());
              if (d != null && d > 0) setState(() => _durationDays = d);
            },
          ),
          const SizedBox(height: 14),
          _summaryRow('المبلغ', _plan == null ? '—' : _plan!.price.toStringAsFixed(0)),
          _summaryRow('الدفع', 'محفظة الوكيل'),
          _summaryRow('الانتهاء الجديد', _fmt(_nextExpiry)),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
        ],
      ),
    );
  }

  Widget _summaryRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey)),
        Flexible(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}
