import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';

enum WhatsAppNotificationType {
  subscriptionRenewed,
  subscriptionExpiresIn3Days,
  subscriptionExpired,
  debtAdded,
  debtPaid,
  generalMessage,
  broadcast,
}

extension WhatsAppNotificationTypeX on WhatsAppNotificationType {
  String get eventType {
    switch (this) {
      case WhatsAppNotificationType.subscriptionRenewed:
        return 'subscription_renewed';
      case WhatsAppNotificationType.subscriptionExpiresIn3Days:
        return 'subscription_expires_3days';
      case WhatsAppNotificationType.subscriptionExpired:
        return 'subscription_expired';
      case WhatsAppNotificationType.debtAdded:
        return 'debt_added';
      case WhatsAppNotificationType.debtPaid:
        return 'debt_paid';
      case WhatsAppNotificationType.generalMessage:
        return 'general_single';
      case WhatsAppNotificationType.broadcast:
        return 'broadcast';
    }
  }
}

class RenderWhatsAppResult {
  const RenderWhatsAppResult({
    required this.ok,
    required this.total,
    required this.sent,
    required this.failed,
    this.raw,
  });

  final bool ok;
  final int total;
  final int sent;
  final int failed;
  final Map<String, dynamic>? raw;
}

class RenderSingleWhatsAppResult {
  const RenderSingleWhatsAppResult({
    required this.success,
    this.messageId,
    this.error,
    this.details,
    this.statusCode,
  });

  final bool success;
  final String? messageId;
  final String? error;
  final Map<String, dynamic>? details;
  final int? statusCode;
}

class WhatsAppSendLog {
  const WhatsAppSendLog({
    required this.at,
    required this.eventType,
    required this.total,
    required this.sent,
    required this.failed,
    required this.ok,
    this.note = '',
    this.to = '',
    this.attempt = 1,
    this.statusCode,
    this.endpoint = '',
    this.requestBody,
    this.responseBody,
  });

  final DateTime at;
  final String eventType;
  final int total;
  final int sent;
  final int failed;
  final bool ok;
  final String note;
  final String to;
  final int attempt;
  final int? statusCode;
  final String endpoint;
  final Map<String, dynamic>? requestBody;
  final Map<String, dynamic>? responseBody;

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'eventType': eventType,
        'total': total,
        'sent': sent,
        'failed': failed,
        'ok': ok,
        'note': note,
        'to': to,
        'attempt': attempt,
        'statusCode': statusCode,
        'endpoint': endpoint,
        'requestBody': requestBody,
        'responseBody': responseBody,
      };

  factory WhatsAppSendLog.fromJson(Map<String, dynamic> j) => WhatsAppSendLog(
        at: DateTime.tryParse((j['at'] ?? '').toString()) ?? DateTime.now(),
        eventType: (j['eventType'] ?? 'unknown').toString(),
        total: (j['total'] as num?)?.toInt() ?? 0,
        sent: (j['sent'] as num?)?.toInt() ?? 0,
        failed: (j['failed'] as num?)?.toInt() ?? 0,
        ok: j['ok'] == true,
        note: (j['note'] ?? '').toString(),
        to: (j['to'] ?? '').toString(),
        attempt: (j['attempt'] as num?)?.toInt() ?? 1,
        statusCode: (j['statusCode'] as num?)?.toInt(),
        endpoint: (j['endpoint'] ?? '').toString(),
        requestBody: j['requestBody'] is Map
            ? Map<String, dynamic>.from(j['requestBody'] as Map)
            : null,
        responseBody: j['responseBody'] is Map
            ? Map<String, dynamic>.from(j['responseBody'] as Map)
            : null,
      );
}

class RenderWhatsAppService {
  static const String endpointKey = 'render_whatsapp_endpoint';
  static const String sendMessageEndpointKey = 'render_send_message_endpoint';
  static const String apiKeyKey = 'render_whatsapp_api_key';
  static const String logsKey = 'render_whatsapp_send_logs';
  static const int maxLogs = 200;
  static const String _defaultSendEndpoint = 'https://ha-0cs7.onrender.com/send-message';
  static const String _embeddedApiKey = '';
  static const int _maxAttempts = 3;

