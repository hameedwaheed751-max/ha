import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/services/agent_push_service.dart';

void main() {
  late List<String> registered;
  late List<String> unregistered;
  late StreamController<String> refresh;

  AgentPushRegistrar registrar({String? token = 'token-1', bool failRegister = false}) =>
      AgentPushRegistrar(
        getToken: () async => token,
        tokenRefresh: refresh.stream,
        register: (t) async {
          if (failRegister) throw Exception('offline');
          registered.add(t);
        },
        unregister: (t) async => unregistered.add(t),
      );

  setUp(() {
    registered = [];
    unregistered = [];
    refresh = StreamController<String>.broadcast();
  });

  test('registers the current token and every refreshed token', () async {
    final r = registrar();
    await r.start();
    refresh.add('token-2');
    await Future<void>.delayed(Duration.zero);
    expect(registered, ['token-1', 'token-2']);
  });

  test('stopping unregisters the latest token and ignores later refreshes', () async {
    final r = registrar();
    await r.start();
    refresh.add('token-2');
    await Future<void>.delayed(Duration.zero);
    await r.stop();
    refresh.add('token-3');
    await Future<void>.delayed(Duration.zero);
    expect(unregistered, ['token-2']);
    expect(registered, ['token-1', 'token-2']);
  });

  test('no token means nothing to register or unregister', () async {
    final r = registrar(token: null);
    await r.start();
    await r.stop();
    expect(registered, isEmpty);
    expect(unregistered, isEmpty);
  });

  test('a failed registration never throws to the caller', () async {
    final r = registrar(failRegister: true);
    await r.start();
    refresh.add('token-2');
    await Future<void>.delayed(Duration.zero);
    expect(registered, isEmpty);
  });

  test('starting twice keeps a single refresh listener', () async {
    final r = registrar();
    await r.start();
    await r.start();
    refresh.add('token-2');
    await Future<void>.delayed(Duration.zero);
    expect(registered.where((t) => t == 'token-2').length, 1);
  });

  test('each notification kind opens its screen', () {
    expect(pushTargetFor({'kind': 'renewal'}), AgentPushTarget.renewals);
    expect(pushTargetFor({'kind': 'ticket'}), AgentPushTarget.tickets);
    expect(pushTargetFor({'kind': 'chat'}), AgentPushTarget.chat);
    expect(pushTargetFor({'kind': 'agent_request'}), AgentPushTarget.agentRequests);
    expect(pushTargetFor({'kind': 'digest'}), AgentPushTarget.expiringSubscribers);
    expect(pushTargetFor({'kind': 'my_subscription'}), AgentPushTarget.home);
    expect(pushTargetFor({'kind': 'other'}), isNull);
    expect(pushTargetFor(const {}), isNull);
  });

  test('chat messages show no in-app banner; the rest do', () {
    expect(AgentPushTarget.chat.showsBanner, isFalse);
    expect(AgentPushTarget.renewals.showsBanner, isTrue);
    expect(AgentPushTarget.agentRequests.showsBanner, isTrue);
  });

  test('a web notification click opens its screen through ?push=', () {
    expect(
      pushTargetFromUri(Uri.parse('https://x.onrender.com/?push=ticket')),
      AgentPushTarget.tickets,
    );
    expect(pushTargetFromUri(Uri.parse('https://x.onrender.com/')), isNull);
    expect(pushTargetFromUri(Uri.parse('https://x.onrender.com/?push=zzz')), isNull);
  });

  test('the web permission offer shows at most once a week', () {
    final now = DateTime(2026, 11, 17, 10);
    expect(shouldOfferWebPush(lastOfferedAt: null, now: now), isTrue);
    expect(
      shouldOfferWebPush(lastOfferedAt: now.subtract(const Duration(days: 2)), now: now),
      isFalse,
    );
    expect(
      shouldOfferWebPush(lastOfferedAt: now.subtract(const Duration(days: 8)), now: now),
      isTrue,
    );
  });
}
