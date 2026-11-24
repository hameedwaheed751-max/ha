import 'dart:async';

import 'package:flutter/material.dart';

import 'earthlink_mobile_service.dart';
import 'earthlink_reseller_service.dart' show EarthlinkException;

/// حوار تفعيل مشترك إيرثلنك **بخصم من رصيد الوكيل** عبر تطبيق الجوال
/// (`rapi.earthlink.iq`، بلا VPN). يقابل وضع «الرصيد» في الزر القديم؛
/// لا دعم للبطاقة هنا عمداً. يجمع كلمة التفعيل (DepositPassword) التي يكتبها
/// الوكيل يدوياً، ثم يستدعي `refillDeposit`، ويعيد النتيجة عبر Navigator.pop.
class EarthlinkMobileRefillDialog extends StatefulWidget {
  const EarthlinkMobileRefillDialog({
    super.key,
    required this.subscriberName,
    required this.planName,
    required this.remainingText,
    required this.userId,
    required this.customerId,
    required this.mobileNumber,
    required this.serviceFactory,
  });

  final String subscriberName;
  final String planName;
  final String remainingText;

  /// معرّف المشترك النصّي (UserId) والرقمي (customerId، غالباً userIndex).
  final String userId;
  final String customerId;
  final String mobileNumber;

  /// يبني خدمة جوال إيرثلنك بعد تسجيل دخول ناجح.
  final Future<EarthlinkMobileService> Function() serviceFactory;

  @override
  State<EarthlinkMobileRefillDialog> createState() =>
      _EarthlinkMobileRefillDialogState();
}

class _EarthlinkMobileRefillDialogState
    extends State<EarthlinkMobileRefillDialog> {
  final _passwordController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _passwordController.text.trim();
    if (password.isEmpty) {
      setState(() => _error = 'اكتب كلمة التفعيل أولاً');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    EarthlinkMobileService? service;
    try {
      service = await widget.serviceFactory();
      final result = await service
          .refillDeposit(
            userId: widget.userId,
            customerId: widget.customerId,
            mobileNumber: widget.mobileNumber,
            depositPassword: password,
          )
          .timeout(const Duration(seconds: 60));
      if (!mounted) return;
      if (result.success) {
        Navigator.pop(context, result);
      } else {
        // نعرض رسالة الخادم الحرفية — تكشف إشارة النجاح الصحيحة عند أول تفعيل.
        setState(() {
          _busy = false;
          _error = result.message.isNotEmpty
              ? result.message
              : 'لم يؤكّد الخادم نجاح التفعيل';
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
        _error = 'تعذّر التفعيل: $e';
      });
    } finally {
      service?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('تفعيل إيرثلنك بالرصيد'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _infoRow('المشترك', widget.subscriberName),
            _infoRow('الباقة', widget.planName),
            _infoRow('المتبقّي', widget.remainingText),
            const SizedBox(height: 14),
            TextField(
              controller: _passwordController,
              obscureText: true,
              enabled: !_busy,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                labelText: 'كلمة التفعيل',
                hintText: 'كلمة التفعيل التي يزوّدك بها إيرثلنك',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.vpn_key),
              ),
              onSubmitted: _busy ? null : (_) => _submit(),
            ),
            const SizedBox(height: 6),
            Text(
              'يُخصم المبلغ من رصيد الوكيل لدى إيرثلنك.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
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
            onPressed: _busy ? null : _submit,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.bolt),
            label: Text(_busy ? 'جارٍ التفعيل…' : 'تفعيل'),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value.isNotEmpty ? value : '—')),
        ],
      ),
    );
  }
}
