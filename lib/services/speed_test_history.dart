import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One finished speed test, kept on this device only.
class SpeedTestRecord {
  const SpeedTestRecord({
    required this.at,
    required this.ping,
    required this.download,
    required this.upload,
    required this.server,
  });

  final DateTime at;
  final double ping;
  final double download;
  final double upload;
  final String server;

  Map<String, Object> toJson() => {
    'at': at.millisecondsSinceEpoch,
    'ping': ping,
    'download': download,
    'upload': upload,
    'server': server,
  };

  static SpeedTestRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = json['at'];
    final ping = json['ping'];
    final download = json['download'];
    final upload = json['upload'];
    if (at is! int || ping is! num || download is! num || upload is! num) {
      return null;
    }
    return SpeedTestRecord(
      at: DateTime.fromMillisecondsSinceEpoch(at),
      ping: ping.toDouble(),
      download: download.toDouble(),
      upload: upload.toDouble(),
      server: json['server'] is String ? json['server'] as String : '',
    );
  }

  String get dateLabel {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(at.day)}/${two(at.month)}/${at.year} '
        '${two(at.hour)}:${two(at.minute)}';
  }

  String get shareText => [
    'نتيجة اختبار السرعة',
    '📅 $dateLabel',
    '⬇️ التحميل: ${download.toStringAsFixed(1)} Mbps',
    '⬆️ الرفع: ${upload.toStringAsFixed(1)} Mbps',
    '📶 زمن الاستجابة: ${ping.toStringAsFixed(0)} ms',
    if (server.isNotEmpty) '🌐 الخادم: $server',
  ].join('\n');
}

/// The last [limit] speed tests on this device, newest first.
class SpeedTestHistory {
  static const _key = 'speed_test_history';
  static const limit = 10;

  static Future<List<SpeedTestRecord>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map(SpeedTestRecord.fromJson)
          .whereType<SpeedTestRecord>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Saves [record] and returns the updated history.
  static Future<List<SpeedTestRecord>> add(SpeedTestRecord record) async {
    final records = [record, ...await load()].take(limit).toList();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode(records.map((item) => item.toJson()).toList()),
      );
    } catch (_) {}
    return records;
  }
}
