import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models.dart';
import '../services/payment_request_service.dart';
import '../services/render_whatsapp_service.dart';

class PaymentRequestsAdminScreen extends StatefulWidget {
  const PaymentRequestsAdminScreen({super.key});

  @override
  State<PaymentRequestsAdminScreen> createState() => _PaymentRequestsAdminScreenState();
}

class _PaymentRequestsAdminScreenState extends State<PaymentRequestsAdminScreen> {
  bool _busy = false;

  Future<void> _approve(PaymentRequestRecord request) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final data = await PaymentRequestService.approveRequest(
        request: request,
        approvedBy: FirebaseAuth.instance.currentUser?.email ?? AppStore.agentEmail,
      );

      final phone = request.phone;
      final planLabel = (data['planLabel'] ?? request.planLabel).toString();
      final endDate = (data['endDate'] ?? '').toString();

      AppStore.addDailyTaskEvent(
        DailyTaskEvent(
          type: 'payment_approved',
          subscriberUser: request.email,
          subscriberName: request.agentName,
          at: DateTime.now(),
          note: 'تم قبول طلب الدفع - $planLabel',
        ),
      );

      await RenderWhatsAppService.sendSingleMessage(
        to: phone,
        message: 'مرحباً ${request.agentName}،\n✅ تم قبول طلب الاشتراك بنجاح.\n📦 الباقة: $planLabel\n📅 ينتهي الاشتراك: ${endDate.isNotEmpty ? endDate : '—'}\n\nشكراً لاختياركم خدمتنا.',
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم قبول الطلب بنجاح')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('فشل قبول الطلب: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject(PaymentRequestRecord request) async {
    if (_busy) return;
    final reasonController = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('سبب الرفض'),
          content: TextField(
            controller: reasonController,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'اكتب سبب الرفض هنا',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, reasonController.text.trim()),
              child: const Text('تأكيد'),
            ),
          ],
        ),
      ),
    );

    if (reason == null) return;

    setState(() => _busy = true);
    try {
      await PaymentRequestService.rejectRequest(
        request: request,
        rejectedBy: FirebaseAuth.instance.currentUser?.email ?? AppStore.agentEmail,
        rejectReason: reason,
      );

      final phone = request.phone;

      AppStore.addDailyTaskEvent(
        DailyTaskEvent(
          type: 'payment_rejected',
          subscriberUser: request.email,
          subscriberName: request.agentName,
          at: DateTime.now(),
          note: reason,
        ),
      );

      await RenderWhatsAppService.sendSingleMessage(
        to: phone,
        message: 'مرحباً ${request.agentName}،\n❌ تم رفض طلب الاشتراك.\nالسبب: $reason\n\nللاستفسار يرجى التواصل مع:\n🏢 ${AppStore.effectiveAgentName}\n\nشكراً لكم.',
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم رفض الطلب')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('فشل رفض الطلب: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showReceipt(String url) async {
    if (url.trim().isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('صورة الإيصال'),
          content: SizedBox(
            width: 360,
            child: InteractiveViewer(child: Image.network(url, fit: BoxFit.contain)),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق'))],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('طلبات الدفع'),
          centerTitle: true,
        ),
        body: StreamBuilder<List<PaymentRequestRecord>>(
          stream: PaymentRequestService.watchPendingRequests(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('خطأ: ${snapshot.error}'));
            }

            final requests = snapshot.data ?? const <PaymentRequestRecord>[];
            if (requests.isEmpty) {
              return const Center(child: Text('لا توجد طلبات دفع معلقة'));
            }

            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: requests.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final request = requests[index];
                final created = DateTime.fromMillisecondsSinceEpoch(request.createdAt).toLocal();
                final createdText = '${created.day.toString().padLeft(2, '0')}/${created.month.toString().padLeft(2, '0')}/${created.year} ${created.hour.toString().padLeft(2, '0')}:${created.minute.toString().padLeft(2, '0')}';

                return Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                request.agentName.isNotEmpty ? request.agentName : 'وكيل بدون اسم',
                                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.orange.shade700,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Text('pending', style: TextStyle(color: Colors.white, fontSize: 12)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text('البريد الإلكتروني: ${request.email}'),
                        Text('رقم الهاتف: ${request.phone}'),
                        Text('نوع الاشتراك: ${request.planLabel}'),
                        Text('المبلغ: ${request.amount}'),
                        Text('رقم التحويل: ${request.transferNumber.isEmpty ? '—' : request.transferNumber}'),
                        Text('تاريخ الطلب: $createdText'),
                        if (request.receiptImage.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          InkWell(
                            onTap: () => _showReceipt(request.receiptImage),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: Image.network(
                                request.receiptImage,
                                height: 180,
                                width: double.infinity,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text('اضغط على الصورة لعرضها بحجم أكبر', style: TextStyle(fontSize: 12, color: Colors.grey)),
                        ],
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _busy ? null : () => _approve(request),
                                icon: const Icon(Icons.check_circle_outline),
                                label: const Text('قبول'),
                                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2E7D32), foregroundColor: Colors.white),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _busy ? null : () => _reject(request),
                                icon: const Icon(Icons.cancel_outlined),
                                label: const Text('رفض'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
