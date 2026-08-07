import 'package:flutter/material.dart';
import '../services/subscription_request_service.dart';

class SubscriptionRequestsAdminScreen extends StatefulWidget {
  const SubscriptionRequestsAdminScreen({super.key});

  @override
  State<SubscriptionRequestsAdminScreen> createState() => _SubscriptionRequestsAdminScreenState();
}

class _SubscriptionRequestsAdminScreenState extends State<SubscriptionRequestsAdminScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

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
      await SubscriptionRequestService.rejectRequest(requestId: requestId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم رفض الطلب')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('فشل رفض الطلب: $e')));
    }
  }

  Future<void> _deleteRequest(SubscriptionRequestModel request) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف البطاقة'),
          content: Text('هل تريد حذف بطاقة الطلب الخاصة بـ ${request.firstName} ${request.lastName}؟'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC62828)),
              child: const Text('حذف'),
            ),
          ],
        ),
      ),
    );

    if (confirm != true) return;

    try {
      await SubscriptionRequestService.deleteRequest(requestId: request.requestId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حذف البطاقة')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('فشل حذف البطاقة: $e')));
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
        body: StreamBuilder<List<SubscriptionRequestModel>>(
          stream: SubscriptionRequestService.watchRequests(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('خطأ: ${snapshot.error}'));
            }

            final requests = snapshot.data ?? const <SubscriptionRequestModel>[];
            final q = _searchQuery.trim().toLowerCase();
            final filtered = q.isEmpty
                ? requests
                : requests.where((request) {
                    final fullName = '${request.firstName} ${request.lastName}'.trim().toLowerCase();
                    final plan = SubscriptionRequestService.planLabelFor(request.selectedPlan).toLowerCase();
                    final haystack = <String>[
                      fullName,
                      request.phone.toLowerCase(),
                      request.email.toLowerCase(),
                      request.requestId.toLowerCase(),
                      request.status.toLowerCase(),
                      request.selectedPlan.toLowerCase(),
                      plan,
                    ].join(' | ');
                    return haystack.contains(q);
                  }).toList();

            if (requests.isEmpty) {
              return const Center(child: Text('لا توجد طلبات اشتراك حالياً'));
            }

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: TextField(
                    controller: _searchController,
                    onChanged: (value) => setState(() => _searchQuery = value),
                    decoration: InputDecoration(
                      labelText: 'بحث بالاسم أو الهاتف أو البريد أو الحالة',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchQuery.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                              icon: const Icon(Icons.clear),
                            ),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(child: Text('لا توجد نتائج مطابقة للبحث'))
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final request = filtered[index];
                            final status = request.status;
                            final planLabel = SubscriptionRequestService.planLabelFor(request.selectedPlan);
                            final createdAt = request.createdAt;
                            final createdText = createdAt == null ? '—' : createdAt.toLocal().toString().split('.').first;

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
                                            '${request.firstName} ${request.lastName}',
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
                                        const SizedBox(width: 6),
                                        IconButton(
                                          tooltip: 'حذف البطاقة',
                                          onPressed: () => _deleteRequest(request),
                                          icon: const Icon(Icons.delete_outline, color: Color(0xFFC62828)),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    if (request.source.trim().toLowerCase() == 'paymentrequests') ...[
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFE3F2FD),
                                          borderRadius: BorderRadius.circular(999),
                                          border: Border.all(color: const Color(0xFF90CAF9)),
                                        ),
                                        child: const Text(
                                          'المصدر: طلبات الدفع',
                                          style: TextStyle(fontSize: 12, color: Color(0xFF1565C0), fontWeight: FontWeight.w700),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                    ],
                                    Text('الباقة: $planLabel'),
                                    Text('السعر: ${request.amount.isEmpty ? '—' : request.amount}'),
                                    Text('الهاتف: ${request.phone.isEmpty ? '—' : request.phone}'),
                                    Text('البريد: ${request.email.isEmpty ? '—' : request.email}'),
                                    Text('رقم التحويل: ${request.transferNumber.isEmpty ? '—' : request.transferNumber}'),
                                    Text('تاريخ الإرسال: $createdText'),
                                    const SizedBox(height: 10),
                                    if (request.receiptImageUrl.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 10),
                                        child: Text('صورة الإيصال: ${request.receiptImageUrl}'),
                                      ),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: ElevatedButton.icon(
                                            onPressed: status == 'approved' || status == 'rejected' ? null : () => _approve(request.requestId, request.toMap()),
                                            icon: const Icon(Icons.check_circle_outline),
                                            label: const Text('قبول'),
                                            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2E7D32)),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: OutlinedButton.icon(
                                            onPressed: status == 'approved' || status == 'rejected' ? null : () => _reject(request.requestId),
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
                        ),
                ),
              ],
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
