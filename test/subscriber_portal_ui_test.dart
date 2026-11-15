import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:untitled/screens/subscriber_portal_invite.dart';
import 'package:untitled/screens/subscriber_portal_requests_screen.dart';
import 'package:untitled/services/subscriber_portal_service.dart';

void main() {
  test('invite message carries the code and the office, nothing else private', () {
    final text = portalInviteMessage(
      subscriberName: ' علي ',
      officeName: 'مكتب النور',
      code: 'ABCD-EFGH',
    );
    expect(text, contains('ABCD-EFGH'));
    expect(text, contains('مكتب النور'));
    expect(text, contains('48 ساعة'));
    expect(portalInviteMessage(subscriberName: 'x', officeName: ' ', code: 'C'), contains('مكتبنا'));
  });

  test('WhatsApp numbers are normalised to the 964 form', () {
    expect(whatsappNumber('0770 123 4567'), '9647701234567');
    expect(whatsappNumber('+964 770 123 4567'), '9647701234567');
    expect(whatsappNumber('009647701234567'), '9647701234567');
    expect(whatsappNumber('7701234567'), '9647701234567');
    expect(whatsappNumber('123'), isNull);
  });

  testWidgets('the requests screen approves a pending request and shows the result', (tester) async {
    var status = 'pending';
    final posted = <String>[];
    final client = SubscriberPortalClient(
      gatewayUrl: 'https://gw.test',
      getIdToken: () async => 'token',
      client: MockClient((r) async {
        Object? data;
        if (r.url.path.endsWith('/portal-settings')) {
          data = {'show_debt': false};
        } else if (r.method == 'POST') {
          posted.add('${r.url.path} ${r.body}');
          status = 'approved';
          data = {'id': 'r1', 'status': status};
        } else {
          data = [
            {
              'id': 'r1',
              'number': 'R-1001',
              'subscriber_id': 's1',
              'subscriber_name': 'علي حسن',
              'package_name': 'Fiber 50',
              'quoted_price': 35000,
              'status': status,
              'created_at': '2026-11-20T00:00:00Z',
            },
          ];
        }
        return http.Response.bytes(utf8.encode(jsonEncode({'success': true, 'data': data})), 200);
      }),
    );
    await tester.pumpWidget(MaterialApp(home: SubscriberPortalRequestsScreen(client: client)));
    await tester.pumpAndSettle();
    expect(find.text('علي حسن'), findsOneWidget);
    expect(find.text('بانتظار ردّك'), findsOneWidget);
    await tester.tap(find.text('قبول'));
    await tester.pumpAndSettle();
    expect(posted.single, contains('"decision":"approve"'));
    expect(find.text('مقبول — بانتظار التفعيل'), findsOneWidget);
    expect(find.text('قبول'), findsNothing);
    expect(find.text('تعذّر التنفيذ'), findsOneWidget);
  });

  testWidgets('a switched-off service shows a clear message, not a crash', (tester) async {
    final client = SubscriberPortalClient(
      gatewayUrl: 'https://gw.test',
      getIdToken: () async => 'token',
      client: MockClient((_) async => http.Response('Cannot GET', 404)),
    );
    await tester.pumpWidget(MaterialApp(home: SubscriberPortalRequestsScreen(client: client)));
    await tester.pumpAndSettle();
    expect(find.text('خدمة مشترك نت غير مفعّلة بعد'), findsOneWidget);
  });
}
