import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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
  static const String _defaultSendEndpoint = String.fromEnvironment(
    'SAS_WEB_PROXY_URL',
    defaultValue: 'https://ha-0cs7.onrender.com',
  );
  static const String _embeddedApiKey = String.fromEnvironment(
    'SAS_PROXY_TOKEN',
    defaultValue: '',
  );
  static const String _legacyEmbeddedApiKey = String.fromEnvironment(
  'PROXY_TOKEN',
    defaultValue: '',
  );
  static const String _metaApiBaseUrl = String.fromEnvironment(
    'META_WHATSAPP_API_URL',
    defaultValue: 'https://graph.facebook.com/v22.0',
  );
  static const String _metaPhoneNumberId = String.fromEnvironment(
    'META_WHATSAPP_PHONE_NUMBER_ID',
    defaultValue: '',
  );
  static const String _metaAccessToken = String.fromEnvironment(
    'META_WHATSAPP_ACCESS_TOKEN',
    defaultValue: '',
  );
  static const String _legacyMetaAccessToken = String.fromEnvironment(
    'META_ACCESS_TOKEN',
    defaultValue: '',
  );
  static const String _legacyMetaPhoneNumberId = String.fromEnvironment(
    'WHATSAPP_PHONE_NUMBER_ID',
    defaultValue: '',
  );
  static const int _maxAttempts = 3;

  static String _digitsOnly(String value) {
    return value.replaceAll(RegExp(r'[^0-9]'), '');
  }

  static String _withAgentPhoneFooter(String message) {
    final agentLabel = AppStore.effectiveAgentName.trim();
    final officePhone = AppStore.officePhone.trim();
    final footerParts = <String>[];
    if (agentLabel.isNotEmpty) footerParts.add(agentLabel);
    if (officePhone.isNotEmpty) footerParts.add(officePhone);

    if (footerParts.isEmpty) return message;

    final messageDigits = _digitsOnly(message);
    final officeDigits = _digitsOnly(officePhone);
    final normalizedOfficePhone = normalizePhone(officePhone);
    final alreadyContainsPhone =
        (officeDigits.isNotEmpty && messageDigits.contains(officeDigits)) ||
        (normalizedOfficePhone.isNotEmpty && messageDigits.contains(normalizedOfficePhone));
    final alreadyContainsAgent = agentLabel.isNotEmpty && message.contains(agentLabel);

    if (alreadyContainsPhone && alreadyContainsAgent) return message;

    final footer = footerParts.join(' • ');
    if (message.trim().isEmpty) return footer;
    return '$message\n🏢 $footer';
  }

  static String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  static String _templateForType(WhatsAppNotificationType type) {
    final map = AppStore.messageTemplates;
    switch (type) {
      case WhatsAppNotificationType.subscriptionRenewed:
        return map['extension'] ??
            'مرحباً {name}، تم تجديد اشتراكك بنجاح لدى {office} حتى {endDate}.';
      case WhatsAppNotificationType.subscriptionExpiresIn3Days:
        return map['nearExpiry'] ?? AppStore.nearExpiryTemplate;
      case WhatsAppNotificationType.subscriptionExpired:
        return map['expired'] ??
            'مرحباً {name}، اشتراكك لدى {office} منتهي. يرجى التجديد لاستمرار الخدمة.';
      case WhatsAppNotificationType.debtAdded:
        return AppStore.debtTemplate;
      case WhatsAppNotificationType.debtPaid:
        return map['debtPaid'] ??
            'مرحباً {{الاسم المشترك}}،\n✅ تم استلام مبلغ الدين المترتب بذمتكم.\n💰 المبلغ المسدد: {{المبلغ}} دينار عراقي\n📅 تاريخ التسديد: {{التاريخ}}\nنشكر لكم التزامكم بالسداد.\nللاستفسار يرجى التواصل مع:\n🏢 {{اسم الوكيل}}\n\nشكراً لاختياركم خدمتنا.';
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
    final resolvedAgent = (agentName ?? AppStore.effectiveAgentName).trim();

    return {
      'name': s.name,
      'customerName': s.name,
      'user': s.user,
      'office': AppStore.officeName,
      'package': resolvedPackage,
      'startDate': _fmt(s.startDate),
      'endDate': _fmt(expiryDate ?? s.endDate),
      'expiryDate': _fmt(expiryDate ?? s.endDate),
      'price': s.price.toStringAsFixed(0),
      'paid': s.paid.toStringAsFixed(0),
      'remaining': resolvedBalance,
      'balance': resolvedBalance,
      'amount': resolvedAmount,
      'agentName': resolvedAgent,
      'date': _fmt(DateTime.now()),
      'message': message ?? '',
    };
  }

  static String applyTemplate(String template, Map<String, String> variables) {
    var out = template;
    for (final entry in variables.entries) {
      out = out.replaceAll('{${entry.key}}', entry.value);
    }
    // دعم القوالب العربية بصيغة {{...}} مع إبقاء الصيغة القديمة {key}.
    out = out
        .replaceAll('{{الاسم المشترك}}', variables['name'] ?? '')
      .replaceAll('{{اسم المشترك}}', variables['name'] ?? '')
      .replaceAll('{{الباقة}}', variables['package'] ?? '')
      .replaceAll('{{اسم الباقة}}', variables['package'] ?? '')
      .replaceAll('{{تاريخ بداية الاشتراك}}', variables['startDate'] ?? '')
      .replaceAll('{{تاريخ البدء}}', variables['startDate'] ?? '')
      .replaceAll('{{تاريخ انتهاء الاشتراك}}', variables['endDate'] ?? '')
        .replaceAll('{{تاريخ الانتهاء}}', variables['endDate'] ?? '')
      .replaceAll('{{مبلغ الاشتراك}}', variables['price'] ?? '')
      .replaceAll('{{المبلغ}}', variables['amount'] ?? '')
      .replaceAll('{{التاريخ}}', variables['date'] ?? '')
      .replaceAll('{{الواصل}}', 'الواصل: ${variables['paid'] ?? ''}')
      .replaceAll('{{المتبقي}}', 'المتبقي: ${variables['remaining'] ?? ''}')
        .replaceAll('{{اسم الوكيل}}', (variables['agentName'] ?? variables['office'] ?? ''));
    return out;
  }

  static String _resolvePhoneNumberId() {
    return _metaPhoneNumberId.trim().isNotEmpty
        ? _metaPhoneNumberId.trim()
        : _legacyMetaPhoneNumberId.trim();
  }

  static String _resolveAccessToken() {
    return _metaAccessToken.trim().isNotEmpty
        ? _metaAccessToken.trim()
        : _legacyMetaAccessToken.trim();
  }

  static String _templateNameForType(WhatsAppNotificationType type) {
    switch (type) {
      case WhatsAppNotificationType.subscriptionRenewed:
        return 'activated';
      case WhatsAppNotificationType.subscriptionExpiresIn3Days:
        return 'expiring';
      case WhatsAppNotificationType.subscriptionExpired:
        return 'expiring';
      case WhatsAppNotificationType.debtAdded:
        return 'debt_added';
      case WhatsAppNotificationType.debtPaid:
        return 'debt_paid';
      case WhatsAppNotificationType.generalMessage:
      case WhatsAppNotificationType.broadcast:
        return 'activated';
    }
  }

  static List<String> _extractOrderedPlaceholders(String templateBody) {
    final matches = RegExp(r'\{\{\s*([^{}]+?)\s*\}\}|\{\s*([a-zA-Z][^{}]*?)\s*\}')
        .allMatches(templateBody);
    final ordered = <String>[];
    for (final match in matches) {
      final placeholder = (match.group(1) ?? match.group(2) ?? '').trim();
      if (placeholder.isNotEmpty) {
        ordered.add(placeholder);
      }
    }
    return ordered;
  }

  static String _normalizePlaceholderKey(String placeholder) {
    return placeholder
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
  }

  static String _valueForPlaceholder(
    String placeholder,
    Map<String, String> variables,
  ) {
    final key = _normalizePlaceholderKey(placeholder);
    const aliases = <String, List<String>>{
      'name': <String>[
        'name',
        'customername',
        'subscribername',
        'الاسم',
        'اسم',
        'الاسمالمشترك',
        'اسمالمشترك',
        'اسم_المشترك',
      ],
      'package': <String>[
        'package',
        'packagename',
        'الباقة',
        'اسمالباقة',
        'الباقه',
      ],
      'startDate': <String>[
        'startdate',
        'subscriptionstart',
        'تاريخالبدء',
        'تاريخالبدء',
        'بدءالاشتراك',
        'تاريخبدايةالاشتراك',
      ],
      'endDate': <String>[
        'enddate',
        'expirydate',
        'subscriptionend',
        'تاريخالانتهاء',
        'تاريخالانتهاءالاشتراك',
        'تاريخانتهاءالاشتراك',
        'انتهاءالاشتراك',
      ],
      'price': <String>[
        'price',
        'subscriptionamount',
        'مبلغالاشتراك',
        'سعرالاشتراك',
      ],
      'paid': <String>[
        'paid',
        'الواصل',
        'المبلغالواصل',
      ],
      'remaining': <String>[
        'remaining',
        'balance',
        'المتبقي',
        'المتبقى',
        'المبلغالمتبقي',
      ],
      'amount': <String>[
        'amount',
        'debtamount',
        'paymentamount',
        'المبلغ',
        'مبلغالدين',
        'قيمةالدين',
        'المبلغالمسدد',
      ],
      'date': <String>[
        'date',
        'paymentdate',
        'today',
        'التاريخ',
        'تاريخالتسديد',
        'تاريخالدفع',
      ],
      'agentName': <String>[
        'agentname',
        'office',
        'officename',
        'اسمالوكيل',
        'اسممكتب',
        'اسمالمكتب',
        'اسممكتبالاشتراكات',
      ],
      'message': <String>[
        'message',
        'الرسالة',
        'النص',
      ],
    };

    for (final entry in aliases.entries) {
      if (entry.value.contains(key)) {
        return (variables[entry.key] ?? '').trim();
      }
    }

    return (variables[placeholder] ?? '').trim();
  }

  static List<String> _bodyParametersForTemplate(
    String templateBody,
    Map<String, String> variables,
  ) {
    final placeholders = _extractOrderedPlaceholders(templateBody);
    if (placeholders.isEmpty) {
      final fallbackMessage = (variables['message'] ?? '').trim();
      return fallbackMessage.isEmpty ? const <String>[] : <String>[fallbackMessage];
    }

    return placeholders
        .map((placeholder) => _valueForPlaceholder(placeholder, variables))
        .toList();
  }

  static Map<String, dynamic> _buildMetaTemplatePayload({
    required String to,
    required String templateName,
    required String templateBody,
    required Map<String, String> variables,
  }) {
    final params = _bodyParametersForTemplate(templateBody, variables);

    debugPrint(
      'Render WhatsApp template parameters for $templateName: ${jsonEncode(params)}',
    );

    final components = <Map<String, dynamic>>[];
    if (params.isNotEmpty) {
      components.add({
        'type': 'body',
        'parameters': params
            .map((value) => <String, dynamic>{'type': 'text', 'text': value})
            .toList(),
      });
    }

    return {
      'messaging_product': 'whatsapp',
      'to': to,
      'type': 'template',
      'template': {
        'name': templateName,
        'language': {'code': 'ar'},
        if (components.isNotEmpty) 'components': components,
      },
    };
  }

  static List<String> _extractTemplateBodyTexts(Map<String, dynamic> payload) {
    final template = payload['template'];
    if (template is! Map) return const <String>[];
    final components = template['components'];
    if (components is! List) return const <String>[];

    for (final component in components) {
      if (component is! Map) continue;
      if ((component['type'] ?? '').toString() != 'body') continue;
      final parameters = component['parameters'];
      if (parameters is! List) return const <String>[];
      return parameters
          .whereType<Map>()
          .map((p) => (p['text'] ?? '').toString().trim())
          .where((v) => v.isNotEmpty)
          .toList();
    }

    return const <String>[];
  }

  static bool _shouldRetryTemplateWithoutParams(Map<String, dynamic> responseBody) {
    final encoded = jsonEncode(responseBody);
    return encoded.contains('132000') &&
        encoded.contains('expected number of params (0)');
  }

  static Map<String, dynamic> _withoutTemplateParams(Map<String, dynamic> payload) {
    final updated = Map<String, dynamic>.from(payload);

    if (updated.containsKey('parameters')) {
      updated['parameters'] = <String>[];
    }

    final template = updated['template'];
    if (template is Map) {
      final updatedTemplate = Map<String, dynamic>.from(
        Map<String, dynamic>.from(template.cast<Object?, Object?>()),
      );
      updatedTemplate.remove('components');
      updated['template'] = updatedTemplate;
    }

    return updated;
  }

  static Future<(String endpoint, String apiKey)> loadConfig() async {
    final phoneNumberId = _resolvePhoneNumberId();
    if (phoneNumberId.isEmpty) {
      final fallbackEndpoint = _defaultSendEndpoint.trim().endsWith('/send-message')
          ? _defaultSendEndpoint.trim()
          : '${_defaultSendEndpoint.trim().replaceAll(RegExp(r'/+$'), '')}/send-message';
      final fallbackToken = _embeddedApiKey.trim().isNotEmpty
          ? _embeddedApiKey.trim()
          : _legacyEmbeddedApiKey.trim();
      return (fallbackEndpoint, fallbackToken);
    }

    final baseUrl = _metaApiBaseUrl.trim().isNotEmpty
        ? _metaApiBaseUrl.trim()
        : 'https://graph.facebook.com/v22.0';
    final endpoint = '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/$phoneNumberId/messages';
    final token = _resolveAccessToken();
    return (endpoint, token);
  }

  static Future<String> loadSendMessageEndpoint() async {
    final config = await loadConfig();
    return config.$1;
  }

  static String _buildProxySendMessageEndpoint() {
    final endpoint = _defaultSendEndpoint.trim();
    if (endpoint.endsWith('/send-message')) return endpoint;
    return '${endpoint.replaceAll(RegExp(r'/+$'), '')}/send-message';
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
    String? templateName,
    Map<String, dynamic>? payloadOverride,
    bool forcePlainText = false,
  }) async {
    final normalizedPhone = normalizePhone(to);
    final cleanMessage = _withAgentPhoneFooter(message.trim());
    if (normalizedPhone.isEmpty || cleanMessage.isEmpty) {
      return const RenderSingleWhatsAppResult(
        success: false,
        error: 'Both "to" and "message" are required',
      );
    }

    final endpoint = forcePlainText
      ? _buildProxySendMessageEndpoint()
      : await loadSendMessageEndpoint();
    final config = await loadConfig();
    final apiKey = config.$2;
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    final usesMetaTemplate = !forcePlainText &&
      endpoint.contains('graph.facebook.com') &&
        _resolvePhoneNumberId().isNotEmpty &&
        apiKey.isNotEmpty;

    if (apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer $apiKey';
      if (!usesMetaTemplate) {
        headers['x-api-key'] = apiKey;
        headers['x-proxy-token'] = apiKey;
      }
    }

    if (endpoint.isEmpty) {
      return const RenderSingleWhatsAppResult(
        success: false,
        error: 'Missing Meta WhatsApp configuration. Set META_WHATSAPP_PHONE_NUMBER_ID and META_WHATSAPP_ACCESS_TOKEN.',
      );
    }

    final payload = (forcePlainText)
      ? <String, dynamic>{
        'to': normalizedPhone,
        'message': cleanMessage,
        }
      : usesMetaTemplate
        ? (payloadOverride ?? <String, dynamic>{
            'messaging_product': 'whatsapp',
            'to': normalizedPhone,
            'type': 'template',
            'template': {
              'name': templateName ?? 'activated',
              'language': {'code': 'ar'},
              'components': [
                {
                  'type': 'body',
                  'parameters': [
                    {'type': 'text', 'text': cleanMessage},
                  ],
                },
              ],
            },
          })
        : () {
            if (payloadOverride != null) {
              final templateMap = payloadOverride['template'];
              final templateNameValue =
                  templateMap is Map ? (templateMap['name'] ?? '').toString().trim() : '';
              final languageCode = templateMap is Map
                  ? ((templateMap['language'] is Map
                          ? (templateMap['language'] as Map)['code']
                          : null) ??
                      'ar')
                      .toString()
                      .trim()
                  : 'ar';
              final params = _extractTemplateBodyTexts(payloadOverride);
              if (templateNameValue.isNotEmpty) {
                return <String, dynamic>{
                  'to': normalizedPhone,
                  'message': cleanMessage,
                  'templateName': templateNameValue,
                  'language': languageCode.isEmpty ? 'ar' : languageCode,
                  'parameters': params,
                };
              }
            }

            return <String, dynamic>{
              'to': normalizedPhone,
              'message': cleanMessage,
            };
          }();

    RenderSingleWhatsAppResult? lastFailure;
    var currentPayload = Map<String, dynamic>.from(payload);
    var retriedWithoutParams = false;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        debugPrint('Render WhatsApp request body:\n${const JsonEncoder.withIndent('  ').convert(currentPayload)}');
        final response = await http
            .post(
              Uri.parse(endpoint),
              headers: headers,
              body: jsonEncode(currentPayload),
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

        debugPrint('Render WhatsApp response body:\n${response.body.isEmpty ? '<empty>' : response.body}');
        final successByStatus = response.statusCode >= 200 && response.statusCode < 300;
        final success = successByStatus && (data['success'] != false);

        await _appendAttemptLog(
          eventType: eventType,
          to: normalizedPhone,
          attempt: attempt,
          ok: success,
          note: success ? (note.isEmpty ? 'Delivered' : note) : 'HTTP ${response.statusCode}',
          endpoint: endpoint,
          requestBody: currentPayload,
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

        final errorMessage = (data['error'] ?? 'HTTP ${response.statusCode}').toString();
        if (data.isNotEmpty) {
          debugPrint('Render WhatsApp Meta error JSON:\n${const JsonEncoder.withIndent('  ').convert(data)}');
        } else {
          debugPrint('Render WhatsApp Meta error body:\n${response.body}');
        }

        lastFailure = RenderSingleWhatsAppResult(
          success: false,
          error: errorMessage,
          details: data.isNotEmpty ? data : {'raw': response.body},
          statusCode: response.statusCode,
        );

        final shouldRetryWithoutParams =
            !retriedWithoutParams && _shouldRetryTemplateWithoutParams(lastFailure.details ?? const <String, dynamic>{});
        if (shouldRetryWithoutParams) {
          retriedWithoutParams = true;
          currentPayload = _withoutTemplateParams(currentPayload);
          debugPrint(
            'Render WhatsApp retrying template without parameters after 132000 mismatch.',
          );
          continue;
        }
      } catch (e) {
        await _appendAttemptLog(
          eventType: eventType,
          to: normalizedPhone,
          attempt: attempt,
          ok: false,
          note: 'Transport error',
          endpoint: endpoint,
          requestBody: currentPayload,
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
    final templateName = _templateNameForType(type);
    final payload = _buildMetaTemplatePayload(
      to: phone,
      templateName: templateName,
      templateBody: tmpl,
      variables: vars,
    );
    return _sendCore(
      to: phone,
      message: rendered,
      eventType: type.eventType,
      note: type.eventType,
      templateName: templateName,
      payloadOverride: payload,
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
  }) async {
    final phone = normalizePhone(subscriber.phone);
    if (phone.isEmpty) {
      return const RenderSingleWhatsAppResult(
        success: false,
        error: 'Subscriber has no valid phone number',
      );
    }

    final tmpl = (template ?? '{message}').trim();
    final vars = _variablesForSubscriber(subscriber, message: message);
    final rendered = applyTemplate(tmpl, vars).trim();

    return _sendCore(
      to: phone,
      message: rendered,
      eventType: WhatsAppNotificationType.generalMessage.eventType,
      note: WhatsAppNotificationType.generalMessage.eventType,
      forcePlainText: true,
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
      forcePlainText: true,
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
      forcePlainText: true,
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
      final vars = _variablesForSubscriber(s);
      final rendered = applyTemplate(template, vars).trim();
      final result = await _sendCore(
        to: s.phone,
        message: rendered,
        eventType: WhatsAppNotificationType.broadcast.eventType,
        note: WhatsAppNotificationType.broadcast.eventType,
        forcePlainText: true,
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
        forcePlainText: true,
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
