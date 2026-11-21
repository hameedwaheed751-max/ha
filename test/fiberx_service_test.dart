import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:untitled/fiberx_service.dart';

void main() {
  group('PKCE', () {
    test('S256 challenge matches RFC 7636 test vector', () {
      // RFC 7636 Appendix B.
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      expect(
        pkceChallengeS256(verifier),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('generated verifier is URL-safe and long enough', () {
      final v = generateCodeVerifier();
      expect(v.length, greaterThanOrEqualTo(43));
      expect(RegExp(r'^[A-Za-z0-9\-._~]+$').hasMatch(v), isTrue);
    });
  });

  group('auth code extraction', () {
    test('reads code from query', () {
      expect(
        extractAuthCode('https://portal/?state=x&code=ABC123&session=y'),
        'ABC123',
      );
    });
    test('reads code from fragment', () {
      expect(
        extractAuthCode('https://portal/#state=x&code=XYZ.789'),
        'XYZ.789',
      );
    });
    test('null when no code', () {
      expect(extractAuthCode('https://portal/#state=x'), isNull);
      expect(extractAuthCode(null), isNull);
    });
  });

  test('parses Keycloak login form action', () {
    const html = '''
      <form id="kc-form-login" onsubmit="x" action="https://auth.x/realms/openradius/login-actions/authenticate?session_code=SC&amp;execution=EX&amp;client_id=openradius-web&amp;tab_id=TB" method="post">
      <input name="username"/></form>''';
    final action = parseKeycloakFormAction(html);
    expect(action, contains('login-actions/authenticate'));
    expect(action, contains('session_code=SC'));
    // يفكّ ترميز &amp;
    expect(action, contains('&execution=EX'));
    expect(action, isNot(contains('&amp;')));
  });

  test('parses radius users with pagination', () {
    final json = {
      'data': [
        {
          'id': 51553,
          'username': 'br-a97835700',
          'firstname': 'وسن محمود',
          'lastname': '',
          'phone': '07852277702',
          'profileId': 11,
          'profileName': 'بلان',
          'profileBillingId': 11,
          'profileBillingName': 'فايبر اكس لايت',
          'balance': '0.00',
          'expiration': '2026-12-01T15:49:00Z',
          'remainingDays': 11,
          'enabled': true,
          'onlineStatus': 1,
        },
      ],
      'pagination': {'currentPage': 1, 'pageSize': 50, 'totalPages': 3},
    };
    final page = parseFiberXUsers(json);
    expect(page.totalPages, 3);
    expect(page.users.length, 1);
    final u = page.users.first;
    expect(u.radiusUserId, '51553');
    expect(u.username, 'br-a97835700');
    expect(u.name, 'وسن محمود');
    expect(u.planName, 'فايبر اكس لايت');
    expect(u.billingProfileId, '11');
    expect(u.remainingDays, 11);
    expect(u.enabled, isTrue);
    expect(u.online, isTrue);
  });

  test('parses billing profiles and drops inactive/deleted', () {
    final json = [
      {'id': 11, 'name': 'لايت', 'price': 35000, 'radiusProfileId': 11, 'isActive': true},
      {'id': 12, 'name': 'محذوفة', 'price': 1, 'radiusProfileId': 12, 'isActive': true, 'isDeleted': true},
      {'id': 13, 'name': 'معطّلة', 'price': 1, 'radiusProfileId': 13, 'isActive': false},
    ];
    final plans = parseFiberXPlans(json);
    expect(plans.map((p) => p.name), ['لايت', 'محذوفة', 'معطّلة']);
    expect(plans.firstWhere((p) => p.name == 'لايت').isActive, isTrue);
    expect(plans.firstWhere((p) => p.name == 'محذوفة').isActive, isFalse);
    expect(plans.firstWhere((p) => p.name == 'معطّلة').isActive, isFalse);
  });

  test('activation body carries required fields as numbers', () {
    final body = fiberxActivationBody(
      radiusUserId: '51553',
      radiusProfileId: '11',
      billingProfileId: '11',
      amount: 35000,
      durationDays: 30,
      nextExpireDate: DateTime.utc(2026, 12, 31, 15, 49),
    );
    expect(body['radiusUserId'], 51553);
    expect(body['billingProfileId'], 11);
    expect(body['amount'], 35000);
    expect(body['durationDays'], 30);
    expect(body['type'], 'Activation');
    expect(body['paymentMethod'], 'Wallet');
    expect(body['nextExpireDate'], '2026-12-31T15:49:00.000Z');
  });

  test('parses activation result (completed) and failure', () {
    final ok = parseActivationResult({
      'status': 'completed',
      'currentExpireDate': '2026-12-31T15:49:00Z',
      'totalCharged': 35000,
    });
    expect(ok.success, isTrue);
    expect(ok.totalCharged, 35000);
    expect(ok.newExpiration, isNotNull);

    final bad = parseActivationResult({
      'status': 'failed',
      'apiStatusMessage': 'insufficient wallet balance',
    });
    expect(bad.success, isFalse);
    expect(bad.message, contains('insufficient'));
  });

  group('service over a fake Keycloak + API', () {
    const user = 'agent@br';
    const pass = 'secret';

    // رد JSON بترميز UTF-8 (http.Response الافتراضي Latin1 يفشل مع العربية).
    http.Response json(Object body, int status) => http.Response(
      body is String ? body : jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

    MockClient buildClient({bool allowPasswordGrant = true}) {
      return MockClient((request) async {
        final path = request.url.path;
        // Keycloak token endpoint.
        if (path.endsWith('/openid-connect/token')) {
          final body = request.body;
          if (body.contains('grant_type=password')) {
            if (!allowPasswordGrant) {
              return json('{"error":"unauthorized_client"}', 400);
            }
            if (!body.contains('password=$pass')) {
              return json('{"error":"invalid_grant"}', 401);
            }
          }
          return json({
            'access_token': 'tok-abc',
            'refresh_token': 'ref-abc',
            'expires_in': 300,
            'token_type': 'Bearer',
          }, 200);
        }
        // API: requires Bearer token.
        final authed = (request.headers['Authorization'] ?? '').contains('tok-abc');
        if (path.endsWith('/api/radius/users')) {
          if (!authed) return json('unauthorized', 401);
          final page = int.tryParse(request.url.queryParameters['page'] ?? '1') ?? 1;
          final data = [
            {
              'id': 1000 + page,
              'username': 'br-$page',
              'firstname': 'مشترك $page',
              'phone': '0780000000$page',
              'profileId': 11,
              'profileBillingId': 11,
              'profileBillingName': 'لايت',
              'expiration': '2026-12-01T00:00:00Z',
              'remainingDays': 10,
              'enabled': true,
              'onlineStatus': 0,
            },
          ];
          return json({
            'data': data,
            'pagination': {'currentPage': page, 'totalPages': 2},
          }, 200);
        }
        if (path.endsWith('/api/RadiusActivation')) {
          if (!authed) return json('unauthorized', 401);
          return json({
            'status': 'completed',
            'currentExpireDate': '2026-12-31T00:00:00Z',
            'totalCharged': 35000,
          }, 201);
        }
        return json('not found', 404);
      });
    }

    test('logs in via password grant and pages all subscribers', () async {
      final svc = FiberXService(
        username: user,
        password: pass,
        client: buildClient(),
      );
      await svc.login();
      expect(svc.isAuthenticated, isTrue);
      final users = await svc.fetchSubscribers();
      expect(users.length, 2); // page 1 + page 2
      svc.dispose();
    });

    test('wrong password is rejected by password grant', () async {
      final svc = FiberXService(
        username: user,
        password: 'wrong',
        client: buildClient(),
      );
      // منحة كلمة المرور ترفض (401) ثم ينتقل لتدفّق الرمز الذي يفشل أيضاً.
      await expectLater(svc.login(), throwsA(isA<FiberXException>()));
      svc.dispose();
    });

    test('activation posts and parses success', () async {
      final svc = FiberXService(
        username: user,
        password: pass,
        client: buildClient(),
      );
      await svc.login();
      final result = await svc.activate(
        subscriber: const FiberXSubscriber(
          radiusUserId: '51553',
          username: 'br-x',
          name: 'x',
          phone: '',
          planName: 'لايت',
          billingProfileId: '11',
          radiusProfileId: '11',
          balance: 0,
          expiration: null,
          remainingDays: 0,
          enabled: true,
          online: false,
        ),
        plan: const FiberXPlan(
          billingProfileId: '11',
          radiusProfileId: '11',
          name: 'لايت',
          price: 35000,
          isActive: true,
        ),
      );
      expect(result.success, isTrue);
      expect(result.totalCharged, 35000);
      svc.dispose();
    });
  });
}
