import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/screens/ping_view.dart';
import 'package:untitled/services/speed_test_history.dart';
import 'package:untitled/widgets/speed_test_extras.dart';

// A small phone, where the new rows are tightest.
Future<void> _pumpOnPhone(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: child));
  await tester.pump();
}

void main() {
  testWidgets('speed test history fits a small phone', (tester) async {
    final records = [
      for (var minute = 0; minute < 10; minute++)
        SpeedTestRecord(
          at: DateTime(2026, 11, 4, 21, minute),
          ping: 123,
          download: 945.7,
          upload: 512.3,
          server: 'Cloudflare - Baghdad - IQ',
        ),
    ];
    await _pumpOnPhone(
      tester,
      Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SpeedTestHistoryPanel(records: records),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('آخر الاختبارات على هذا الجهاز'), findsOneWidget);
  });

  testWidgets('ping view fits a small phone with results', (tester) async {
    final controller = TextEditingController(text: 'google.com');
    addTearDown(controller.dispose);
    await _pumpOnPhone(
      tester,
      PingView(
        controller: controller,
        testing: true,
        attempts: [
          for (var index = 1; index <= 5; index++)
            PingAttempt(
              sequence: index,
              address: '142.250.185.238',
              details: '64 bytes  TTL=117',
              duration: const Duration(microseconds: 123456),
            ),
          const PingAttempt(sequence: 6, error: 'انتهت مهلة الطلب'),
        ],
        sent: 6,
        received: 5,
        error: null,
        onRun: () {},
        onStop: () {},
        quickTargets: pingQuickTargets('sas.example-isp.iq'),
        onQuickTarget: (_) {},
        idleHint: 'أدخل IP',
        note:
            'في المتصفح يُقاس زمن الاستجابة عبر HTTPS لأن المتصفح لا يسمح بـ '
            'ICMP، فقد يكون أعلى قليلاً من Ping التطبيق.',
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('التذبذب ms'), findsOneWidget);
    expect(find.text('خادم SAS'), findsOneWidget);
  });
}
