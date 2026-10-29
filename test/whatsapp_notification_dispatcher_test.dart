import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';
import 'package:untitled/services/render_whatsapp_service.dart';
import 'package:untitled/services/waha_notification_service.dart';
import 'package:untitled/services/whatsapp_notification_dispatcher.dart';

Subscriber _subscriber() => Subscriber(
  subscriberId: '00000000-0000-4000-8000-000000000001',
  user: 'customer-1',
  name: 'مستخدم تجريبي',
  phone: '0790 000 0000',
  address: '',
  ip: '',
  type: 'الباقة التجريبية',
  price: 50000,
  startDate: DateTime(2026, 10, 20),
  endDate: DateTime(2026, 11, 20),
  paid: 20000,
);

void main() {
  test('WAHA is the default provider', () {
    expect(WhatsAppNotificationDispatcher.configuredProvider, WhatsAppProvider.waha);
    expect(WhatsAppNotificationDispatcher().provider, WhatsAppProvider.waha);
  });

  test('WAHA activation uses NetAgent template data and event idempotency', () async {
    final originalOfficeName = AppStore.officeName;
    final originalOfficePhone = AppStore.officePhone;
    AppStore.officeName = 'مكتب تجريبي';
    AppStore.officePhone = '0790 111 2222';
    addTearDown(() {
      AppStore.officeName = originalOfficeName;
      AppStore.officePhone = originalOfficePhone;
    });

    String? sentTo;
    String? sentText;
    String? sentEventType;
    String? sentIdempotencyKey;
    final dispatcher = WhatsAppNotificationDispatcher(
      provider: WhatsAppProvider.waha,
      wahaSender: ({
        required to,
        required text,
        required eventType,
        required idempotencyKey,
      }) async {
        sentTo = to;
        sentText = text;
        sentEventType = eventType;
        sentIdempotencyKey = idempotencyKey;
        return const WahaSendResult(success: true, messageId: 'message-1');
      },
    );

    final result = await dispatcher.notifySubscriptionActivated(
      _subscriber(),
      paidAmount: 20000,
      eventId: '2026-10-20T00:00:00.000',
    );

    expect(result.success, isTrue);
    expect(sentTo, '9647900000000');
    expect(sentEventType, 'subscription_activated');
    expect(
      sentIdempotencyKey,
      'subscription_activated:00000000-0000-4000-8000-000000000001:2026-10-20T00:00:00.000',
    );
    expect(sentText, contains('تم تفعيل اشتراك الإنترنت بنجاح'));
    expect(sentText, contains('الباقة: الباقة التجريبية'));
    expect(sentText, contains('المبلغ الواصل: 20000 دينار عراقي'));
    expect(sentText, contains('المبلغ المتبقي: 30000 دينار عراقي'));
    expect(sentText, contains('مكتب تجريبي'));
    expect(sentText, contains('9647901112222'));
  });

  test('WAHA failures are returned without falling back to Meta', () async {
    var sendCount = 0;
    final dispatcher = WhatsAppNotificationDispatcher(
      provider: WhatsAppProvider.waha,
      wahaSender: ({
        required to,
        required text,
        required eventType,
        required idempotencyKey,
      }) async {
        sendCount += 1;
        return const WahaSendResult(success: false, error: 'gateway unavailable');
      },
    );

    final result = await dispatcher.notifySubscriptionActivated(
      _subscriber(),
      eventId: 'activation-once',
    );

    expect(result.success, isFalse);
    expect(result.error, 'gateway unavailable');
    expect(sendCount, 1);
  });

  test('WAHA dispatches debt and both expiry notifications with stable event keys', () async {
    final sent = <({String eventType, String text, String idempotencyKey})>[];
    final dispatcher = WhatsAppNotificationDispatcher(
      provider: WhatsAppProvider.waha,
      wahaSender: ({
        required to,
        required text,
        required eventType,
        required idempotencyKey,
      }) async {
        sent.add((
          eventType: eventType,
          text: text,
          idempotencyKey: idempotencyKey,
        ));
        return const WahaSendResult(success: true);
      },
    );

    await dispatcher.notifyDebtReminder(
      _subscriber(),
      remainingBalance: 30000,
      template: 'الدين {{amount}} والمتبقي {{remaining_amount}}',
      eventId: '2026-10-22_debt',
    );
    await dispatcher.notifySubscriptionExpiresIn3Days(
      _subscriber(),
      template: 'ينتهي في {{subscription_end_date}}',
      eventId: '2026-10-22_near-expiry',
    );
    await dispatcher.notifySubscriptionExpired(
      _subscriber(),
      template: 'انتهى في {{subscription_end_date}}',
      eventId: '2026-10-22_expired',
    );

    expect(sent.map((entry) => entry.eventType), [
      'debt_reminder',
      'expiry_3days',
      'subscription_expired',
    ]);
    expect(sent[0].text, 'الدين 30000 والمتبقي 30000');
    expect(sent[1].text, 'ينتهي في 20/11/2026');
    expect(sent[2].text, 'انتهى في 20/11/2026');
    expect(
      sent.map((entry) => entry.idempotencyKey),
      [
        'debt_reminder:00000000-0000-4000-8000-000000000001:2026-10-22_debt',
        'expiry_3days:00000000-0000-4000-8000-000000000001:2026-10-22_near-expiry',
        'subscription_expired:00000000-0000-4000-8000-000000000001:2026-10-22_expired',
      ],
    );
  });

  test('WAHA dispatcher sends general messages, broadcasts, debt-paid, and payment notices', () async {
    final sent = <({String to, String text, String eventType, String idempotencyKey})>[];
    final dispatcher = WhatsAppNotificationDispatcher(
      wahaSender: ({
        required to,
        required text,
        required eventType,
        required idempotencyKey,
      }) async {
        sent.add((
          to: to,
          text: text,
          eventType: eventType,
          idempotencyKey: idempotencyKey,
        ));
        return const WahaSendResult(success: true);
      },
    );

    await dispatcher.sendSubscriberMessage(
      _subscriber(),
      message: 'رسالة تجريبية إلى {name}',
      eventType: 'general_message',
      eventId: 'manual-1',
    );
    await dispatcher.sendSubscriberMessage(
      _subscriber(),
      message: 'حملة إلى {name}',
      eventType: 'broadcast',
      eventId: 'campaign-1',
    );
    await dispatcher.notifyDebtPaid(
      _subscriber(),
      amountPaid: 20000,
      remainingBalance: 0,
      eventId: 'settled-1',
    );
    await dispatcher.sendText(
      to: '0790 000 0000',
      text: 'تم قبول طلب الدفع',
      eventType: 'payment_approved',
      idempotencyKey: 'payment_approved:request-1',
    );

    expect(sent.map((entry) => entry.eventType), [
      'general_message',
      'broadcast',
      'debt_paid',
      'payment_approved',
    ]);
    expect(sent.first.text, contains('رسالة تجريبية إلى مستخدم تجريبي'));
    expect(sent.first.idempotencyKey, contains('manual-1'));
    expect(sent[2].text, contains('المبلغ الواصل: 20000'));
    expect(sent.last.to, '9647900000000');
  });

  test('activation text is rendered using the same public Meta template renderer', () {
    final variables = <String, String>{
      'customer_name': 'مستخدم تجريبي',
      'package_name': 'الباقة التجريبية',
      'paid_amount': '20000',
      'remaining_amount': '30000',
      'subscription_start': '20/10/2026',
      'subscription_end': '20/11/2026',
      'agent_name': 'الوكيل',
      'whatsapp_number': '9647901112222',
    };
    final expected = RenderWhatsAppService.applyTemplate(
      AppStore.activationTemplate,
      variables,
    );
    expect(expected, contains('تم تفعيل اشتراك الإنترنت بنجاح'));
    expect(expected, contains('المبلغ الواصل: 20000 دينار عراقي'));
  });

  test('four specific event types always use WAHA even with meta provider', () async {
    final sent = <({String to, String text, String eventType, String idempotencyKey})>[];
    final dispatcher = WhatsAppNotificationDispatcher(
      provider: WhatsAppProvider.meta, // تم تعيين Provider إلى meta
      wahaSender: ({
        required to,
        required text,
        required eventType,
        required idempotencyKey,
      }) async {
        sent.add((
          to: to,
          text: text,
          eventType: eventType,
          idempotencyKey: idempotencyKey,
        ));
        return const WahaSendResult(success: true);
      },
    );

    // اختبار الأنواع الأربعة التي يجب أن تستخدم WAHA دائمًا
    await dispatcher.notifySubscriptionActivated(
      _subscriber(),
      eventId: 'test-activation',
    );
    await dispatcher.notifyDebtReminder(
      _subscriber(),
      remainingBalance: 50000,
      eventId: 'test-debt',
    );
    await dispatcher.notifySubscriptionExpiresIn3Days(
      _subscriber(),
      eventId: 'test-3days',
    );
    await dispatcher.notifySubscriptionExpired(
      _subscriber(),
      eventId: 'test-expired',
    );

    // التحقق من أن جميع الأنواع الأربعة تم إرسالها عبر WAHA
    expect(sent.length, 4);
    expect(sent.map((entry) => entry.eventType), [
      'subscription_activated',
      'debt_reminder',
      'expiry_3days',
      'subscription_expired',
    ]);
  });

  test('other event types respect provider setting (meta)', () async {
    var wahaCallCount = 0;
    
    final dispatcher = WhatsAppNotificationDispatcher(
      provider: WhatsAppProvider.meta,
      wahaSender: ({
        required to,
        required text,
        required eventType,
        required idempotencyKey,
      }) async {
        wahaCallCount++;
        return const WahaSendResult(success: true);
      },
    );

    // هذا النوع يجب أن يستخدم meta لأن provider=meta وليس من الأنواع الأربعة
    // نحن نختبر أن WAHA لم يتم استدعاؤها (لأن provider=meta)
    await dispatcher.notifyDebtPaid(
      _subscriber(),
      amountPaid: 20000,
      remainingBalance: 0,
      eventId: 'test-paid',
    );

    // التحقق من أن WAHA لم يتم استدعاؤها
    expect(wahaCallCount, 0);
  });

  test('other event types respect provider setting (waha)', () async {
    var wahaCallCount = 0;
    
    final dispatcher = WhatsAppNotificationDispatcher(
      provider: WhatsAppProvider.waha,
      wahaSender: ({
        required to,
        required text,
        required eventType,
        required idempotencyKey,
      }) async {
        wahaCallCount++;
        return const WahaSendResult(success: true);
      },
    );

    // هذا النوع ليس من الأربعة ولكن provider=waha
    await dispatcher.notifyDebtPaid(
      _subscriber(),
      amountPaid: 20000,
      remainingBalance: 0,
      eventId: 'test-paid-waha',
    );

    // التحقق من أن WAHA تم استدعاؤها مرة واحدة
    expect(wahaCallCount, 1);
  });
}
