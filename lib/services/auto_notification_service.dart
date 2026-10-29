import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'render_whatsapp_service.dart';
import 'whatsapp_notification_dispatcher.dart';

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
    final dispatcher = WhatsAppNotificationDispatcher();

    for (final s in AppStore.subscribers) {
      final phone = RenderWhatsAppService.normalizePhone(s.phone);
      if (phone.isEmpty) continue;

      final days = s.endDate.difference(now).inDays;

      if (!s.disabled && !s.expired && days >= 0 && days <= 3) {
        RenderWhatsAppService.dispatchInBackground(
          dispatcher.notifySubscriptionExpiresIn3Days(
            s,
            template: nearTemplate,
            eventId: '${day}_${s.subscriberId}_${s.endDate.millisecondsSinceEpoch}',
          ),
        );
      }

      if (s.expired) {
        RenderWhatsAppService.dispatchInBackground(
          dispatcher.notifySubscriptionExpired(
            s,
            template: expiredTemplate,
            eventId: '${day}_${s.subscriberId}_${s.endDate.millisecondsSinceEpoch}',
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
      WhatsAppNotificationDispatcher().notifyDebtPaid(
        subscriber,
        amountPaid: oldRemaining,
        remainingBalance: newRemaining,
        eventId:
            'settled_${subscriber.subscriberId}_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
  }
}
