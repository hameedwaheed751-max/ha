import 'dart:async';

import 'package:flutter/material.dart';

import 'earthlink_mobile_service.dart';
import 'earthlink_reseller_service.dart' show EarthlinkException;

/// حوار **تغيير باقة** مشترك إيرثلنك عبر تطبيق الجوال (`chnageaccounttype`).
/// يجلب الباقات من `/accounts/all`، يعرضها بقائمة منسدلة (الافتراضي = الباقة
/// الحالية)، وعند التأكيد ينفّذ تغيير الباقة. يعيد الباقة المختارة عبر
/// Navigator.pop عند النجاح، أو null عند الإلغاء. لا يُنفّذ تعبئة/تجديد.
class EarthlinkChangePlanDialog extends StatefulWidget {
  const EarthlinkChangePlanDialog({
    super.key,
    required this.subscriberName,
    required this.currentPlanName,
    required this.currentAccountIndex,
    required this.userId,
    required this.serviceFactory,
  });

  final String subscriberName;
  final String currentPlanName;
  final int currentAccountIndex;
  final String userId;

  /// يبني خدمة جوال إيرثلنك بعد تسجيل دخول ناجح.
  final Future<EarthlinkMobileService> Function() serviceFactory;

  @override
  State<EarthlinkChangePlanDialog> createState() =>
      _EarthlinkChangePlanDialogState();
}

class _EarthlinkChangePlanDialogState extends State<EarthlinkChangePlanDialog> {
  EarthlinkMobileService? _service;
  List<EarthlinkMobilePlan> _plans = const [];
  EarthlinkMobilePlan? _selected;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPlans();
  }

  @override
  void dispose() {
    _service?.dispose();
    super.dispose();
  }

  Future<void> _loadPlans() async {
    try {
      final service = await widget.serviceFactory();
      _service = service;
      final plans = await service.fetchPlans().timeout(
        const Duration(seconds: 60),
      );
      if (!mounted) return;
      EarthlinkMobilePlan? current;
      for (final p in plans) {
        if (p.accountIndex == widget.currentAccountIndex) {
          current = p;
          break;
        }
      }
      setState(() {
        _plans = plans;
        _selected = current ?? (plans.isNotEmpty ? plans.first : null);
        _loading = false;
      });
    } on EarthlinkException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'تعذّر جلب الباقات: $e';
      });
    }
  }

  Future<void> _submit() async {
    final selected = _selected;
    final service = _service;
    if (selected == null || service == null) return;
    if (selected.accountIndex == widget.currentAccountIndex) {
      setState(() => _error = 'هذه هي الباقة الحالية — اختر باقة مختلفة');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await service
          .changeAccount(
            userId: widget.userId,
            accountIndex: selected.accountIndex,
          )
          .timeout(const Duration(seconds: 60));
      if (!mounted) return;
      if (result.success) {
        Navigator.pop(context, selected);
      } else {
        setState(() {
          _busy = false;
          _error = result.message.isNotEmpty
              ? result.message
              : 'لم يؤكّد الخادم تغيير الباقة';
        });
      }
    } on EarthlinkException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'تعذّر تغيير الباقة: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('تغيير باقة إيرثلنك'),
        content: _loading
            ? const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.subscriberName,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'الباقة الحالية: ${widget.currentPlanName}',
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                  ),
                  const SizedBox(height: 14),
                  if (_plans.isEmpty)
                    const Text('لا توجد باقات متاحة')
                  else
                    DropdownButtonFormField<EarthlinkMobilePlan>(
                      initialValue: _selected,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'الباقة الجديدة',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final p in _plans)
                          DropdownMenuItem(value: p, child: Text(p.name)),
                      ],
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _selected = v),
                    ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline, color: Colors.red.shade700),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: TextStyle(color: Colors.red.shade800),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton.icon(
            onPressed: (_busy || _loading || _plans.isEmpty) ? null : _submit,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.swap_horiz),
            label: Text(_busy ? 'جارٍ التغيير…' : 'تغيير'),
          ),
        ],
      ),
    );
  }
}
