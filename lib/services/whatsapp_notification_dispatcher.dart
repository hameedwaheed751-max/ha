import 'package:flutter/foundation.dart';

import '../models.dart';
import 'render_whatsapp_service.dart';
import 'whatsapp_notification_preferences.dart';
import 'waha_notification_service.dart';

enum WhatsAppProvider { meta, waha }

class WhatsAppDispatchResult {
  const WhatsAppDispatchResult({
    required this.success,
    this.error,
    this.messageId,
    this.statusCode,
  });

  final bool success;
  final String? error;
  final String? messageId;
  final int? statusCode;
}

typedef WahaTextSender =
    Future<WahaSendResult> Function({
      required String to,
      required String text,
      required String eventType,
      required String idempotencyKey,
    });

class WhatsAppNotificationDispatcher {
  WhatsAppNotificationDispatcher({
    this.provider = WhatsAppProvider.waha,
    WahaTextSender? wahaSender,
    WhatsAppNotificationPreferences? preferences,
  }) : _wahaSender = wahaSender ?? _defaultWahaSender,
       _preferences = preferences ?? FirebaseWhatsAppNotificationPreferences();

  static const String _providerDefine = String.fromEnvironment(
    'NETAGENT_WHATSAPP_PROVIDER',
    defaultValue: 'waha',
  );

  static WhatsAppProvider get configuredProvider =>
      _providerDefine.trim().toLowerCase() == 'waha'
      ? WhatsAppProvider.waha
      : WhatsAppProvider.meta;

  final WhatsAppProvider provider;
  final WahaTextSender _wahaSender;
  final WhatsAppNotificationPreferences _preferences;

  static Future<WahaSendResult> _defaultWahaSender({
    required String to,
    required String text,
    required String eventType,
    required String idempotencyKey,
  }) => WahaNotificationService.forCurrentUser().sendText(
    to: to,
    text: text,
    eventType: eventType,
    idempotencyKey: idempotencyKey,
  );

  Future<WhatsAppDispatchResult> notifySubscriptionActivated(
    Subscriber subscriber, {
    String? template,
    double? paidAmount,
    required String eventId,
  }) => _dispatch(
    subscriber: subscriber,
    type: WhatsAppNotificationType.subscriptionActivated,
    eventType: 'subscription_activated',
    eventId: eventId,
    template:
        template ??
        AppStore.messageTemplates['activation'] ??
        AppStore.activationTemplate,
    paidAmount: paidAmount,
  );

  Future<WhatsAppDispatchResult> notifyDebtReminder(
    Subscriber subscriber, {
    double amountAdded = 0,
    required double remainingBalance,
    String? template,
    required String eventId,
  }) => _dispatch(
    subscriber: subscriber,
    type: WhatsAppNotificationType.debtAdded,
    eventType: 'debt_reminder',
    eventId: eventId,
    template:
        template ?? AppStore.messageTemplates['debt'] ?? AppStore.debtTemplate,
    amount: amountAdded > 0 ? amountAdded : remainingBalance,
    balance: remainingBalance,
  );

  Future<WhatsAppDispatchResult> notifySubscriptionExpiresIn3Days(
    Subscriber subscriber, {
    String? template,
    required String eventId,
  }) => _dispatch(
    subscriber: subscriber,
    type: WhatsAppNotificationType.subscriptionExpiresIn3Days,
    eventType: 'expiry_3days',
    eventId: eventId,
    template:
        template ??
        AppStore.messageTemplates['nearExpiry'] ??
        AppStore.nearExpiryTemplate,
  );

  Future<WhatsAppDispatchResult> notifySubscriptionExpired(
    Subscriber subscriber, {
    String? template,
    required String eventId,
  }) => _dispatch(
    subscriber: subscriber,
    type: WhatsAppNotificationType.subscriptionExpired,
    eventType: 'subscription_expired',
    eventId: eventId,
    template:
        template ??
        AppStore.messageTemplates['expired'] ??
        'مرحباً {{customer_name}}،\n⚠️ اشتراكك لدى {{agent_name}} منتهي. يرجى التجديد لاستمرار الخدمة.\n📦 الباقة: {{package_name}}\n📅 تاريخ الانتهاء: {{subscription_end_date}}\n📱 {{whatsapp_number}}',
  );

