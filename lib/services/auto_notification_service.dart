import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'render_whatsapp_service.dart';

class AutoNotificationService {
  static const String _dailyRunPrefix = 'wa_auto_daily_expiry_';

  static String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  static String _dayKey(DateTime now) =>
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

  static String _renderTemplate(String template, Subscriber s) {
    return template
        .replaceAll('{name}', s.name)
        .replaceAll('{user}', s.user)
        .replaceAll('{office}', AppStore.officeName)
        .replaceAll('{endDate}', _fmt(s.endDate))
        .replaceAll('{price}', s.price.toStringAsFixed(0))
        .replaceAll('{paid}', s.paid.toStringAsFixed(0))
        .replaceAll('{remaining}', s.remaining.toStringAsFixed(0))
        .replaceAll('{package}', s.type);
  }

  static Future<void> runDailyExpiryAutomation() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final day = _dayKey(now);

    if (prefs.getString(_dailyRunPrefix) == day) {
      return;
    }

    final nearTemplate = AppStore.messageTemplates['nearExpiry'] ??
        'مرحباً {name}، نذكرك أن اشتراكك ينتهي بتاريخ {endDate}. يرجى التجديد.';
    final expiredTemplate = AppStore.messageTemplates['expired'] ??
        'مرحباً {name}، اشتراكك لدى {office} منتهي. يرجى التجديد لاستمرار الخدمة.';

    final nearRecipients = <Map<String, String>>[];
    final expiredRecipients = <Map<String, String>>[];

    for (final s in AppStore.subscribers) {
      final phone = RenderWhatsAppService.normalizePhone(s.phone);
      if (phone.isEmpty) continue;

      final days = s.endDate.difference(now).inDays;

      if (!s.disabled && !s.expired && days >= 0 && days <= 3) {
        nearRecipients.add({
          'phone': phone,
          'message': _renderTemplate(nearTemplate, s),
        });
      }

      if (s.expired) {
        expiredRecipients.add({
          'phone': phone,
          'message': _renderTemplate(expiredTemplate, s),
        });
      }
    }

    if (nearRecipients.isNotEmpty) {
      await RenderWhatsAppService.sendCampaign(
        nearRecipients,
        eventType: 'auto_expiry_3days',
        note: 'Daily automatic: expiring within 3 days',
      );
    }
    if (expiredRecipients.isNotEmpty) {
      await RenderWhatsAppService.sendCampaign(
        expiredRecipients,
        eventType: 'auto_expired',
        note: 'Daily automatic: expired subscriptions',
      );
    }

    await prefs.setString(_dailyRunPrefix, day);
  }

  static Future<void> notifyDebtSettledIfNeeded({
    required Subscriber subscriber,
    required double oldRemaining,
    required double newRemaining,
  }) async {
    if (oldRemaining <= 0.0001 || newRemaining > 0.0001) {
      return;
    }

    final phone = RenderWhatsAppService.normalizePhone(subscriber.phone);
    if (phone.isEmpty) {
      return;
    }

    final office = AppStore.officeName.isEmpty ? 'المكتب' : AppStore.officeName;
    final message =
        'مرحباً ${subscriber.name}، تم تسديد كامل الدين لديك لدى $office. شكراً لكم.';

    await RenderWhatsAppService.sendCampaign(
      [
        {'phone': phone, 'message': message},
      ],
      eventType: 'auto_debt_settled',
      note: 'Debt settled to zero',
    );
  }
}
