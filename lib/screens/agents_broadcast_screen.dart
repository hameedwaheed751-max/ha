import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/render_whatsapp_service.dart';
import '../services/subscription_request_service.dart';
import '../services/whatsapp_notification_dispatcher.dart';

/// وكيل تصله رسالة المدير العامة على رقمه.
class AgentRecipient {
  const AgentRecipient({
    required this.uid,
    required this.name,
    required this.phone,
    required this.plan,
    required this.approved,
  });

  final String uid;
  final String name;
  final String phone;
  final String plan;
  final bool approved;
}

/// الوكلاء من طلبات الاشتراك: وكيل واحد لكل حساب ولكل رقم، بلا المحذوفين.
List<AgentRecipient> agentBroadcastRecipients(
  Iterable<SubscriptionRequestModel> requests, {
  bool approvedOnly = true,
  Map<String, AgentProfile> profiles = const {},
}) {
  final recipients = <AgentRecipient>[];
  final phones = <String>{};
  for (final agent in SubscriptionRequestService.groupByAgent(requests)) {
    final current = agent.current;
    if (current.uid.isEmpty || current.isDeleted) continue;
    final approved =
        current.status == SubscriptionRequestService.approvedStatus ||
        agent.older.any(
          (r) => r.status == SubscriptionRequestService.approvedStatus,
        );
    if (approvedOnly && !approved) continue;
    final profile = profiles[current.uid];
    final withPhone = [current, ...agent.older].firstWhere(
      (r) => RenderWhatsAppService.normalizePhone(r.phone).isNotEmpty,
      orElse: () => current,
    );
    // الرقم الذي عدّله الوكيل في ملفه يتقدم على رقم طلبه.
    final phone = RenderWhatsAppService.normalizePhone(
      profile?.phoneOr(withPhone.phone) ?? withPhone.phone,
    );
    if (phone.isEmpty || !phones.add(phone)) continue;
    final fromRequest = '${current.firstName} ${current.lastName}'.trim();
    final name = profile?.nameOr(fromRequest) ?? fromRequest;
    recipients.add(
      AgentRecipient(
        uid: current.uid,
        name: name.isEmpty ? current.email : name,
        phone: phone,
        plan: SubscriptionRequestService.planLabelFor(current.selectedPlan),
        approved: approved,
      ),
    );
  }
  recipients.sort((a, b) => a.name.compareTo(b.name));
  return recipients;
}

/// يملأ {name} باسم الوكيل و{plan} بباقته.
String renderAgentBroadcast(String template, AgentRecipient agent) => template
    .replaceAll('{name}', agent.name)
    .replaceAll('{{اسم الوكيل}}', agent.name)
    .replaceAll('{plan}', agent.plan);

/// رسالة عامة من المدير إلى أرقام الوكلاء عبر واتساب.
class AgentsBroadcastScreen extends StatefulWidget {
  const AgentsBroadcastScreen({super.key});

  static const templateKey = 'agents_broadcast_template';
  static const defaultTemplate =
      'مرحباً {name}،\n📢 رسالة عامة من إدارة تطبيق وكيل نت:\n\n\n\nشكراً لكم.';

  @override
  State<AgentsBroadcastScreen> createState() => _AgentsBroadcastScreenState();
}

