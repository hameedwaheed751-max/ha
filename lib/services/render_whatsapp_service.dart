import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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

class WhatsAppSendLog {
  const WhatsAppSendLog({
    required this.at,
    required this.eventType,
    required this.total,
    required this.sent,
    required this.failed,
    required this.ok,
    this.note = '',
  });

  final DateTime at;
  final String eventType;
  final int total;
  final int sent;
  final int failed;
  final bool ok;
  final String note;

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'eventType': eventType,
        'total': total,
        'sent': sent,
        'failed': failed,
        'ok': ok,
        'note': note,
      };

  factory WhatsAppSendLog.fromJson(Map<String, dynamic> j) => WhatsAppSendLog(
        at: DateTime.tryParse((j['at'] ?? '').toString()) ?? DateTime.now(),
        eventType: (j['eventType'] ?? 'unknown').toString(),
        total: (j['total'] as num?)?.toInt() ?? 0,
        sent: (j['sent'] as num?)?.toInt() ?? 0,
        failed: (j['failed'] as num?)?.toInt() ?? 0,
        ok: j['ok'] == true,
        note: (j['note'] ?? '').toString(),
      );
}

class RenderWhatsAppService {
  static const String endpointKey = 'render_whatsapp_endpoint';
  static const String apiKeyKey = 'render_whatsapp_api_key';
  static const String logsKey = 'render_whatsapp_send_logs';
  static const int maxLogs = 200;

  static Future<(String endpoint, String apiKey)> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final endpoint = (prefs.getString(endpointKey) ?? '').trim();
    final apiKey = (prefs.getString(apiKeyKey) ?? '').trim();
    return (endpoint, apiKey);
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

  static Future<void> clearLogs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(logsKey);
  }

  static Future<RenderWhatsAppResult> sendCampaign(
    List<Map<String, String>> recipients,
    {
      String eventType = 'manual',
      String note = '',
    }
  ) async {
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

    final config = await loadConfig();
    final endpoint = config.$1;
    final apiKey = config.$2;

    if (endpoint.isEmpty) {
      final result = RenderWhatsAppResult(
        ok: false,
        total: filtered.length,
        sent: 0,
        failed: filtered.length,
        raw: const {'error': 'Render endpoint is not configured'},
      );
      await _appendLog(
        WhatsAppSendLog(
          at: DateTime.now(),
          eventType: eventType,
          total: filtered.length,
          sent: 0,
          failed: filtered.length,
          ok: false,
          note: note.isEmpty ? 'Render endpoint not configured' : note,
        ),
      );
      return result;
    }

    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer $apiKey';
      headers['x-api-key'] = apiKey;
    }

    final response = await http.post(
      Uri.parse(endpoint),
      headers: headers,
      body: jsonEncode({'recipients': filtered}),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final result = RenderWhatsAppResult(
        ok: false,
        total: filtered.length,
        sent: 0,
        failed: filtered.length,
        raw: {'status': response.statusCode, 'body': response.body},
      );
      await _appendLog(
        WhatsAppSendLog(
          at: DateTime.now(),
          eventType: eventType,
          total: filtered.length,
          sent: 0,
          failed: filtered.length,
          ok: false,
          note: note.isEmpty ? 'HTTP ${response.statusCode}' : note,
        ),
      );
      return result;
    }

    try {
      final decoded = jsonDecode(response.body);
      final data = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      final result = RenderWhatsAppResult(
        ok: data['ok'] == true,
        total: (data['total'] as num?)?.toInt() ?? filtered.length,
        sent: (data['sent'] as num?)?.toInt() ?? 0,
        failed: (data['failed'] as num?)?.toInt() ?? 0,
        raw: data,
      );
      await _appendLog(
        WhatsAppSendLog(
          at: DateTime.now(),
          eventType: eventType,
          total: result.total,
          sent: result.sent,
          failed: result.failed,
          ok: result.ok,
          note: note,
        ),
      );
      return result;
    } catch (_) {
      final result = RenderWhatsAppResult(
        ok: false,
        total: filtered.length,
        sent: 0,
        failed: filtered.length,
        raw: {'body': response.body},
      );
      await _appendLog(
        WhatsAppSendLog(
          at: DateTime.now(),
          eventType: eventType,
          total: filtered.length,
          sent: 0,
          failed: filtered.length,
          ok: false,
          note: note.isEmpty ? 'Invalid JSON response from Render' : note,
        ),
      );
      return result;
    }
  }
}