  Future<WhatsAppDispatchResult> notifyDebtPaid(
    Subscriber subscriber, {
    required double amountPaid,
    required double remainingBalance,
    String? template,
    required String eventId,
  }) => _dispatch(
    subscriber: subscriber,
    type: WhatsAppNotificationType.debtPaid,
    eventType: 'debt_paid',
    eventId: eventId,
    template:
        template ??
        AppStore.messageTemplates['debtPaid'] ??
        'مرحباً {{customer_name}}،\n✅ تم استلام مبلغ الدين المترتب بذمتكم.\n💰 المبلغ الواصل: {{paid_amount}} دينار عراقي\n💰 المتبقي: {{remaining_amount}} دينار عراقي\nنشكر لكم التزامكم بالسداد.\nللاستفسار يرجى التواصل مع:\n🏢 {{agent_name}}\n📱 {{whatsapp_number}}\n\nشكراً لاختياركم خدمتنا.',
    amount: amountPaid,
    paidAmount: amountPaid,
    balance: remainingBalance,
  );

  Future<WhatsAppDispatchResult> sendSubscriberMessage(
    Subscriber subscriber, {
    required String message,
    required String eventType,
    required String eventId,
  }) async {
    final eventCheck = await _checkEvent(eventType);
    if (eventCheck.blocked != null) return eventCheck.blocked!;

    // تحديد الـ Provider بناءً على نوع الحدث
    // الرسائل الأربعة المطلوبة تذهب إلى WAHA
    // باقي الرسائل تستخدم الـ Provider المحدد (قد يكون meta أو waha حسب الإعداد)
    final effectiveProvider = switch (eventType) {
      'subscription_activated' => WhatsAppProvider.waha,
      'debt_reminder' => WhatsAppProvider.waha,
      'expiry_3days' => WhatsAppProvider.waha,
      'subscription_expired' => WhatsAppProvider.waha,
      _ => provider, // باقي الرسائل تستخدم الـ Provider المحدد في الإعدادات
    };

    if (effectiveProvider == WhatsAppProvider.meta) {
      final phone = RenderWhatsAppService.normalizePhone(subscriber.phone);
      if (phone.isEmpty) {
        return const WhatsAppDispatchResult(
          success: false,
          error: 'Subscriber has no valid phone number.',
        );
      }

      // استخدام Meta للرسائل العامة
      final result =
          await RenderWhatsAppService.notifyGeneralMessageToSubscriber(
            subscriber,
            message: eventCheck.preference?.message ?? message,
            template: '{message}',
          );

      return WhatsAppDispatchResult(
        success: result.success,
        error: result.error,
        messageId: result.messageId,
        statusCode: result.statusCode,
      );
    }

    final phone = RenderWhatsAppService.normalizePhone(subscriber.phone);
    final rendered = _appendAgentFooter(
      RenderWhatsAppService.applyTemplate(
        (eventCheck.preference?.message ?? message).trim(),
        _variablesForSubscriber(subscriber),
      ).trim(),
    );
    return _sendWahaText(
      to: phone,
      text: rendered,
      eventType: eventType,
      idempotencyKey: '$eventType:${subscriber.subscriberId}:$eventId',
    );
  }

