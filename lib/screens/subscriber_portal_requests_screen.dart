import 'package:flutter/material.dart';

import '../services/subscriber_portal_service.dart';
import 'subscriber_portal_support.dart';

/// طلبات التجديد وتذاكر الدعم الواردة من تطبيق «مشترك نت».
/// القبول لا يفعّل شيئاً: التفعيل يبقى بزر التفعيل المعتاد، وبعده يصل
/// «تم التجديد» للمشترك تلقائياً حين يتقدّم تاريخ انتهائه.
class SubscriberPortalRequestsScreen extends StatefulWidget {
  const SubscriberPortalRequestsScreen({super.key, this.client});

  final SubscriberPortalClient? client;

  @override
  State<SubscriberPortalRequestsScreen> createState() =>
      _SubscriberPortalRequestsScreenState();
}

class _SubscriberPortalRequestsScreenState
    extends State<SubscriberPortalRequestsScreen> {
  late final SubscriberPortalClient _client =
      widget.client ?? SubscriberPortalSync.instance.client;
  List<PortalRenewal>? _items;
  bool? _showDebt;
  String? _error;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final results = await Future.wait([_client.renewals(), _client.showDebt()]);
      if (!mounted) return;
      setState(() {
        _items = results[0] as List<PortalRenewal>;
        _showDebt = results[1] as bool;
      });
      // يرسل «تم التجديد» لما فُعّل منذ آخر حفظ.
      if (widget.client == null) SubscriberPortalSync.instance.schedule();
    } on PortalException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _act(String id, Future<void> Function() action) async {
    setState(() => _busy.add(id));
    try {
      await action();
      await _load();
    } on PortalException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<String?> _askReason({required String title, required String hint}) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 200,
            decoration: InputDecoration(hintText: hint),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                final text = controller.text.trim();
                if (text.isNotEmpty) Navigator.pop(context, text);
              },
              child: const Text('إرسال'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(PortalRenewal r) {
    final busy = _busy.contains(r.id);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    r.subscriberName,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ),
                Text(r.number, style: TextStyle(color: scheme.outline)),
              ],
            ),
            const SizedBox(height: 4),
            Text('${r.packageName} — ${r.quotedPrice.toStringAsFixed(0)} د.ع'),
            const SizedBox(height: 4),
            Text(
              r.statusLabel,
              style: TextStyle(
                color: r.status == 'pending' ? scheme.primary : scheme.outline,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (r.rejectReason.isNotEmpty) Text('السبب: ${r.rejectReason}'),
            if (r.status == 'approved')
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'فعّل المشترك من قائمة المشتركين كالمعتاد؛ يصله «تم التجديد» تلقائياً بعد التفعيل.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (r.isOpen)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: busy
                    ? const LinearProgressIndicator()
                    : Wrap(
                        spacing: 8,
                        children: [
                          if (r.status == 'pending')
                            FilledButton(
                              onPressed: () => _act(r.id, () => _client.approve(r.id)),
                              child: const Text('قبول'),
                            ),
                          OutlinedButton(
                            onPressed: () async {
                              final reason = await _askReason(
                                title: 'رفض الطلب',
                                hint: 'سبب يظهر للمشترك',
                              );
                              if (reason != null) {
                                await _act(r.id, () => _client.reject(r.id, reason));
                              }
                            },
                            child: const Text('رفض'),
                          ),
                          if (r.status == 'approved')
                            TextButton(
                              onPressed: () async {
                                final note = await _askReason(
                                  title: 'تعذّر التفعيل',
                                  hint: 'ماذا حدث؟',
                                );
                                if (note != null) {
                                  await _act(r.id, () => _client.fail(r.id, note));
                                }
                              },
                              child: const Text('تعذّر التنفيذ'),
                            ),
                        ],
                      ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    Widget body;
    if (_error != null && items == null) {
      body = ListView(
        children: [
          const SizedBox(height: 120),
          Icon(Icons.cloud_off, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Center(child: TextButton(onPressed: _load, child: const Text('إعادة المحاولة'))),
        ],
      );
    } else if (items == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      final open = items.where((r) => r.isOpen).toList();
      final closed = items.where((r) => !r.isOpen).take(30).toList();
      body = ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          SwitchListTile(
            title: const Text('إظهار المستحقات للمشتركين'),
            subtitle: const Text('يرى المشترك المتبقي عليه ودفعاته في التطبيق'),
            value: _showDebt ?? false,
            onChanged: (value) => _act('settings', () => _client.setShowDebt(value)),
          ),
          const Divider(),
          if (open.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text('لا طلبات مفتوحة', textAlign: TextAlign.center),
            ),
          ...open.map(_card),
          if (closed.isNotEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('السابقة', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ...closed.map(_card),
        ],
      );
    }
    return Directionality(
      textDirection: TextDirection.rtl,
      child: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('طلبات مشترك نت'),
            centerTitle: true,
            bottom: const TabBar(tabs: [Tab(text: 'التجديد'), Tab(text: 'الدعم')]),
          ),
          body: TabBarView(
            children: [
              RefreshIndicator(onRefresh: _load, child: body),
              SupportTicketsTab(client: _client),
            ],
          ),
        ),
      ),
    );
  }
}
