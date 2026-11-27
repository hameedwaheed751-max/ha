import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/services/whatsapp_notification_preferences.dart';

void main() {
  group('resolveManualTemplateMessage', () {
    test('prefers the saved event preference over the local fallback', () {
      final result = resolveManualTemplateMessage(
        preferenceMessage: 'نص منتهي جديد',
        fallback: 'نص افتراضي قديم',
      );
      expect(result, 'نص منتهي جديد');
    });

    test('falls back to the local template when preference is null', () {
      final result = resolveManualTemplateMessage(
        preferenceMessage: null,
        fallback: 'نص افتراضي قديم',
      );
      expect(result, 'نص افتراضي قديم');
    });

    test('falls back when preference is blank/whitespace only', () {
      final result = resolveManualTemplateMessage(
        preferenceMessage: '   ',
        fallback: 'نص افتراضي قديم',
      );
      expect(result, 'نص افتراضي قديم');
    });

    test('maps the expired template key to its preference event type', () {
      expect(manualTemplateEventTypes['expired'], 'subscription_expired');
      expect(manualTemplateEventTypes['activation'], 'subscription_activated');
      expect(manualTemplateEventTypes['nearExpiry'], 'expiry_3days');
      expect(manualTemplateEventTypes['debt'], 'debt_reminder');
      expect(manualTemplateEventTypes['debtPaid'], 'debt_paid');
      // 'extension' has no notification preference event.
      expect(manualTemplateEventTypes.containsKey('extension'), isFalse);
    });
  });
}
