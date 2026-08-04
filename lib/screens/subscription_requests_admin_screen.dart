import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../services/subscription_request_service.dart';

class SubscriptionRequestsAdminScreen extends StatefulWidget {
  const SubscriptionRequestsAdminScreen({super.key});

  @override
  State<SubscriptionRequestsAdminScreen> createState() => _SubscriptionRequestsAdminScreenState();
}

class _SubscriptionRequestsAdminScreenState extends State<SubscriptionRequestsAdminScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<void> _approve(String requestId, Map<String, dynamic> data) async {
    try {
      await SubscriptionRequestService.approveRequestById(requestId: requestId, requestData: data);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم قبول الطلب بنجاح')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('فشل قبول الطلب: $e')));
    }
  }

  Future<void> _reject(String requestId) async {
    try {
      await _firestore.collection(SubscriptionRequestService.collectionName).doc(requestId).update({
        'status': 'rejected',
        'reviewedAt': FieldValue.serverTimestamp(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم رفض الطلب')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('فشل رفض الطلب: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('طلبات الاشتراك'),
          centerTitle: true,
        ),
        body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _firestore.collection(SubscriptionRequestService.collectionName).orderBy('createdAt', descending: true).snapshots(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('خطأ: ${snapshot.error}'));
            }

            final docs = snapshot.data?.docs ?? [];
            if (docs.isEmpty) {
              return const Center(child: Text('لا توجد طلبات اشتراك حالياً'));
            }

            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: docs.length,
              itemBuilder: (context, index) {
                final doc = docs[index];
                final data = doc.data();
                final status = data['status']?.toString() ?? 'pending';
                final planLabel = SubscriptionRequestService.planLabelFor(data['selectedPlan']?.toString() ?? 'trial');
                final createdAt = data['createdAt'];
                final createdText = createdAt is Timestamp ? createdAt.toDate().toLocal().toString().split('.').first : '—';

                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${data['firstName']} ${data['lastName']}',
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: _statusColor(status),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(status, style: const TextStyle(color: Colors.white, fontSize: 12)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text('الباقة: $planLabel'),
                        Text('السعر: ${data['amount'] ?? '—'}'),
                        Text('الهاتف: ${data['phone'] ?? '—'}'),
                        Text('البريد: ${data['email'] ?? '—'}'),
                        Text('رقم التحويل: ${data['transferNumber'] ?? '—'}'),
                        Text('تاريخ الإرسال: $createdText'),
                        const SizedBox(height: 10),
                        if (data['receiptImageUrl'] != null && (data['receiptImageUrl'] as String).isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Text('صورة الإيصال: ${data['receiptImageUrl']}'),
                          ),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: status == 'approved' || status == 'rejected' ? null : () => _approve(doc.id, data),
                                icon: const Icon(Icons.check_circle_outline),
                                label: const Text('قبول'),
                                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2E7D32)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: status == 'approved' || status == 'rejected' ? null : () => _reject(doc.id),
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

  Color _statusColor(String status) {
    switch (status) {
      case 'approved':
        return const Color(0xFF2E7D32);
      case 'rejected':
        return const Color(0xFFC62828);
      default:
        return const Color(0xFF1565C0);
    }
  }
}
