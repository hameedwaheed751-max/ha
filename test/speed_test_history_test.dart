import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:untitled/services/speed_test_history.dart';

SpeedTestRecord _record(int minute, {double download = 48.24}) =>
    SpeedTestRecord(
      at: DateTime(2026, 11, 3, 21, minute),
      ping: 23.4,
      download: download,
      upload: 19.56,
      server: 'Speedtest.net',
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('keeps the last 10 results, newest first', () async {
    for (var minute = 0; minute < 12; minute++) {
      await SpeedTestHistory.add(_record(minute));
    }
    final history = await SpeedTestHistory.load();
    expect(history, hasLength(10));
    expect(history.first.at.minute, 11);
    expect(history.last.at.minute, 2);
  });

  test('unreadable saved data gives an empty history', () async {
    SharedPreferences.setMockInitialValues({'speed_test_history': 'not json'});
    expect(await SpeedTestHistory.load(), isEmpty);

    SharedPreferences.setMockInitialValues({
      'speed_test_history':
          '[{"at":1},{"at":1,"ping":2,"download":3,"upload":4}]',
    });
    final history = await SpeedTestHistory.load();
    expect(history, hasLength(1));
    expect(history.single.server, '');
  });

  test('the shared text lists every measurement', () {
    expect(
      _record(40).shareText,
      'نتيجة اختبار السرعة\n'
      '📅 03/11/2026 21:40\n'
      '⬇️ التحميل: 48.2 Mbps\n'
      '⬆️ الرفع: 19.6 Mbps\n'
      '📶 زمن الاستجابة: 23 ms\n'
      '🌐 الخادم: Speedtest.net',
    );
  });
}