class _AgentsBroadcastScreenState extends State<AgentsBroadcastScreen> {
  final _template = TextEditingController(
    text: AgentsBroadcastScreen.defaultTemplate,
  );
  late final Stream<List<SubscriptionRequestModel>> _requests =
      SubscriptionRequestService.watchRequests();
  bool _approvedOnly = true;
  Future<Map<String, AgentProfile>>? _profiles;
  final Set<String> _excluded = {};
  bool _sending = false;
  bool _stop = false;
  int _progress = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _loadTemplate();
  }

  @override
  void dispose() {
    _template.dispose();
    super.dispose();
  }

  Future<void> _loadTemplate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(AgentsBroadcastScreen.templateKey);
      if (saved != null && saved.trim().isNotEmpty && mounted) {
        _template.text = saved;
      }
    } catch (_) {}
  }

  Future<void> _saveTemplate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AgentsBroadcastScreen.templateKey, _template.text);
    } catch (_) {}
  }

  void _show(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 8)),
    );
  }

  Future<void> _send(List<AgentRecipient> recipients) async {
    final template = _template.text.trim();
    if (template.isEmpty) {
      _show('اكتب نص الرسالة أولاً');
      return;
    }
    if (recipients.isEmpty) {
      _show('لا يوجد وكيل محدد');
      return;
    }
    final minutes =
        (recipients.length *
                WhatsAppNotificationDispatcher.bulkMessageDelay.inSeconds /
                60)
            .ceil();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('إرسال الرسالة للوكلاء'),
          content: Text(
            'ستُرسل إلى ${recipients.length} وكيل من رقم واتساب المدير، '
            'رسالة كل ${WhatsAppNotificationDispatcher.bulkMessageDelay.inSeconds} '
            'ثانية (نحو $minutes دقيقة). أبقِ هذه الصفحة مفتوحة.\n\n'
            'مثال:\n${renderAgentBroadcast(template, recipients.first)}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('إرسال'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    await _saveTemplate();

    final campaign = DateTime.now().millisecondsSinceEpoch;
    final dispatcher = WhatsAppNotificationDispatcher();
    var sent = 0;
    var skipped = 0;
    var failed = 0;
    var rateLimited = false;
    String? firstError;
    setState(() {
      _sending = true;
      _stop = false;
      _progress = 0;
      _total = recipients.length;
    });
    for (var i = 0; i < recipients.length; i++) {
      if (_stop) break;
      if (mounted) setState(() => _progress = i + 1);
      final agent = recipients[i];
      WhatsAppDispatchResult result;
      try {
        result = await dispatcher.sendText(
          to: agent.phone,
          text: renderAgentBroadcast(template, agent),
          eventType: 'general_message',
          idempotencyKey: 'agents_broadcast:${campaign}_${agent.uid}',
        );
      } on Exception catch (e) {
        result = WhatsAppDispatchResult(success: false, error: '$e');
      }
      if (result.success) {
        sent++;
      } else if (result.wasSkipped) {
        skipped++;
      } else {
        failed++;
        firstError ??= result.friendlyError;
      }
      if (result.statusCode == 429) {
        rateLimited = true;
        break;
      }
      if (i < recipients.length - 1 && !_stop) {
        await Future<void>.delayed(
          WhatsAppNotificationDispatcher.bulkMessageDelay,
        );
      }
    }
    final notReached = recipients.length - sent - skipped - failed;
    final summary = [
      'أُرسلت $sent',
      if (skipped > 0) 'أُرسلت سابقاً $skipped',
      if (failed > 0) 'فشلت $failed',
      if (notReached > 0) 'لم تُرسل $notReached',
    ].join('، ');
    try {
      await RenderWhatsAppService.logCampaign(
        title: 'رسالة عامة للوكلاء',
        total: recipients.length,
        sent: sent,
        failed: failed,
        note: summary,
      );
    } catch (_) {}
    if (!mounted) return;
    setState(() => _sending = false);
    _show(
      [
        if (rateLimited) 'توقف الإرسال بطلب من بوابة واتساب',
        summary,
        ?firstError,
      ].join('\n'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('رسالة عامة للوكلاء'),
          centerTitle: true,
        ),
        body: StreamBuilder<List<SubscriptionRequestModel>>(
          stream: _requests,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text('خطأ: ${snapshot.error}'));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            _profiles ??= SubscriptionRequestService.loadAgentProfiles(
              snapshot.data!.map((r) => r.uid),
            );
            return FutureBuilder<Map<String, AgentProfile>>(
              future: _profiles,
              builder: (context, profiles) {
                if (profiles.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                return _body(
                  agentBroadcastRecipients(
                    snapshot.data!,
                    approvedOnly: _approvedOnly,
                    profiles: profiles.data ?? const {},
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _body(List<AgentRecipient> all) {
    final chosen = all.where((a) => !_excluded.contains(a.uid)).toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          key: const ValueKey('agents-broadcast-text'),
          controller: _template,
          enabled: !_sending,
          minLines: 5,
          maxLines: 12,
          decoration: const InputDecoration(
            labelText: 'نص الرسالة',
            helperText: '{name} اسم الوكيل، {plan} باقته في التطبيق',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('المقبولون')),
            ButtonSegment(value: false, label: Text('كل الوكلاء')),
          ],
          selected: {_approvedOnly},
          onSelectionChanged: _sending
              ? null
              : (value) => setState(() => _approvedOnly = value.first),
        ),
        const SizedBox(height: 12),
        if (_sending) ...[
          LinearProgressIndicator(
            value: _total == 0 ? null : _progress / _total,
          ),
          const SizedBox(height: 6),
          Text('جارٍ الإرسال $_progress من $_total'),
          TextButton(
            onPressed: () => setState(() => _stop = true),
            child: const Text('إيقاف'),
          ),
        ] else
          FilledButton.icon(
            key: const ValueKey('agents-broadcast-send'),
            onPressed: chosen.isEmpty ? null : () => _send(chosen),
            icon: const Icon(Icons.send_rounded),
            label: Text('إرسال إلى ${chosen.length} وكيل'),
          ),
        const SizedBox(height: 12),
        Text(
          'الوكلاء (${all.length}) — أزل العلامة عمن لا تريد مراسلته',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        if (all.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('لا يوجد وكيل له رقم هاتف'),
          ),
        for (final agent in all)
          CheckboxListTile(
            key: ValueKey('agent-${agent.uid}'),
            contentPadding: EdgeInsets.zero,
            value: !_excluded.contains(agent.uid),
            onChanged: _sending
                ? null
                : (on) => setState(
                    () => on == true
                        ? _excluded.remove(agent.uid)
                        : _excluded.add(agent.uid),
                  ),
            title: Text(agent.name),
            subtitle: Text(
              '${agent.phone} • ${agent.plan}'
              '${agent.approved ? '' : ' • لم يُقبل'}',
            ),
          ),
      ],
    );
  }
}
