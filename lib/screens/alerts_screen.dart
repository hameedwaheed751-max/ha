import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models.dart';
import '../services/auto_notification_service.dart';
import '../services/notification_export_service.dart';
import '../services/render_whatsapp_service.dart';
import '../services/whatsapp_notification_dispatcher.dart';
import '../services/whatsapp_notification_preferences.dart';

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  bool _sendingAutomatic = false;
  bool _stopRequested = false;
  int _sendProgress = 0;
  int _sendTotal = 0;
  List<WhatsAppSendLog> _logs = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadLogs();
    });
  }

  @override
  void dispose() {
    _stopRequested = true;
    super.dispose();
  }

  Future<void> _loadLogs() async {
    final logs = await RenderWhatsAppService.loadLogs();
    if (!mounted) return;
    setState(() => _logs = logs);
  }

  String fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  String _applyTemplate(String template, Subscriber s) {
    final paid = s.paid.toStringAsFixed(0);
    final remaining = s.remaining.toStringAsFixed(0);
    return template
        .replaceAll('{name}', s.name)
        .replaceAll('{{الاسم المشترك}}', s.name)
        .replaceAll('{user}', s.user)
        .replaceAll('{office}', AppStore.officeName)
        .replaceAll('{{اسم الوكيل}}', AppStore.officeName)
        .replaceAll('{package}', s.packageDisplay)
        .replaceAll('{{اسم الباقة}}', s.packageDisplay)
        .replaceAll('{{تاريخ البدء}}', fmt(s.startDate))
        .replaceAll('{endDate}', fmt(s.endDate))
        .replaceAll('{{تاريخ الانتهاء}}', fmt(s.endDate))
        .replaceAll('{price}', s.price.toStringAsFixed(0))
        .replaceAll('{{مبلغ الاشتراك}}', s.price.toStringAsFixed(0))
        .replaceAll('{{المبلغ}}', remaining)
        .replaceAll('{paid}', paid)
        .replaceAll('{{الواصل}}', 'الواصل: $paid')
        .replaceAll('{remaining}', remaining)
        .replaceAll('{{المتبقي}}', 'المتبقي: $remaining');
  }

  List<Subscriber> _recipients(String type) {
    final now = DateTime.now();
    return AppStore.subscribers.where((s) {
      if (RenderWhatsAppService.normalizePhone(s.phone).isEmpty) return false;
      if (type == 'debt') return s.remaining > 0;
      if (type == 'threeDays') {
        final remaining = s.endDate.difference(now);
        return s.active &&
            !s.disabled &&
            remaining > Duration.zero &&
            remaining <= const Duration(hours: 72);
      }
      if (type == 'activated') return !s.expired && !s.disabled;
      return true;
    }).toList();
  }

  String? _eventType(String type) => switch (type) {
    'debt' => 'debt_reminder',
    'threeDays' => 'expiry_3days',
    'activated' => 'subscription_activated',
    _ => null,
  };

  /// النص المعروض للمراجعة هو ما يُرسله الحدث نفسه تلقائياً.
  Future<String?> _savedEventMessage(String type) async {
    final eventType = _eventType(type);
    if (eventType == null) return null;
    try {
      return (await FirebaseWhatsAppNotificationPreferences().load(
        eventType,
      )).message;
    } catch (_) {
      return null;
    }
  }

  String _templateKey(String type) {
    if (type == 'debt') return 'debt';
    if (type == 'threeDays') return 'nearExpiry';
    if (type == 'activated') return 'activation';
    return 'general';
  }

  String _fallback(String type) {
    if (type == 'debt') {
      return 'مرحباً {{الاسم المشترك}}،\n✅ يوجد دين مترتب بذمتكم جراء تفعيل الاشتراك.\n💰 يرجى تسديد: {{المبلغ}} دينار عراقي\n📅 لضمان استمرار الخدمة\nنشكر لكم التزامكم بالسداد.\nللاستفسار يرجى التواصل مع:\n🏢 {{اسم الوكيل}}\n\nشكراً لاختياركم خدمتنا.';
    }
    if (type == 'threeDays') {
      return 'مرحباً {{الاسم المشترك}}،\n⏳ نود إعلامكم بأن اشتراك الإنترنت سينتهي قريباً.\n📅 تاريخ انتهاء الاشتراك: {{تاريخ الانتهاء}}\nلضمان استمرار الخدمة دون انقطاع، يرجى مراجعة:\n🏢 {{اسم الوكيل}}\n\nشكراً لاختياركم خدمتنا.';
    }
    if (type == 'activated') {
      return 'مرحباً {{الاسم المشترك}}،\n✅ تم تفعيل اشتراك الإنترنت بنجاح.\n📦 الباقة: {{اسم الباقة}}\n📅 يبدأ الاشتراك: {{تاريخ البدء}}\n📅 ينتهي الاشتراك: {{تاريخ الانتهاء}}\nمبلغ الاشتراك:{{مبلغ الاشتراك}}\n{{الواصل}}\n{{المتبقي}}\nللاستفسار يرجى التواصل مع:\n🏢 {{اسم الوكيل}}\n\nشكراً لاختياركم خدمتنا.';
    }
    return 'مرحباً {name}، رسالة عامة من {office}.';
  }

  Future<WhatsAppDispatchResult> _sendOne(
    WhatsAppNotificationDispatcher dispatcher,
    String type,
    Subscriber s,
    String template, {
    required String runDay,
    required int campaignId,
  }) {
    final rendered = _applyTemplate(template, s);
    return switch (type) {
      'threeDays' => AutoNotificationService.sendNearExpiryManually(
        s,
        template: rendered,
      ),
      'debt' => dispatcher.notifyDebtReminder(
        s,
        remainingBalance: s.remaining,
        template: rendered,
        composedText: true,
        eventId:
            '${runDay}_${s.subscriberId}_${s.remaining.toStringAsFixed(0)}',
      ),
      'activated' => dispatcher.notifySubscriptionActivated(
        s,
        template: rendered,
        composedText: true,
        eventId:
            '${runDay}_${s.subscriberId}_${s.endDate.millisecondsSinceEpoch}',
      ),
      _ => dispatcher.sendSubscriberMessage(
        s,
        message: rendered,
        eventType: 'broadcast',
        eventId: '${runDay}_${campaignId}_${s.subscriberId}',
      ),
    };
  }

  Future<void> _sendCampaign(
    String type,
    List<Subscriber> recipients,
    String template, {
    required String title,
  }) async {
    final runDay = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    final campaignId = DateTime.now().microsecondsSinceEpoch;
    final dispatcher = WhatsAppNotificationDispatcher();
    var sent = 0;
    var skipped = 0;
    var failed = 0;
    var rateLimited = false;
    String? firstError;

    setState(() {
      _sendingAutomatic = true;
      _stopRequested = false;
      _sendProgress = 0;
      _sendTotal = recipients.length;
    });
    for (var index = 0; index < recipients.length; index++) {
      if (_stopRequested) break;
      if (mounted) setState(() => _sendProgress = index + 1);
      WhatsAppDispatchResult result;
      try {
        result = await _sendOne(
          dispatcher,
          type,
          recipients[index],
          template,
          runDay: runDay,
          campaignId: campaignId,
        );
      } on Exception {
        result = const WhatsAppDispatchResult(success: false);
      }
      if (result.success) {
        sent += 1;
      } else if (result.wasSkipped) {
        skipped += 1;
        continue;
      } else {
        failed += 1;
        firstError ??= result.friendlyError;
      }
      if (result.statusCode == 429) {
        rateLimited = true;
        break;
      }
      if (index < recipients.length - 1 && !_stopRequested) {
        await Future<void>.delayed(
          WhatsAppNotificationDispatcher.bulkMessageDelay,
        );
      }
    }

    final notReached = recipients.length - sent - skipped - failed;
    final parts = <String>[
      'أُرسلت $sent',
      if (skipped > 0) 'أُرسلت سابقاً $skipped',
      if (failed > 0) 'فشلت $failed',
      if (notReached > 0) 'لم تُرسل $notReached',
    ];
    final summary = parts.join('، ');
    await RenderWhatsAppService.logCampaign(
      title: title,
      total: recipients.length,
      sent: sent,
      failed: failed,
      note: summary,
    );
    if (!mounted) return;
    setState(() => _sendingAutomatic = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          [
            if (rateLimited) 'توقف الإرسال بطلب من بوابة WhatsApp',
            summary,
            ?firstError,
          ].join('\n'),
        ),
        duration: const Duration(seconds: 8),
      ),
    );
    await _loadLogs();
  }

  Future<void> _showExportMenu() async {
    final plan = buildAutomaticNotificationPlan(AppStore.subscribers);
    await showDialog<void>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تصدير البيانات'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.table_chart_outlined),
                title: const Text('تصدير CSV'),
                subtitle: const Text('ملف جدول يحتوي على جميع المشتركين'),
                onTap: () {
                  Navigator.pop(ctx);
                  _exportData('csv');
                },
              ),
              ListTile(
                leading: const Icon(Icons.table_view_outlined),
                title: const Text('تصدير Excel'),
                subtitle: const Text('ملف تنسيق جدول مناسب لبرنامج Excel'),
                onTap: () {
                  Navigator.pop(ctx);
                  _exportData('excel');
                },
              ),
              const SizedBox(height: 8),
              ...plan.map(
                (group) =>
                    Text('${group.title}: ${group.recipients.length} مشترك'),
              ),
            ],
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
  }

  Future<void> _exportData(String format) async {
    final content = format == 'excel'
        ? exportSubscribersToExcel(AppStore.subscribers)
        : format == 'json'
        ? exportSubscribersToJson(AppStore.subscribers)
        : exportSubscribersToCsv(AppStore.subscribers);

    await Clipboard.setData(ClipboardData(text: content));

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'تم نسخ البيانات بصيغة ${format == 'excel'
              ? 'Excel'
              : format == 'json'
              ? 'JSON'
              : 'CSV'} إلى الحافظة',
        ),
      ),
    );
  }

  Future<void> _composeCampaign(String type, String title) async {
    final recipients = _recipients(type);
    final key = _templateKey(type);
    final saved = AppStore.messageTemplates[key] ?? '';
    final initial =
        await _savedEventMessage(type) ??
        (saved.trim().isEmpty ? _fallback(type) : saved);
    final c = TextEditingController(text: initial);

    if (!mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'عدد المستلمين: ${recipients.length}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: c,
                    minLines: 4,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      labelText: 'نص الرسالة',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'يمكن استخدام: {name} {user} {office} {endDate} {price} {paid} {remaining} {package}',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: recipients.isEmpty
                  ? null
                  : () => Navigator.pop(ctx, true),
              child: const Text('متابعة'),
            ),
          ],
        ),
      ),
    );

    if (approved != true || recipients.isEmpty) return;

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تأكيد الإرسال'),
          content: Text(
            'ستُرسل الرسالة إلى ${recipients.length} مشترك بفاصل ${WhatsAppNotificationDispatcher.bulkMessageDelay.inSeconds} ثانية، وتستغرق نحو ${_durationText(recipients.length)}. أبقِ هذه الشاشة مفتوحة حتى ينتهي الإرسال.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('رجوع'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('تأكيد'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;

    await _sendCampaign(type, recipients, c.text, title: title);
  }

  String _durationText(int recipients) {
    final seconds =
        (recipients - 1) *
        WhatsAppNotificationDispatcher.bulkMessageDelay.inSeconds;
    return seconds < 60 ? 'أقل من دقيقة' : '${(seconds / 60).ceil()} دقيقة';
  }

  String _fmtLogTime(DateTime d) {
    final date =
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    final time =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return '$date $time';
  }

  Future<void> _showLogs() async {
    await _loadLogs();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('سجل إرسال واتساب'),
          content: SizedBox(
            width: 520,
            child: _logs.isEmpty
                ? const Center(child: Text('لا يوجد سجل إرسال بعد'))
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: _logs.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final log = _logs[i];
                      return ListTile(
                        leading: Icon(
                          log.ok ? Icons.check_circle : Icons.error_outline,
                          color: log.ok ? Colors.green : Colors.red,
                        ),
                        title: Text(
                          '${log.eventType} • ${log.sent}/${log.total}',
                        ),
                        subtitle: Text(
                          '${_fmtLogTime(log.at)}${log.note.isEmpty ? '' : ' • ${log.note}'}',
                        ),
                        trailing: Text('فشل ${log.failed}'),
                        onTap: log.responseBody == null
                            ? null
                            : () => showDialog<void>(
                                context: ctx,
                                builder: (detailsContext) => Directionality(
                                  textDirection: TextDirection.rtl,
                                  child: AlertDialog(
                                    title: Text(
                                      log.ok
                                          ? 'تفاصيل الرد ${log.statusCode ?? ''}'
                                          : 'تفاصيل الخطأ ${log.statusCode ?? ''}',
                                    ),
                                    content: SelectableText(
                                      JsonEncoder.withIndent(
                                        '  ',
                                      ).convert(log.responseBody),
                                      textDirection: TextDirection.ltr,
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(detailsContext),
                                        child: const Text('إغلاق'),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await RenderWhatsAppService.clearLogs();
                await _loadLogs();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('مسح السجل'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _campaignCard({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required String type,
  }) {
    final count = _recipients(type).length;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: .12),
          child: Icon(icon, color: color),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('$subtitle • $count مشترك'),
        trailing: const Icon(Icons.chevron_left),
        onTap: _sendingAutomatic ? null : () => _composeCampaign(type, title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('التنبيهات والرسائل'),
          centerTitle: true,
          actions: [
            if (_sendingAutomatic)
              TextButton.icon(
                onPressed: _stopRequested
                    ? null
                    : () => setState(() => _stopRequested = true),
                icon: const Icon(Icons.stop_circle_outlined),
                label: Text('إيقاف $_sendProgress/$_sendTotal'),
              ),
            IconButton(
              tooltip: 'سجل الإرسال',
              onPressed: _showLogs,
              icon: const Icon(Icons.history_outlined),
            ),
            IconButton(
              tooltip: 'التصدير والإشعارات',
              onPressed: _showExportMenu,
              icon: const Icon(Icons.download_outlined),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Row(
                  children: [
                    Icon(Icons.campaign, size: 32),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'اختر مجموعة المستلمين، راجع نص الرسالة، ثم أكد ليتم الإرسال عبر حساب WhatsApp المرتبط، برسالة كل 15 ثانية.',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            _campaignCard(
              icon: Icons.notifications_active,
              color: Colors.deepOrange,
              title: 'ينتهي اشتراكهم خلال 3 أيام',
              subtitle: 'تنبيه للمشتركين قبل انتهاء الاشتراك',
              type: 'threeDays',
            ),
            _campaignCard(
              icon: Icons.check_circle_outline,
              color: Colors.green,
              title: 'رسائل التفعيل وتاريخ الانتهاء',
              subtitle: 'رسالة التفعيل والباقة وتاريخ انتهاء الاشتراك',
              type: 'activated',
            ),
            _campaignCard(
              icon: Icons.money_off,
              color: Colors.red,
              title: 'رسائل المديونين',
              subtitle: 'رسالة للمشتركين الذين لديهم مبلغ متبقي',
              type: 'debt',
            ),
            _campaignCard(
              icon: Icons.groups,
              color: Colors.blue,
              title: 'رسالة عامة',
              subtitle: 'إعلان أو تنبيه عام لكل المشتركين',
              type: 'all',
            ),
          ],
        ),
      ),
    );
  }
}
