import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/speed_test_history.dart';

/// Lets the agent send a result over WhatsApp or copy it.
Future<void> shareSpeedTestResult(
  BuildContext context,
  SpeedTestRecord record,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.chat_rounded),
              title: const Text('إرسال عبر واتساب'),
              onTap: () => Navigator.pop(sheetContext, 'whatsapp'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('نسخ النتيجة'),
              onTap: () => Navigator.pop(sheetContext, 'copy'),
            ),
          ],
        ),
      ),
    ),
  );
  if (choice == 'whatsapp') {
    final uri = Uri.https('wa.me', '/', {'text': record.shareText});
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      messenger.showSnackBar(
        const SnackBar(content: Text('تعذر فتح واتساب على هذا الجهاز')),
      );
    }
  } else if (choice == 'copy') {
    await Clipboard.setData(ClipboardData(text: record.shareText));
    messenger.showSnackBar(
      const SnackBar(content: Text('تم نسخ نتيجة الاختبار')),
    );
  }
}

/// The last speed tests on this device, newest first.
class SpeedTestHistoryPanel extends StatelessWidget {
  const SpeedTestHistoryPanel({super.key, required this.records});

  final List<SpeedTestRecord> records;

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0C1428),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF263451)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'آخر الاختبارات على هذا الجهاز',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          for (final record in records)
            InkWell(
              onTap: () => shareSpeedTestResult(context, record),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        record.dateLabel,
                        textDirection: TextDirection.ltr,
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          color: Color(0xFF9BA8C2),
                          fontSize: 12,
                        ),
                      ),
                    ),
                    _value('⬇', record.download, 'Mbps', 0xFFFFAA00),
                    _value('⬆', record.upload, 'Mbps', 0xFF26D8F6),
                    _value('', record.ping, 'ms', 0xFFFF3D6E, digits: 0),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _value(
    String arrow,
    double value,
    String unit,
    int color, {
    int digits = 1,
  }) {
    return SizedBox(
      width: 78,
      child: Text(
        '$arrow ${value.toStringAsFixed(digits)} $unit'.trim(),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Color(color),
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
