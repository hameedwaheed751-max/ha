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

  test('an already-linked record is unlinked and re-invited only after the agent confirms', () async {
    final calls = <String>[];
    var linked = true;
    final client = SubscriberPortalClient(
      gatewayUrl: 'https://gw.test',
      getIdToken: () async => 'token',
      client: MockClient((r) async {
        calls.add('${r.method} ${r.url.path}');
        if (r.method == 'DELETE') {
          linked = false;
          return http.Response(jsonEncode({'success': true, 'data': null}), 200);
        }
        if (linked) {
          return http.Response(
            jsonEncode({'success': false, 'error': 'record_already_linked'}),
            409,
          );
        }
        return http.Response(
          jsonEncode({
            'success': true,
            'data': {
              'id': 'i1',
              'code': 'ABCD2345',
              'masked_phone': '67',
              'expires_at': '2026-11-17T10:00:00Z',
            },
          }),
          200,
        );
      }),
    );
    final refused = await inviteWithRelink(client, 's1', confirmRelink: () async => false);
    expect(refused, isNull);
    expect(calls.where((c) => c.startsWith('DELETE')), isEmpty);
    final invitation = await inviteWithRelink(client, 's1', confirmRelink: () async => true);
    expect(invitation?.code, 'ABCD2345');
    expect(calls, contains('DELETE /api/v1/agent/subscriber-links/s1'));
  });

  test('cancelling the link asks first, and an unlinked subscriber gets a clear message', () async {
    final calls = <String>[];
    var linked = true;
    final client = SubscriberPortalClient(
      gatewayUrl: 'https://gw.test',
      getIdToken: () async => 'token',
      client: MockClient((r) async {
        calls.add('${r.method} ${r.url.path}');
        if (!linked) {
          return http.Response(jsonEncode({'success': false, 'error': 'not_linked'}), 404);
        }
        linked = false;
        return http.Response(jsonEncode({'success': true, 'data': null}), 200);
      }),
    );
    expect(await unlinkFromPortal(client, 's1', confirm: () async => false), isFalse);
    expect(calls, isEmpty);
    expect(await unlinkFromPortal(client, 's1', confirm: () async => true), isTrue);
    expect(calls, ['DELETE /api/v1/agent/subscriber-links/s1']);
    await expectLater(
      unlinkFromPortal(client, 's1', confirm: () async => true),
      throwsA(isA<PortalException>().having((e) => e.message, 'message', 'المشترك غير مربوط بتطبيق مشترك نت')),
    );
  });

  testWidgets('the support tab lists tickets, opens one, and sends the agent reply', (tester) async {
    final posted = <String>[];
    var status = 'open';
    final messages = <Map<String, Object>>[
      {'from_subscriber': true, 'author': 'علي حسن', 'text': 'الإنترنت ينقطع مساءً', 'at': '2026-11-20T18:00:00Z'},
    ];
    Map<String, Object> ticket() => {
      'id': 't1',
      'number': 'T-101',
      'subscriber_id': 's1',
      'subscriber_name': 'علي حسن',
      'category': 'connection',
      'status': status,
      'created_at': '2026-11-20T18:00:00Z',
      'updated_at': '2026-11-20T18:00:00Z',
      'messages': messages,
    };
    final client = SubscriberPortalClient(
      gatewayUrl: 'https://gw.test',
      getIdToken: () async => 'token',
      client: MockClient((r) async {
        Object? data;
        if (r.url.path.endsWith('/portal-settings')) {
          data = {'show_debt': false};
        } else if (r.url.path.endsWith('/renewal-requests')) {
          data = [];
        } else if (r.method == 'POST' && r.url.path.endsWith('/messages')) {
          posted.add(r.body);
          messages.add({'from_subscriber': false, 'author': 'مكتب', 'text': 'سنفحص الخط', 'at': '2026-11-20T19:00:00Z'});
          status = 'answered';
          data = ticket();
        } else if (r.url.path.endsWith('/support-tickets')) {
          data = [ticket()];
        }
        return http.Response.bytes(utf8.encode(jsonEncode({'success': true, 'data': data})), 200);
      }),
    );
    await tester.pumpWidget(MaterialApp(home: SubscriberPortalRequestsScreen(client: client)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('الدعم'));
    await tester.pumpAndSettle();
    expect(find.text('علي حسن'), findsOneWidget);
    expect(find.text('بانتظار ردّك'), findsOneWidget);
    await tester.tap(find.text('علي حسن'));
    await tester.pumpAndSettle();
    expect(find.text('الإنترنت ينقطع مساءً'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'سنفحص الخط');
    await tester.tap(find.byTooltip('إرسال'));
    await tester.pumpAndSettle();
    expect(posted.single, '{"text":"سنفحص الخط"}');
    expect(find.text('سنفحص الخط'), findsOneWidget);
  });

  test('tickets parse with labels the agent understands', () {
    final t = PortalTicket.fromJson({
      'id': 't1',
      'number': 'T-101',
      'subscriber_id': 's1',
      'subscriber_name': 'علي',
      'category': 'billing',
      'status': 'answered',
      'created_at': '2026-11-20T18:00:00Z',
      'updated_at': '2026-11-20T19:00:00Z',
      'messages': [
        {'from_subscriber': true, 'author': 'علي', 'text': 'سؤال', 'at': '2026-11-20T18:00:00Z'},
      ],
    });
    expect(t.categoryLabel, 'المحاسبة');
    expect(t.statusLabel, 'تم الرد');
    expect(t.awaitingAgent, isFalse);
    expect(t.messages.single.fromSubscriber, isTrue);
  });
}