  static String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  static String _templateForType(WhatsAppNotificationType type) {
    final map = AppStore.messageTemplates;
    switch (type) {
      case WhatsAppNotificationType.subscriptionRenewed:
        return map['extension'] ??
            'مرحباً {name}، تم تجديد اشتراكك بنجاح لدى {office} حتى {endDate}.';
      case WhatsAppNotificationType.subscriptionExpiresIn3Days:
        return map['nearExpiry'] ??
            'مرحباً {name}، نذكرك أن اشتراكك ينتهي بتاريخ {endDate}. يرجى التجديد.';
      case WhatsAppNotificationType.subscriptionExpired:
        return map['expired'] ??
            'مرحباً {name}، اشتراكك لدى {office} منتهي. يرجى التجديد لاستمرار الخدمة.';
      case WhatsAppNotificationType.debtAdded:
        return map['debt'] ??
            'مرحباً {name}، تمت إضافة مبلغ جديد عليك. المتبقي الحالي: {balance}.';
      case WhatsAppNotificationType.debtPaid:
        return 'مرحباً {name}، تم تسديد مبلغ {amount} بنجاح. الرصيد المتبقي: {balance}. شكراً لكم.';
      case WhatsAppNotificationType.generalMessage:
        return '{message}';
      case WhatsAppNotificationType.broadcast:
        return '{message}';
    }
  }

  static Map<String, String> _variablesForSubscriber(
    Subscriber s, {
    String? message,
    double? amount,
    double? balance,
    String? packageName,
    DateTime? expiryDate,
    String? agentName,
  }) {
    final resolvedPackage = (packageName ?? s.packageDisplay).trim();
    final resolvedAmount = amount == null ? '' : amount.toStringAsFixed(0);
    final resolvedBalance = (balance ?? s.remaining).toStringAsFixed(0);
    final resolvedAgent = (agentName ?? AppStore.agentName).trim();

    return {
      'name': s.name,
      'customerName': s.name,
      'user': s.user,
      'office': AppStore.officeName,
      'package': resolvedPackage,
      'endDate': _fmt(expiryDate ?? s.endDate),
      'expiryDate': _fmt(expiryDate ?? s.endDate),
      'price': s.price.toStringAsFixed(0),
      'paid': s.paid.toStringAsFixed(0),
      'remaining': resolvedBalance,
      'balance': resolvedBalance,
      'amount': resolvedAmount,
      'agentName': resolvedAgent,
      'message': message ?? '',
    };
  }

  static String applyTemplate(String template, Map<String, String> variables) {
    var out = template;
    for (final entry in variables.entries) {
      out = out.replaceAll('{${entry.key}}', entry.value);
    }
    return out;
  }

  static Future<(String endpoint, String apiKey)> loadConfig() async {
    return (_defaultSendEndpoint, _embeddedApiKey);
  }

  static Future<String> loadSendMessageEndpoint() async {
    return _defaultSendEndpoint;
  }

  static String normalizePhone(String phone) {
    var n = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (n.startsWith('0')) n = '964${n.substring(1)}';
    return n;
  }

