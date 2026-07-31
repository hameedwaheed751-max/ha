import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'render_whatsapp_service.dart';

class AutoNotificationService {
  static const String _dailyRunPrefix = 'wa_auto_daily_expiry_';

  static String _dayKey(DateTime now) =>
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

  static Future<void> runDailyExpiryAutomation() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final day = _dayKey(now);

    if (prefs.getString(_dailyRunPrefix) == day) {
      return;
    }

    final nearTemplate = AppStore.messageTemplates['nearExpiry'];
    final expiredTemplate = AppStore.messageTemplates['expired'];

    for (final s in AppStore.subscribers) {
      final phone = RenderWhatsAppService.normalizePhone(s.phone);
      if (phone.isEmpty) continue;

      final days = s.endDate.difference(now).inDays;

      if (!s.disabled && !s.expired && days >= 0 && days <= 3) {
        RenderWhatsAppService.dispatchInBackground(
          RenderWhatsAppService.notifySubscriptionExpiresIn3Days(
            s,
            template: nearTemplate,
          ),
        );
      }

      if (s.expired) {
        RenderWhatsAppService.dispatchInBackground(
          RenderWhatsAppService.notifySubscriptionExpired(
            s,
            template: expiredTemplate,
          ),
        );
      }
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

    RenderWhatsAppService.dispatchInBackground(
      RenderWhatsAppService.notifyDebtPaid(
        subscriber,
        amountPaid: oldRemaining,
        remainingBalance: newRemaining,
      ),
    );
  }
}
