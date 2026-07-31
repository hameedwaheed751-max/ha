import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models.dart';
import '../services/notification_export_service.dart';
import '../services/render_whatsapp_service.dart';

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  static const String _renderEndpointKey = 'render_whatsapp_endpoint';
  static const String _renderApiKeyKey = 'render_whatsapp_api_key';

  bool _sendingAutomatic = false;
  String _renderEndpoint = '';
  String _renderApiKey = '';
  List<WhatsAppSendLog> _logs = const [];

  @override
  void initState() {
    super.initState();
    _loadRenderConfig();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    final logs = await RenderWhatsAppService.loadLogs();
    if (!mounted) return;
    setState(() => _logs = logs);
  }

  Future<void> _loadRenderConfig() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _renderEndpoint = (prefs.getString(_renderEndpointKey) ?? '').trim();
      _renderApiKey = (prefs.getString(_renderApiKeyKey) ?? '').trim();
    });
  }

  Future<void> _openRenderConfigDialog() async {
    final endpointController = TextEditingController(text: _renderEndpoint);
    final tokenController = TextEditingController(text: _renderApiKey);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('إعدادات Render للإرسال التلقائي'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: endpointController,
                decoration: const InputDecoration(
                  labelText: 'Render Endpoint URL',
                  hintText: 'https://ha-0cs7.onrender.com/send-message',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: tokenController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'API Key (اختياري حسب خادم Render)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حفظ')),
          ],
        ),
      ),
    );

    if (saved != true) return;

    final prefs = await SharedPreferences.getInstance();
    _renderEndpoint = endpointController.text.trim();
    _renderApiKey = tokenController.text.trim();
    await prefs.setString(_renderEndpointKey, _renderEndpoint);
    await prefs.setString(RenderWhatsAppService.sendMessageEndpointKey, _renderEndpoint);
    await prefs.setString(_renderApiKeyKey, _renderApiKey);

    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم حفظ إعدادات Render بنجاح')),
    );
  }

  String fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  String normalizePhone(String phone) {
    var n = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (n.startsWith('0')) n = '964${n.substring(1)}';
    return n;
  }

  String _applyTemplate(String template, Subscriber s) {
    return template
        .replaceAll('{name}', s.name)
        .replaceAll('{user}', s.user)
        .replaceAll('{office}', AppStore.officeName)
        .replaceAll('{endDate}', fmt(s.endDate))
        .replaceAll('{price}', s.price.toStringAsFixed(0))
        .replaceAll('{paid}', s.paid.toStringAsFixed(0))
        .replaceAll('{remaining}', s.remaining.toStringAsFixed(0))
        .replaceAll('{package}', s.type);
  }

  List<Subscriber> _recipients(String type) {
    final now = DateTime.now();
    return AppStore.subscribers.where((s) {
      final days = s.endDate.difference(now).inDays;
      if (type == 'debt') return s.remaining > 0;
      if (type == 'threeDays') return days >= 0 && days <= 3;
      if (type == 'activated') return !s.expired && !s.disabled;
      return true;
    }).toList();
  }

  String _templateKey(String type) {
    if (type == 'debt') return 'debt';
    if (type == 'threeDays') return 'nearExpiry';
    if (type == 'activated') return 'activation';
    return 'general';
  }

  String _fallback(String type) {
    if (type == 'debt') {
      return 'مرحباً {name}، تذكير من {office}: المبلغ المتبقي عليك هو {remaining}. شكراً لكم.';
    }
    if (type == 'threeDays') {
      return 'مرحباً {name}، نذكرك من {office} أن اشتراكك ينتهي بتاريخ {endDate}. يرجى التجديد لتجنب انقطاع الخدمة.';
    }
    if (type == 'activated') {
      return 'مرحباً {name}، تم تفعيل اشتراكك بنجاح لدى {office}. الباقة: {package}، تاريخ الانتهاء: {endDate}. شكراً لكم.';
    }
    return 'مرحباً {name}، رسالة عامة من {office}.';
  }

  Future<void> _sendAutomaticCampaign(
    String type,
    List<Subscriber> recipients,
    String template,
    {
      String eventType = 'manual_campaign',
      String note = '',
    }
  ) async {
    if (_renderEndpoint.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يرجى ضبط Render Endpoint أولاً من زر الإعدادات في الأعلى')),
      );
      await _openRenderConfigDialog();
      if (_renderEndpoint.isEmpty) return;
    }

    final valid = recipients.where((s) => normalizePhone(s.phone).isNotEmpty).toList();
    if (valid.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد أرقام هاتف صالحة للإرسال التلقائي')),
      );
      return;
    }

    if (mounted) {
      setState(() => _sendingAutomatic = true);
    }

    try {
      RenderWhatsAppResult result;
      if (type == 'all') {
        result = await RenderWhatsAppService.sendBroadcastMessage(
          subscribers: valid,
          template: template,
          eventType: eventType,
          note: note,
        );
      } else {
        var sent = 0;
        var failed = 0;
        for (final s in valid) {
          final rendered = _applyTemplate(template, s);
          late final RenderSingleWhatsAppResult single;
          if (type == 'threeDays') {
            single = await RenderWhatsAppService.notifySubscriptionExpiresIn3Days(
              s,
              template: rendered,
            );
          } else if (type == 'debt') {
            single = await RenderWhatsAppService.notifyDebtAdded(
              s,
              amountAdded: 0,
              remainingBalance: s.remaining,
              template: rendered,
            );
          } else if (type == 'activated') {
            single = await RenderWhatsAppService.notifyGeneralMessageToSubscriber(
              s,
              message: rendered,
              template: '{message}',
            );
          } else {
            single = await RenderWhatsAppService.notifyGeneralMessageToSubscriber(
              s,
              message: rendered,
              template: '{message}',
            );
          }

          if (single.success) {
            sent += 1;
          } else {
            failed += 1;
          }
        }

        result = RenderWhatsAppResult(
          ok: failed == 0,
          total: valid.length,
          sent: sent,
          failed: failed,
          raw: {'eventType': eventType, 'note': note},
        );
      }

      if (!mounted) return;
      final sent = result.sent.toString();
      final failed = result.failed.toString();
      final total = result.total.toString();
      final ok = result.ok;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? 'تم الإرسال التلقائي عبر Render: $sent / $total'
                : 'اكتمل الإرسال مع أخطاء: ناجح $sent، فشل $failed من $total',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
      await _loadLogs();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل الإرسال عبر Render: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _sendingAutomatic = false);
      }
    }
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
              ...plan.map((group) => Text('${group.title}: ${group.recipients.length} مشترك')),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
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
      SnackBar(content: Text('تم نسخ البيانات بصيغة ${format == 'excel' ? 'Excel' : format == 'json' ? 'JSON' : 'CSV'} إلى الحافظة')),
    );
  }

  Future<void> _composeCampaign(String type, String title) async {
    final recipients = _recipients(type);
    final key = _templateKey(type);
    final initial = AppStore.messageTemplates[key] ?? _fallback(type);
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
                  Text('عدد المستلمين: ${recipients.length}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
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
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            FilledButton(
              onPressed: recipients.isEmpty ? null : () => Navigator.pop(ctx, true),
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
          content: Text('سيتم تجهيز الرسالة إلى ${recipients.length} مشترك. هل تريد المتابعة؟'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('رجوع')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تأكيد')),
          ],
        ),
      ),
    );

    if (confirmed != true) return;

    await _sendAutomaticCampaign(
      type,
      recipients,
      c.text,
      eventType: 'manual_$type',
      note: 'Manual campaign: $title',
    );
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
                        title: Text('${log.eventType} • ${log.sent}/${log.total}'),
                        subtitle: Text('${_fmtLogTime(log.at)}${log.note.isEmpty ? '' : ' • ${log.note}'}'),
                        trailing: Text('فشل ${log.failed}'),
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
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
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
        onTap: () => _composeCampaign(type, title),
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
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            IconButton(
              tooltip: 'إعدادات Render',
              onPressed: _openRenderConfigDialog,
              icon: const Icon(Icons.cloud_outlined),
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
                        'اختر مجموعة المستلمين، راجع نص الرسالة، ثم أكد ليتم الإرسال التلقائي عبر خادم Render المرتبط بـ developers.facebook.',
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