  Future<WhatsAppDispatchResult> sendText({
    required String to,
    required String text,
    required String eventType,
    required String idempotencyKey,
  }) async {
    final eventCheck = await _checkEvent(eventType);
    if (eventCheck.blocked != null) return eventCheck.blocked!;

    // تحديد الـ Provider بناءً على نوع الحدث
    // الرسائل الأربعة المطلوبة تذهب إلى WAHA
    // باقي الرسائل تستخدم الـ Provider المحدد (قد يكون meta أو waha حسب الإعداد)
    final effectiveProvider = switch (eventType) {
      'subscription_activated' => WhatsAppProvider.waha,
      'debt_reminder' => WhatsAppProvider.waha,
      'expiry_3days' => WhatsAppProvider.waha,
      'subscription_expired' => WhatsAppProvider.waha,
      _ => provider, // باقي الرسائل تستخدم الـ Provider المحدد في الإعدادات
    };

    if (effectiveProvider == WhatsAppProvider.meta) {
      // استخدام Meta للرسائل العامة
      final result = await RenderWhatsAppService.sendSingleMessage(
        to: to,
        message: eventCheck.preference?.message ?? text,
      );

      return WhatsAppDispatchResult(
        success: result.success,
        error: result.error,
        messageId: result.messageId,
        statusCode: result.statusCode,
      );
    }

    return _sendWahaText(
      to: to,
      text: eventCheck.preference?.message ?? text,
      eventType: eventType,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<WhatsAppDispatchResult> _dispatch({
    required Subscriber subscriber,
    required WhatsAppNotificationType type,
    required String eventType,
    required String eventId,
    required String template,
    double? amount,
    double? paidAmount,
    double? balance,
  }) async {
    final eventCheck = await _checkEvent(eventType);
    if (eventCheck.blocked != null) return eventCheck.blocked!;
    final resolvedTemplate = eventCheck.preference?.message ?? template;

    // تحديد الـ Provider بناءً على نوع الحدث
    // الرسائل الأربعة المطلوبة تذهب إلى WAHA
    // باقي الرسائل تستخدم الـ Provider المحدد (قد يكون meta أو waha حسب الإعداد)
    final effectiveProvider = switch (eventType) {
      'subscription_activated' => WhatsAppProvider.waha,
      'debt_reminder' => WhatsAppProvider.waha,
      'expiry_3days' => WhatsAppProvider.waha,
      'subscription_expired' => WhatsAppProvider.waha,
      _ => provider, // باقي الرسائل تستخدم الـ Provider المحدد في الإعدادات
    };

    if (effectiveProvider == WhatsAppProvider.meta) {
      try {
        final result = switch (type) {
          WhatsAppNotificationType.subscriptionActivated =>
            await RenderWhatsAppService.notifySubscriptionActivated(
              subscriber,
              template: resolvedTemplate,
              paidAmount: paidAmount,
            ),
          WhatsAppNotificationType.debtAdded =>
            await RenderWhatsAppService.notifyDebtAdded(
              subscriber,
              amountAdded: amount ?? 0,
              remainingBalance: balance ?? subscriber.remaining,
              template: resolvedTemplate,
            ),
          WhatsAppNotificationType.subscriptionExpiresIn3Days =>
            await RenderWhatsAppService.notifySubscriptionExpiresIn3Days(
              subscriber,
              template: resolvedTemplate,
            ),
          WhatsAppNotificationType.subscriptionExpired =>
            await RenderWhatsAppService.notifySubscriptionExpired(
              subscriber,
              template: resolvedTemplate,
            ),
          WhatsAppNotificationType.debtPaid =>
            await RenderWhatsAppService.notifyDebtPaid(
              subscriber,
              amountPaid: amount ?? 0,
              remainingBalance: balance ?? subscriber.remaining,
              template: resolvedTemplate,
            ),
          WhatsAppNotificationType.subscriptionRenewed =>
            await RenderWhatsAppService.notifySubscriptionRenewed(
              subscriber,
              template: resolvedTemplate,
            ),
          WhatsAppNotificationType.generalMessage =>
            await RenderWhatsAppService.notifyGeneralMessageToSubscriber(
              subscriber,
              message: resolvedTemplate,
              template: '{message}',
            ),
          WhatsAppNotificationType.broadcast => throw StateError(
            'Broadcast notifications are handled separately.',
          ),
        };
        return WhatsAppDispatchResult(
          success: result.success,
          error: result.error,
          messageId: result.messageId,
          statusCode: result.statusCode,
        );
      } catch (error) {
        return WhatsAppDispatchResult(success: false, error: error.toString());
      }
    }

    final phone = RenderWhatsAppService.normalizePhone(subscriber.phone);
    if (phone.isEmpty) {
      return const WhatsAppDispatchResult(
        success: false,
        error: 'Subscriber has no valid phone number.',
      );
    }
    if (eventId.trim().isEmpty) {
      return const WhatsAppDispatchResult(
        success: false,
        error: 'A stable notification event ID is required.',
      );
    }

    final variables = _variablesForSubscriber(
      subscriber,
      amount: amount,
      paidAmount: paidAmount,
      balance: balance,
    );
    final rendered = _appendAgentFooter(
      RenderWhatsAppService.applyTemplate(
        resolvedTemplate.trim(),
        variables,
      ).trim(),
    );

    return _sendWahaText(
      to: phone,
      text: rendered,
      eventType: eventType,
      idempotencyKey: '$eventType:${subscriber.subscriberId}:$eventId',
    );
  }

  Future<_WhatsAppEventCheck> _checkEvent(String eventType) async {
    if (!FirebaseWhatsAppNotificationPreferences.eventTypes.contains(
      eventType,
    )) {
      return const _WhatsAppEventCheck();
    }
    try {
      final preference = await _preferences.load(eventType);
      if (!preference.enabled) {
        return _WhatsAppEventCheck(
          preference: preference,
          blocked: const WhatsAppDispatchResult(
            success: false,
            error: 'notification_disabled',
          ),
        );
      }
      return _WhatsAppEventCheck(preference: preference);
    } catch (_) {
      debugPrint('WhatsApp event settings could not be loaded.');
      return const _WhatsAppEventCheck(
        blocked: WhatsAppDispatchResult(
          success: false,
          error: 'notification_settings_unavailable',
        ),
      );
    }
  }

  Future<WhatsAppDispatchResult> _sendWahaText({
    required String to,
    required String text,
    required String eventType,
    required String idempotencyKey,
  }) async {
    final phone = RenderWhatsAppService.normalizePhone(to);
    if (phone.isEmpty || text.trim().isEmpty) {
      return const WhatsAppDispatchResult(
        success: false,
        error: 'Recipient and message are required.',
      );
    }

    if (eventType.trim().isEmpty || idempotencyKey.trim().isEmpty) {
      return const WhatsAppDispatchResult(
        success: false,
        error: 'Event type and idempotency key are required.',
      );
    }
    try {
      final result = await _wahaSender(
        to: phone,
        text: text.trim(),
        eventType: eventType,
        idempotencyKey: idempotencyKey,
      );
      return WhatsAppDispatchResult(
        success: result.success,
        error: result.error,
        messageId: result.messageId,
        statusCode: result.statusCode,
      );
    } catch (error) {
      return WhatsAppDispatchResult(success: false, error: error.toString());
    }
  }

  static Map<String, String> _variablesForSubscriber(
    Subscriber subscriber, {
    double? amount,
    double? paidAmount,
    double? balance,
  }) {
    String format(DateTime date) =>
        '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

    final package = subscriber.packageDisplay.trim();
    final agent = AppStore.effectiveAgentName.trim();
    final phone = RenderWhatsAppService.normalizePhone(AppStore.officePhone);
    final remaining = (balance ?? subscriber.remaining).toStringAsFixed(0);
    final payment = (paidAmount ?? subscriber.paid).toStringAsFixed(0);
    final resolvedAmount = (amount ?? balance ?? subscriber.remaining)
        .toStringAsFixed(0);
    final startDate = format(subscriber.startDate);
    final endDate = format(subscriber.endDate);
    final today = format(DateTime.now());

    return {
      'name': subscriber.name,
      'customerName': subscriber.name,
      'customer_name': subscriber.name,
      'user': subscriber.user,
      'office': AppStore.officeName,
      'package': package,
      'package_name': package,
      'startDate': startDate,
      'subscription_start': startDate,
      'subscription_start_date': startDate,
      'endDate': endDate,
      'subscription_end': endDate,
      'subscription_end_date': endDate,
      'expiryDate': endDate,
      'price': subscriber.price.toStringAsFixed(0),
      'subscription_amount': subscriber.price.toStringAsFixed(0),
      'paid': subscriber.paid.toStringAsFixed(0),
      'paid_amount': paidAmount == null ? payment : payment,
      'remaining': remaining,
      'balance': remaining,
      'remaining_amount': remaining,
      'amount': resolvedAmount,
      'debt_amount': resolvedAmount,
      'agentName': agent,
      'agent_name': agent,
      'date': today,
      'payment_date': today,
      'notification_date': today,
      'whatsappNumber': phone,
      'whatsapp_number': phone,
      'message': '',
    };
  }

  static String _appendAgentFooter(String message) {
    final agent = AppStore.effectiveAgentName.trim();
    final officePhone = AppStore.officePhone.trim();
    final parts = <String>[
      if (agent.isNotEmpty) agent,
      if (officePhone.isNotEmpty) officePhone,
    ];
    if (parts.isEmpty) return message;
    final allDigits = message.replaceAll(RegExp(r'[^0-9]'), '');
    final officeDigits = officePhone.replaceAll(RegExp(r'[^0-9]'), '');
    final normalizedOfficePhone = RenderWhatsAppService.normalizePhone(
      officePhone,
    );
    final hasPhone =
        (officeDigits.isNotEmpty && allDigits.contains(officeDigits)) ||
        (normalizedOfficePhone.isNotEmpty &&
            allDigits.contains(normalizedOfficePhone));
    final hasAgent = agent.isNotEmpty && message.contains(agent);
    if (hasPhone && hasAgent) return message;
    return '${message.trim()}\n🏢 ${parts.join(' • ')}'.trim();
  }
}

class _WhatsAppEventCheck {
  const _WhatsAppEventCheck({this.preference, this.blocked});

  final WhatsAppNotificationEventPreference? preference;
  final WhatsAppDispatchResult? blocked;
}
