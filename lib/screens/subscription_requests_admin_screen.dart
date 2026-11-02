import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models.dart';
import '../services/payment_request_service.dart';
import '../services/subscription_request_service.dart';
import '../services/whatsapp_notification_dispatcher.dart';

enum _AdminAction { changePlan, extend, endSubscription, resetPassword }

class SubscriptionRequestsAdminScreen extends StatefulWidget {
  const SubscriptionRequestsAdminScreen({super.key});

  @override
  State<SubscriptionRequestsAdminScreen> createState() =>
      _SubscriptionRequestsAdminScreenState();
}

class _SubscriptionRequestsAdminScreenState
    extends State<SubscriptionRequestsAdminScreen> {
  final TextEditingController _searchController = TextEditingController();
  late final Stream<List<SubscriptionRequestModel>> _requests =
      SubscriptionRequestService.watchRequests();
  String _searchQuery = '';
  bool _busy = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _agentName(SubscriptionRequestModel request) =>
      '${request.firstName} ${request.lastName}'.trim();

  String _safeEventId(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  String _dateText(DateTime? date) {
    if (date == null) return '—';
    final local = date.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')}/${local.year}';
  }

  /// القرار حُفظ قبل هذه الخطوة، فلا يُعرض فشلها على أنه فشل القبول أو الرفض.
  Future<bool> _afterDecision({
    required DailyTaskEvent event,
    required String phone,
    required String text,
    required String eventType,
    required String idempotencyKey,
  }) async {
    try {
      AppStore.addDailyTaskEvent(event);
      final result = await WhatsAppNotificationDispatcher().sendText(
        to: phone,
        text: text,
        eventType: eventType,
        idempotencyKey: idempotencyKey,
      );
      return result.success;
    } catch (e) {
      debugPrint('Notification failed for $eventType: $e');
      return false;
    }
  }

  Future<void> _approve(SubscriptionRequestModel request) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final data = await SubscriptionRequestService.approveRequestById(
        requestId: request.requestId,
        requestData: request.toMap(),
        collectionPath: request.collectionPath,
      );
      final planLabel = (data['planLabel'] ?? '').toString();
      final endDate = DateTime.tryParse((data['endDate'] ?? '').toString());
      final notified = await _afterDecision(
        event: DailyTaskEvent(
          type: 'payment_approved',
          subscriberUser: request.email,
          subscriberName: _agentName(request),
          at: DateTime.now(),
          note: 'تم قبول طلب الدفع - $planLabel',
        ),
        phone: request.phone,
        text:
            'مرحباً ${_agentName(request)}،\n✅ تم قبول طلب الاشتراك بنجاح.\n📦 الباقة: $planLabel\n📅 ينتهي الاشتراك: ${_dateText(endDate)}\n\nشكراً لاختياركم خدمتنا.',
        eventType: 'payment_approved',
        idempotencyKey: 'payment_approved:${_safeEventId(request.requestId)}',
      );
      _showMessage(
        notified
            ? 'تم قبول الطلب بنجاح'
            : 'تم قبول الطلب وتفعيل الاشتراك، لكن تعذر إرسال رسالة واتساب للوكيل',
      );
    } catch (e) {
      _showMessage('فشل قبول الطلب: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject(SubscriptionRequestModel request) async {
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
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, reasonController.text.trim()),
              child: const Text('تأكيد'),
            ),
          ],
        ),
      ),
    );
    reasonController.dispose();
    if (reason == null || !mounted) return;

    setState(() => _busy = true);
    try {
      await SubscriptionRequestService.rejectRequest(
        requestId: request.requestId,
        reason: reason,
        collectionPath: request.collectionPath,
      );
      final notified = await _afterDecision(
        event: DailyTaskEvent(
          type: 'payment_rejected',
          subscriberUser: request.email,
          subscriberName: _agentName(request),
          at: DateTime.now(),
          note: reason,
        ),
        phone: request.phone,
        text:
            'مرحباً ${_agentName(request)}،\n❌ تم رفض طلب الاشتراك.\nالسبب: $reason\n\nللاستفسار يرجى التواصل مع:\n🏢 ${AppStore.effectiveAgentName}\n\nشكراً لكم.',
        eventType: 'payment_rejected',
        idempotencyKey: 'payment_rejected:${_safeEventId(request.requestId)}',
      );
      _showMessage(
        notified
            ? 'تم رفض الطلب'
            : 'تم رفض الطلب، لكن تعذر إرسال رسالة واتساب للوكيل',
      );
    } catch (e) {
      _showMessage('فشل رفض الطلب: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteRequest(SubscriptionRequestModel request) async {
    final confirmed = await _confirm(
      title: 'حذف البطاقة',
      content: 'هل تريد حذف بطاقة الطلب الخاصة بـ ${_agentName(request)}؟',
      confirmLabel: 'حذف',
    );
    if (!confirmed) return;
    await _runAction(() async {
      await SubscriptionRequestService.deleteRequest(
        requestId: request.requestId,
        collectionPath: request.collectionPath,
      );
      return 'تم حذف البطاقة';
    }, 'فشل حذف البطاقة');
  }

  Future<void> _runAction(
    Future<String> Function() action,
    String failurePrefix,
  ) async {
    try {
      _showMessage(await action());
    } catch (e) {
      _showMessage('$failurePrefix: $e');
    }
  }

  Future<bool> _confirm({
    required String title,
    required String content,
    required String confirmLabel,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ),
    );
    return confirmed == true;
  }

  Future<void> _changePlan(SubscriptionRequestModel request) async {
    final current = PaymentPlanCatalog.normalize(request.selectedPlan);
    final plan = await showDialog<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SimpleDialog(
          title: const Text('تغيير الباقة'),
          children: [
            for (final option in PaymentPlanCatalog.supportedPlans)
              SimpleDialogOption(
                onPressed: option == current
                    ? null
                    : () => Navigator.of(ctx).pop(option),
                child: Text(
                  SubscriptionRequestService.planLabel(option) +
                      (option == current ? ' (الحالية)' : ''),
                ),
              ),
          ],
        ),
      ),
    );
    if (plan == null) return;
    await _runAction(() async {
      await PaymentRequestService.changeRequestPlan(
        requestId: request.requestId,
        plan: plan,
        collectionPath: request.collectionPath,
      );
      return 'تم تغيير الباقة إلى ${SubscriptionRequestService.planLabel(plan)}';
    }, 'فشل تغيير الباقة');
  }

  Future<void> _extend(SubscriptionRequestModel request) async {
    final daysController = TextEditingController(text: '30');
    final days = await showDialog<int>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تمديد الاشتراك'),
          content: TextField(
            controller: daysController,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'عدد الأيام',
              helperText: 'تُضاف بعد المدة المتبقية',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(int.tryParse(daysController.text)),
              child: const Text('تمديد'),
            ),
          ],
        ),
      ),
    );
    daysController.dispose();
    if (days == null) return;
    if (days < 1 || days > 3650) {
      _showMessage('أدخل عدد أيام بين 1 و3650');
      return;
    }
    await _runAction(() async {
      final end = await SubscriptionRequestService.extendSubscription(
        uid: request.uid,
        days: days,
      );
      return 'تم تمديد الاشتراك حتى ${_dateText(end)}';
    }, 'فشل التمديد');
  }

  Future<void> _endSubscription(SubscriptionRequestModel request) async {
    final confirmed = await _confirm(
      title: 'إنهاء الاشتراك',
      content:
          'سيُسجَّل خروج ${_agentName(request)} خلال أقل من دقيقة إذا كان متصلاً، ويمكنك إعادته بالتمديد.',
      confirmLabel: 'إنهاء الاشتراك',
    );
    if (!confirmed) return;
    await _runAction(() async {
      await SubscriptionRequestService.endSubscription(uid: request.uid);
      return 'تم إنهاء الاشتراك';
    }, 'فشل إنهاء الاشتراك');
  }

  Future<void> _resetPassword(SubscriptionRequestModel request) async {
    final confirmed = await _confirm(
      title: 'إعادة تعيين كلمة المرور',
      content:
          'سيصل إلى ${request.email} رابط يختار به الوكيل كلمة مرور جديدة.',
      confirmLabel: 'إرسال الرابط',
    );
    if (!confirmed) return;
    await _runAction(() async {
      await SubscriptionRequestService.sendPasswordReset(email: request.email);
      return 'تم إرسال رابط إعادة التعيين إلى ${request.email}';
    }, 'فشل إرسال الرابط');
  }

  void _onAdminAction(_AdminAction action, SubscriptionRequestModel request) {
    switch (action) {
      case _AdminAction.changePlan:
        _changePlan(request);
      case _AdminAction.extend:
        _extend(request);
      case _AdminAction.endSubscription:
        _endSubscription(request);
      case _AdminAction.resetPassword:
        _resetPassword(request);
    }
  }

  List<PopupMenuEntry<_AdminAction>> _adminActions(
    SubscriptionRequestModel request,
    bool canReview,
  ) {
    final approved =
        request.status == SubscriptionRequestService.approvedStatus;
    final hasAgent = request.uid.isNotEmpty;
    return [
      if (canReview || (approved && hasAgent))
        const PopupMenuItem(
          value: _AdminAction.changePlan,
          child: Text('تغيير الباقة'),
        ),
      if (approved && hasAgent) ...const [
        PopupMenuItem(
          value: _AdminAction.extend,
          child: Text('تمديد الاشتراك'),
        ),
        PopupMenuItem(
          value: _AdminAction.endSubscription,
          child: Text('إنهاء الاشتراك'),
        ),
      ],
      if (request.email.isNotEmpty)
        const PopupMenuItem(
          value: _AdminAction.resetPassword,
          child: Text('إعادة تعيين كلمة المرور'),
        ),
    ];
  }

  Future<void> _showReceipt(String url) => showDialog<void>(
    context: context,
    builder: (ctx) => Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('صورة الإيصال'),
        content: SizedBox(
          width: 360,
          child: InteractiveViewer(
            child: Image.network(url, fit: BoxFit.contain),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    ),
  );

  bool _isOpen(SubscriptionRequestModel request) =>
      request.status == SubscriptionRequestService.pendingStatus ||
      request.status == SubscriptionRequestService.reviewingStatus;

  bool _matchesSearch(SubscriptionRequestModel request) {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [
      _agentName(request),
      request.phone,
      request.email,
      request.requestId,
      request.selectedPlan,
      SubscriptionRequestService.planLabelFor(request.selectedPlan),
    ].join(' | ').toLowerCase().contains(q);
  }

  Widget _requestList(
    List<SubscriptionRequestModel> requests,
    String emptyText,
  ) {
    if (requests.isEmpty) return Center(child: Text(emptyText));
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: requests.length,
      itemBuilder: (context, index) => _requestCard(requests[index]),
    );
  }

  Widget _requestCard(SubscriptionRequestModel request) {
    final status = request.status;
    final canReview = SubscriptionRequestService.isOpenForReview({
      'status': status,
      'reviewedAt': request.reviewedAt,
    });
    final createdAt = request.createdAt;
    final createdText = createdAt == null
        ? '—'
        : createdAt.toLocal().toString().split('.').first;
    final isFree = SubscriptionRequestService.isTrialPlan(request.selectedPlan);

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
                    _agentName(request).isEmpty
                        ? 'وكيل بدون اسم'
                        : _agentName(request),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _statusColor(status),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    _statusLabel(status),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                PopupMenuButton<_AdminAction>(
                  tooltip: 'إدارة الوكيل',
                  onSelected: (action) => _onAdminAction(action, request),
                  itemBuilder: (_) => _adminActions(request, canReview),
                ),
                if (request.collectionPath ==
                        SubscriptionRequestService.collectionName &&
                    SubscriptionRequestService.canDelete({
                      'status': status,
                      'reviewedAt': request.reviewedAt,
                    }))
                  IconButton(
                    tooltip: 'حذف البطاقة',
                    onPressed: () => _deleteRequest(request),
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Color(0xFFC62828),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'الباقة: ${SubscriptionRequestService.planLabelFor(request.selectedPlan)}',
            ),
            Text('السعر: ${request.amount.isEmpty ? '—' : request.amount}'),
            Text('الهاتف: ${request.phone.isEmpty ? '—' : request.phone}'),
            Text('البريد: ${request.email.isEmpty ? '—' : request.email}'),
            Text(
              'رقم التحويل: ${request.transferNumber.isEmpty ? '—' : request.transferNumber}',
            ),
            Text('تاريخ الإرسال: $createdText'),
            if (request.isRenewal) const Text('النوع: تجديد'),
            if (request.source == 'trial') const Text('النوع: تجربة مجانية'),
            if (request.rejectionReason.isNotEmpty)
              Text('سبب الرفض: ${request.rejectionReason}'),
            if (canReview &&
                !isFree &&
                PaymentRequestService.receiptUploadsEnabled &&
                request.receiptImageUrl.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'لا يوجد وصل، تأكد من التحويل قبل القبول',
                  style: TextStyle(
                    color: Color(0xFFC62828),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            if (request.receiptImageUrl.isNotEmpty) ...[
              const SizedBox(height: 10),
              InkWell(
                onTap: () => _showReceipt(request.receiptImageUrl),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.network(
                    request.receiptImageUrl,
                    height: 180,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ],
            if (canReview) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy || request.uid.isEmpty
                          ? null
                          : () => _approve(request),
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('قبول'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF2E7D32),
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
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
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: DefaultTabController(
        length: 3,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('طلبات الاشتراك'),
            centerTitle: true,
          ),
          body: StreamBuilder<List<SubscriptionRequestModel>>(
            stream: _requests,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(child: Text('خطأ: ${snapshot.error}'));
              }

              final requests = (snapshot.data ?? const [])
                  .where(_matchesSearch)
                  .toList();
              final open = requests.where(_isOpen).toList();
              final approved = requests
                  .where(
                    (request) =>
                        request.status ==
                        SubscriptionRequestService.approvedStatus,
                  )
                  .toList();
              final rejected = requests
                  .where(
                    (request) =>
                        request.status ==
                        SubscriptionRequestService.rejectedStatus,
                  )
                  .toList();

              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: TextField(
                      controller: _searchController,
                      onChanged: (value) =>
                          setState(() => _searchQuery = value),
                      decoration: InputDecoration(
                        labelText: 'بحث بالاسم أو الهاتف أو البريد أو الباقة',
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
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  TabBar(
                    tabs: [
                      Tab(text: 'معلق (${open.length})'),
                      Tab(text: 'مقبول (${approved.length})'),
                      Tab(text: 'مرفوض (${rejected.length})'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _requestList(open, 'لا توجد طلبات معلقة'),
                        _requestList(approved, 'لا توجد طلبات مقبولة'),
                        _requestList(rejected, 'لا توجد طلبات مرفوضة'),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  String _statusLabel(String status) => switch (status) {
    SubscriptionRequestService.approvedStatus => 'مقبول',
    SubscriptionRequestService.rejectedStatus => 'مرفوض',
    SubscriptionRequestService.reviewingStatus => 'قيد القبول',
    _ => 'معلق',
  };

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
