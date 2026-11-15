import 'package:flutter/material.dart';

import '../services/subscriber_portal_service.dart';

String _when(DateTime t) =>
    '${t.year}/${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// تبويب «الدعم» في طلبات مشترك نت: تذاكر المشتركين المربوطين.
class SupportTicketsTab extends StatefulWidget {
  const SupportTicketsTab({super.key, required this.client});

  final SubscriberPortalClient client;

  @override
  State<SupportTicketsTab> createState() => _SupportTicketsTabState();
}

class _SupportTicketsTabState extends State<SupportTicketsTab>
    with AutomaticKeepAliveClientMixin {
  List<PortalTicket>? _items;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final items = await widget.client.supportTickets();
      if (mounted) setState(() => _items = items);
    } on PortalException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _open(PortalTicket ticket) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PortalTicketScreen(client: widget.client, ticket: ticket),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final items = _items;
    final scheme = Theme.of(context).colorScheme;
    Widget body;
    if (_error != null && items == null) {
      body = ListView(
        children: [
          const SizedBox(height: 120),
          Text(_error!, textAlign: TextAlign.center),
          Center(child: TextButton(onPressed: _load, child: const Text('إعادة المحاولة'))),
        ],
      );
    } else if (items == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (items.isEmpty) {
      body = ListView(
        children: const [
          SizedBox(height: 120),
          Text('لا توجد تذاكر دعم من المشتركين', textAlign: TextAlign.center),
        ],
      );
    } else {
      // بانتظار الرد أولاً، ثم الأحدث.
      final sorted = [...items]
        ..sort((a, b) {
          if (a.awaitingAgent != b.awaitingAgent) return a.awaitingAgent ? -1 : 1;
          return b.updatedAt.compareTo(a.updatedAt);
        });
      body = ListView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: sorted.length,
        itemBuilder: (context, i) {
          final t = sorted[i];
          return Card(
            margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: ListTile(
              onTap: () => _open(t),
              title: Text(t.subscriberName, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(
                '${t.categoryLabel} — ${t.messages.isEmpty ? '' : t.messages.last.text}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    t.statusLabel,
                    style: TextStyle(
                      color: t.awaitingAgent ? scheme.primary : scheme.outline,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(t.number, style: TextStyle(color: scheme.outline, fontSize: 12)),
                ],
              ),
            ),
          );
        },
      );
    }
    return RefreshIndicator(onRefresh: _load, child: body);
  }
}

/// محادثة التذكرة: رسائل المشترك والوكيل، والرد، والإغلاق.
class PortalTicketScreen extends StatefulWidget {
  const PortalTicketScreen({super.key, required this.client, required this.ticket});

  final SubscriberPortalClient client;
  final PortalTicket ticket;

  @override
  State<PortalTicketScreen> createState() => _PortalTicketScreenState();
}

class _PortalTicketScreenState extends State<PortalTicketScreen> {
  late PortalTicket _ticket = widget.ticket;
  final _text = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _run(Future<PortalTicket> Function() action) async {
    setState(() => _busy = true);
    try {
      final updated = await action();
      if (mounted) setState(() => _ticket = updated);
    } on PortalException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _busy) return;
    await _run(() => widget.client.replyToTicket(_ticket.id, text));
    if (mounted && !_busy) _text.clear();
  }

  Future<void> _close() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('إغلاق التذكرة'),
          content: const Text('يصل للمشترك إشعار بالإغلاق، ولا يستطيع الرد عليها بعده.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('تراجع')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('إغلاق')),
          ],
        ),
      ),
    );
    if (ok == true) await _run(() => widget.client.closeTicket(_ticket.id));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = _ticket;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text('${t.subscriberName} — ${t.number}'),
          actions: [
            if (!t.isClosed)
              TextButton(onPressed: _busy ? null : _close, child: const Text('إغلاق التذكرة')),
          ],
        ),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              color: scheme.surfaceContainerHighest,
              child: Text('${t.categoryLabel} • ${t.statusLabel}', textAlign: TextAlign.center),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: t.messages.length,
                itemBuilder: (context, i) {
                  final m = t.messages[i];
                  return Align(
                    alignment: m.fromSubscriber ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 320),
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: m.fromSubscriber ? scheme.surfaceContainerHigh : scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(m.author, style: TextStyle(fontSize: 12, color: scheme.outline)),
                          const SizedBox(height: 2),
                          Text(m.text),
                          const SizedBox(height: 2),
                          Text(_when(m.at), style: TextStyle(fontSize: 11, color: scheme.outline)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            if (t.isClosed)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('التذكرة مغلقة'),
              )
            else
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _text,
                          minLines: 1,
                          maxLines: 4,
                          maxLength: 1000,
                          decoration: const InputDecoration(
                            hintText: 'اكتب ردك للمشترك',
                            counterText: '',
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'إرسال',
                        onPressed: _busy ? null : _send,
                        icon: _busy
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.send),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
