import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/screens/agents_broadcast_screen.dart';
import 'package:untitled/services/subscription_request_service.dart';

SubscriptionRequestModel _request(
  String id, {
  String uid = '',
  String phone = '07701234567',
  String status = 'approved',
  String first = 'علي',
  int createdAt = 1000,
  String? deletedAt,
}) => SubscriptionRequestModel.fromMap({
  'requestId': id,
  'uid': uid,
  'firstName': first,
  'lastName': '',
  'phone': phone,
  'email': '$id@x.com',
  'selectedPlan': 'one_year',
  'amount': '1',
  'paymentMethod': 'Qi Card',
  'status': status,
  'createdAt': createdAt,
  'deletedAt': ?deletedAt,
});

void main() {
  final now = DateTime.utc(2026, 11, 9, 10);

  test('deleting keeps every request as a rejected card without receipts', () {
    final updates = SubscriptionRequestService.deletionUpdates(
      uid: 'u1',
      profile: {'sasUsername': 'old'},
      sas: {'username': 'mgr', 'serverUrl': 'https://www.sas.example.com/x'},
      requests: {
        'admin/subscriptionRequests/r1': {'receiptImageUrl': 'http://img'},
      },
      now: now,
    );
    expect(updates['agents/u1'], isNull);
    expect(updates.containsKey('agents/u1'), isTrue);
    expect(updates.containsKey('agents/u1_old'), isTrue);
    expect(updates.containsKey('admin/subscriptionRequests/r1'), isFalse);
    const r = 'admin/subscriptionRequests/r1';
    expect(updates['$r/status'], 'rejected');
    expect(updates['$r/deletedAt'], now.toIso8601String());
    expect(updates['$r/deletedSas'], 'mgr @ sas.example.com');
    expect(updates.containsKey('$r/receiptImageUrl'), isTrue);
    expect(updates['$r/receiptImageUrl'], isNull);
  });

  test('an agent with no request still leaves a rejected card', () {
    final updates = SubscriptionRequestService.deletionUpdates(
      uid: 'u2',
      profile: {'name': 'حسن', 'email': 'h@x.com', 'phone': '0780'},
      sas: const {},
      requests: const {},
      now: now,
    );
    final card =
        updates['admin/subscriptionRequests/deleted_u2']
            as Map<String, Object?>;
    expect(card['status'], 'rejected');
    expect(card['firstName'], 'حسن');
    expect(card['email'], 'h@x.com');
    expect(card.containsKey('receiptImageUrl'), isFalse);
    final model = SubscriptionRequestModel.fromMap(
      Map<String, dynamic>.from(card),
    );
    expect(model.isDeleted, isTrue);
  });

  test('agents deleted earlier come back from their fingerprints', () {
    final cards = SubscriptionRequestService.deletedAgentCards(
      claims: {
        'sas': {
          'h1': {'uid': 'gone', 'at': 5000},
          'h2': {'uid': 'known', 'at': 1},
          'h3': {'uid': 'alive', 'at': 1},
        },
        'phones': {
          'h4': {'uid': 'gone', 'at': 3000},
          'h5': {'uid': SubscriptionRequestService.trustedAdminUid, 'at': 1},
        },
      },
      knownUids: {'known'},
      existingAgents: {'alive'},
    );
    expect(cards, hasLength(1));
    final card = cards.single;
    expect(card.uid, 'gone');
    expect(card.status, 'rejected');
    expect(card.isDeleted, isTrue);
    expect(card.createdAt, DateTime.fromMillisecondsSinceEpoch(3000));
    expect(card.rejectionReason, contains('ساس'));
    expect(card.rejectionReason, contains('رقم هاتف'));
  });

  test('broadcast reaches each approved agent once, never deleted ones', () {
    final recipients = agentBroadcastRecipients([
      _request('a', uid: 'u1', first: 'أحمد'),
      _request('b', uid: 'u2', first: 'باسم', status: 'pending'),
      _request('c', uid: 'u3', first: 'جواد', phone: '+964 770 123 4567'),
      _request('d', uid: 'u4', first: 'داود', phone: ''),
      _request(
        'e',
        uid: 'u5',
        deletedAt: '2026-11-01T00:00:00Z',
        status: 'rejected',
        phone: '07811111111',
      ),
    ]);
    expect(recipients.map((r) => r.uid), ['u1']);

    final all = agentBroadcastRecipients([
      _request('a', uid: 'u1'),
      _request('b', uid: 'u2', status: 'pending', phone: '07900000000'),
    ], approvedOnly: false);
    expect(all.map((r) => r.uid).toSet(), {'u1', 'u2'});
  });

  test('the broadcast text names the agent and plan', () {
    final agent = agentBroadcastRecipients([_request('a', uid: 'u1')]).single;
    expect(
      renderAgentBroadcast('مرحباً {name} ({plan})', agent),
      'مرحباً علي (سنة)',
    );
  });

  test('the profile the agent edited wins over the request', () {
    final profile = AgentProfile.fromValue({
      'firstName': 'علي',
      'lastName': 'حسن',
      'phone': '07812345678',
      'email': 'new@x.com',
    })!;
    expect(profile.name, 'علي حسن');
    expect(profile.phoneOr('07700000000'), '07812345678');
    expect(const AgentProfile().phoneOr('07700000000'), '07700000000');

    final recipients = agentBroadcastRecipients(
      [_request('a', uid: 'u1')],
      profiles: {'u1': profile},
    );
    expect(recipients.single.phone, endsWith('7812345678'));
    expect(recipients.single.name, 'علي حسن');
  });
}
