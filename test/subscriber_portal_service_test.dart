import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:untitled/models.dart';
import 'package:untitled/services/subscriber_portal_service.dart';

Subscriber _subscriber({
  String id = '11111111-1111-4111-8111-111111111111',
  DateTime? end,
  double price = 35000,
  double paid = 20000,
}) => Subscriber(
  subscriberId: id,
  user: 'ali.sas',
  name: 'علي',
  phone: '07701234567',
  address: 'عنوان خاص',
  ip: '10.0.0.5',
  type: 'Fiber 50',
  price: price,
  startDate: DateTime(2026, 11, 1),
  endDate: end ?? DateTime(2026, 12, 1),
  notes: 'ملاحظة داخلية',
  paid: paid,
  carriedDebt: 5000,
  sasData: {'password': 'secret'},
  payments: [PaymentRecord(amount: 20000, at: DateTime(2026, 11, 2))],
);

PortalRenewal _renewal({String status = 'approved', DateTime? previousEnd}) =>
    PortalRenewal(
      id: 'r1',
      number: 'R-1001',
      subscriberId: '11111111-1111-4111-8111-111111111111',
      subscriberName: 'علي',
      packageName: 'Fiber 50',
      quotedPrice: 35000,
      status: status,
      createdAt: DateTime(2026, 11, 20),
      previousEndDate: previousEnd ?? DateTime(2026, 12, 1),
    );

SubscriberPortalClient _client(
  Future<http.Response> Function(http.Request) handler,
) => SubscriberPortalClient(
  gatewayUrl: 'https://gw.test/',
  getIdToken: () async => 'token',
  client: MockClient(handler),
);

http.Response _ok(Object? data) =>
    http.Response(jsonEncode({'success': true, 'data': data}), 200);

void main() {
  test('the summary carries no SAS username, notes, address or raw SAS data', () {
    final summary = buildPortalSummary(_subscriber(), lastSasSync: DateTime(2026, 11, 15));
    final text = jsonEncode(summary);
    for (final secret in ['ali.sas', 'ملاحظة داخلية', 'عنوان خاص', '10.0.0.5', 'secret', '0770']) {
      expect(text.contains(secret), isFalse, reason: secret);
    }
    final finance = summary['finance'] as Map;
    // المتبقي = الدين المرحّل + (السعر − المدفوع) كما يراه الوكيل.
    expect(finance['balance_due'], 20000);
    expect(finance['total_paid'], 20000);
    expect(finance['total_charges'], 40000);
    final entry = (finance['entries'] as List).single as Map;
    expect(entry['amount'], -20000);
    expect(entry['type'], 'payment');
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch('${entry['id']}'), isTrue);
  });

  test('connection is unknown until SAS has been synced', () {
    expect(buildPortalSummary(_subscriber())['connection'], 'unknown');
  });

  test('a renewal counts as done only when the end date moved past the one at request time', () {
    final s = _subscriber(end: DateTime(2027, 1, 1));
    final byId = {s.subscriberId: s};
    expect(renewalsToComplete([_renewal()], byId).single.$2, DateTime(2027, 1, 1));
    expect(renewalsToComplete([_renewal(status: 'pending')], byId), hasLength(1));
    expect(renewalsToComplete([_renewal(status: 'rejected')], byId), isEmpty);
    expect(
      renewalsToComplete([_renewal(previousEnd: DateTime(2027, 1, 1))], byId),
      isEmpty,
    );
    final unchanged = _subscriber();
    expect(renewalsToComplete([_renewal()], {unchanged.subscriberId: unchanged}), isEmpty);
  });

  test('a 404 without the JSON envelope means the service is switched off', () async {
    final client = _client((_) async => http.Response('Cannot GET', 404));
    await expectLater(
      client.renewals(),
      throwsA(isA<PortalException>().having((e) => e.code, 'code', 'portal_disabled')),
    );
  });

  test('server error codes come through, and requests carry the agent token', () async {
    late http.Request seen;
    final client = _client((r) async {
      seen = r;
      return http.Response(jsonEncode({'success': false, 'error': 'phone_missing'}), 422);
    });
    await expectLater(
      client.createInvitation('abc'),
      throwsA(isA<PortalException>().having((e) => e.code, 'code', 'phone_missing')),
    );
    expect(seen.url.toString(), 'https://gw.test/api/v1/agent/subscriber-invitations');
    expect(seen.headers['Authorization'], 'Bearer token');
    expect(jsonDecode(seen.body), {'subscriber_id': 'abc'});
  });

  test('sync publishes changed summaries once and completes executed renewals', () async {
    final s = _subscriber(end: DateTime(2027, 1, 1));
    final calls = <String>[];
    final client = _client((r) async {
      calls.add('${r.method} ${r.url.path}');
      if (r.url.path.endsWith('/subscriber-links')) {
        return _ok([{'subscriber_id': s.subscriberId}]);
      }
      if (r.url.path.endsWith('/renewal-requests') && r.method == 'GET') {
        return _ok([
          {'id': 'r1', 'status': 'approved', 'subscriber_id': s.subscriberId,
           'previous_end_date': '2026-12-01T00:00:00.000', 'created_at': '2026-11-20T00:00:00Z'},
          {'id': 'r2', 'status': 'pending', 'subscriber_id': 'other',
           'previous_end_date': '2026-12-01T00:00:00.000', 'created_at': '2026-11-20T00:00:00Z'},
        ]);
      }
      if (r.url.path.endsWith('/support-tickets')) {
        return _ok([
          {'id': 't1', 'status': 'open', 'messages': []},
        ]);
      }
      if (r.url.path.endsWith('/result')) {
        expect(jsonDecode(r.body)['result'], 'completed');
        return _ok({'id': 'r1', 'status': 'completed'});
      }
      return _ok({'updated_at': 'x'});
    });
    final sync = SubscriberPortalSync(
      client: client,
      subscribers: () => [s],
      lastSasSync: () => null,
      isEnabled: () async => true,
    );
    await sync.run();
    expect(calls.where((c) => c.startsWith('PUT')), hasLength(1));
    expect(calls.where((c) => c.endsWith('/r1/result')), hasLength(1));
    // طلب تجديد بانتظار الرد + تذكرة بانتظار الرد.
    expect(sync.openRequests.value, 2);
    await sync.run();
    expect(calls.where((c) => c.startsWith('PUT')), hasLength(1));
    s.name = 'علي حسن';
    await sync.run();
    expect(calls.where((c) => c.startsWith('PUT')), hasLength(2));
  });

  test('sync does nothing for non-pilot accounts and pauses when the service is off', () async {
    var hits = 0;
    final off = _client((_) async {
      hits++;
      return http.Response('Cannot GET', 404);
    });
    final notPilot = SubscriberPortalSync(
      client: off,
      subscribers: () => [],
      lastSasSync: () => null,
      isEnabled: () async => false,
    );
    await notPilot.run();
    expect(hits, 0);
    final pilot = SubscriberPortalSync(
      client: off,
      subscribers: () => [],
      lastSasSync: () => null,
      isEnabled: () async => true,
    );
    await pilot.run();
    await pilot.run();
    expect(hits, 1);
  });
}