  static Future<List<WhatsAppSendLog>> loadLogs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(logsKey);
    if (raw == null || raw.isEmpty) return const <WhatsAppSendLog>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <WhatsAppSendLog>[];
      return decoded
          .whereType<Map>()
          .map((e) => WhatsAppSendLog.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return const <WhatsAppSendLog>[];
    }
  }

  static Future<void> _appendLog(WhatsAppSendLog log) async {
    final prefs = await SharedPreferences.getInstance();
    final logs = await loadLogs();
    final updated = <WhatsAppSendLog>[log, ...logs];
    if (updated.length > maxLogs) {
      updated.removeRange(maxLogs, updated.length);
    }
    await prefs.setString(
      logsKey,
      jsonEncode(updated.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> _appendAttemptLog({
    required String eventType,
    required String to,
    required int attempt,
    required bool ok,
    required String note,
    required String endpoint,
    Map<String, dynamic>? requestBody,
    Map<String, dynamic>? responseBody,
    int? statusCode,
  }) async {
    await _appendLog(
      WhatsAppSendLog(
        at: DateTime.now(),
        eventType: eventType,
        total: 1,
        sent: ok ? 1 : 0,
        failed: ok ? 0 : 1,
        ok: ok,
        note: note,
        to: to,
        attempt: attempt,
        statusCode: statusCode,
        endpoint: endpoint,
        requestBody: requestBody,
        responseBody: responseBody,
      ),
    );
  }

  static Future<void> clearLogs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(logsKey);
  }

  static Future<RenderSingleWhatsAppResult> _sendCore({
    required String to,
    required String message,
    required String eventType,
    String note = '',
    int maxAttempts = _maxAttempts,
  }) async {
    final normalizedPhone = normalizePhone(to);
    final cleanMessage = message.trim();
    if (normalizedPhone.isEmpty || cleanMessage.isEmpty) {
      return const RenderSingleWhatsAppResult(
        success: false,
        error: 'Both "to" and "message" are required',
      );
    }

    final endpoint = await loadSendMessageEndpoint();
    final config = await loadConfig();
    final apiKey = config.$2;
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };

    if (apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer $apiKey';
      headers['x-api-key'] = apiKey;
      headers['x-proxy-token'] = apiKey;
    }

    final payload = <String, dynamic>{
      'to': normalizedPhone,
      'message': cleanMessage,
    };

    RenderSingleWhatsAppResult? lastFailure;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final response = await http
            .post(
              Uri.parse(endpoint),
              headers: headers,
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 25));

        Map<String, dynamic> data = <String, dynamic>{};
        if (response.body.isNotEmpty) {
          try {
            final decoded = jsonDecode(response.body);
            if (decoded is Map<String, dynamic>) {
              data = decoded;
            }
          } catch (_) {}
        }

        final successByStatus = response.statusCode >= 200 && response.statusCode < 300;
        final success = successByStatus && (data['success'] != false);

        await _appendAttemptLog(
          eventType: eventType,
          to: normalizedPhone,
          attempt: attempt,
          ok: success,
          note: success ? (note.isEmpty ? 'Delivered' : note) : 'HTTP ${response.statusCode}',
          endpoint: endpoint,
          requestBody: payload,
          responseBody: data.isNotEmpty ? data : {'raw': response.body},
          statusCode: response.statusCode,
        );

        if (success) {
          return RenderSingleWhatsAppResult(
            success: true,
            messageId: (data['messageId'] ?? '').toString(),
            details: data,
            statusCode: response.statusCode,
          );
        }

        lastFailure = RenderSingleWhatsAppResult(
          success: false,
          error: (data['error'] ?? 'HTTP ${response.statusCode}').toString(),
          details: data.isNotEmpty ? data : {'raw': response.body},
          statusCode: response.statusCode,
        );
      } catch (e) {
        await _appendAttemptLog(
          eventType: eventType,
          to: normalizedPhone,
          attempt: attempt,
          ok: false,
          note: 'Transport error',
          endpoint: endpoint,
          requestBody: payload,
          responseBody: {'error': e.toString()},
        );
        lastFailure = RenderSingleWhatsAppResult(
          success: false,
          error: e.toString(),
        );
      }

      if (attempt < maxAttempts) {
        await Future.delayed(Duration(milliseconds: 900 * attempt));
      }
    }

    return lastFailure ??
        const RenderSingleWhatsAppResult(
          success: false,
          error: 'Unknown WhatsApp sending failure',
        );
  }

  static Future<RenderSingleWhatsAppResult> _notifyByType({
    required WhatsAppNotificationType type,
    required Subscriber subscriber,
    String? template,
    String? message,
    double? amount,
    double? balance,
    String? packageName,
    DateTime? expiryDate,
    String? agentName,
  }) async {
    final phone = normalizePhone(subscriber.phone);
    if (phone.isEmpty) {
      return const RenderSingleWhatsAppResult(
        success: false,
        error: 'Subscriber has no valid phone number',
      );
    }

    final tmpl = (template ?? _templateForType(type)).trim();
    final vars = _variablesForSubscriber(
      subscriber,
      message: message,
      amount: amount,
      balance: balance,
      packageName: packageName,
      expiryDate: expiryDate,
      agentName: agentName,
    );

    final rendered = applyTemplate(tmpl, vars).trim();
    return _sendCore(
      to: phone,
      message: rendered,
      eventType: type.eventType,
      note: type.eventType,
    );
  }

  static Future<RenderSingleWhatsAppResult> notifySubscriptionRenewed(
    Subscriber subscriber, {
    String? template,
  }) {
    return _notifyByType(
      type: WhatsAppNotificationType.subscriptionRenewed,
      subscriber: subscriber,
      template: template,
    );
  }

  static Future<RenderSingleWhatsAppResult> notifySubscriptionExpiresIn3Days(
    Subscriber subscriber, {
    String? template,
  }) {
    return _notifyByType(
      type: WhatsAppNotificationType.subscriptionExpiresIn3Days,
      subscriber: subscriber,
      template: template,
    );
  }

  static Future<RenderSingleWhatsAppResult> notifySubscriptionExpired(
    Subscriber subscriber, {
    String? template,
  }) {
    return _notifyByType(
      type: WhatsAppNotificationType.subscriptionExpired,
      subscriber: subscriber,
      template: template,
    );
  }

  static Future<RenderSingleWhatsAppResult> notifyDebtAdded(
    Subscriber subscriber, {
    required double amountAdded,
    required double remainingBalance,
    String? template,
  }) {
    return _notifyByType(
      type: WhatsAppNotificationType.debtAdded,
      subscriber: subscriber,
      template: template,
      amount: amountAdded,
      balance: remainingBalance,
    );
  }

  static Future<RenderSingleWhatsAppResult> notifyDebtPaid(
    Subscriber subscriber, {
    required double amountPaid,
    required double remainingBalance,
    String? template,
  }) {
    return _notifyByType(
      type: WhatsAppNotificationType.debtPaid,
      subscriber: subscriber,
      template: template,
      amount: amountPaid,
      balance: remainingBalance,
    );
  }

  static Future<RenderSingleWhatsAppResult> notifyGeneralMessageToSubscriber(
    Subscriber subscriber, {
    required String message,
    String? template,
  }) {
    return _notifyByType(
      type: WhatsAppNotificationType.generalMessage,
      subscriber: subscriber,
      template: template,
      message: message,
    );
  }

  static Future<RenderSingleWhatsAppResult> notifyCustom(
    Subscriber subscriber, {
    required String template,
    Map<String, String>? extraVariables,
    String eventType = 'custom',
  }) async {
    final vars = _variablesForSubscriber(subscriber);
    if (extraVariables != null) {
      vars.addAll(extraVariables);
    }
    return _sendCore(
      to: subscriber.phone,
      message: applyTemplate(template, vars),
      eventType: eventType,
      note: 'custom-template',
    );
  }

  static Future<RenderSingleWhatsAppResult> sendSingleMessage({
    required String to,
    required String message,
  }) {
    return _sendCore(
      to: to,
      message: message,
      eventType: WhatsAppNotificationType.generalMessage.eventType,
    );
  }

  static Future<RenderWhatsAppResult> sendBroadcastMessage({
    required List<Subscriber> subscribers,
    required String template,
    String eventType = 'broadcast',
    String note = '',
  }) async {
    var sent = 0;
    var failed = 0;
    for (final s in subscribers) {
      final result = await _notifyByType(
        type: WhatsAppNotificationType.broadcast,
        subscriber: s,
        template: template,
      );
      if (result.success) {
        sent += 1;
      } else {
        failed += 1;
      }
    }

    return RenderWhatsAppResult(
      ok: failed == 0 && subscribers.isNotEmpty,
      total: subscribers.length,
      sent: sent,
      failed: failed,
      raw: {'eventType': eventType, 'note': note},
    );
  }

  static Future<RenderWhatsAppResult> sendCampaign(
    List<Map<String, String>> recipients, {
    String eventType = 'manual',
    String note = '',
  }) async {
    final filtered = recipients
        .where((row) => (row['phone'] ?? '').trim().isNotEmpty)
        .where((row) => (row['message'] ?? '').trim().isNotEmpty)
        .toList();

    if (filtered.isEmpty) {
      const result = RenderWhatsAppResult(ok: false, total: 0, sent: 0, failed: 0);
      await _appendLog(
        WhatsAppSendLog(
          at: DateTime.now(),
          eventType: eventType,
          total: 0,
          sent: 0,
          failed: 0,
          ok: false,
          note: note.isEmpty ? 'No valid recipients' : note,
        ),
      );
      return result;
    }

    var sent = 0;
    var failed = 0;
    for (final row in filtered) {
      final result = await _sendCore(
        to: row['phone'] ?? '',
        message: row['message'] ?? '',
        eventType: eventType,
        note: note,
      );
      if (result.success) {
        sent += 1;
      } else {
        failed += 1;
      }
    }

    return RenderWhatsAppResult(
      ok: failed == 0,
      total: filtered.length,
      sent: sent,
      failed: failed,
      raw: {'eventType': eventType, 'note': note},
    );
  }

  static void dispatchInBackground(Future<void> future) {
    unawaited(future);
  }
}
