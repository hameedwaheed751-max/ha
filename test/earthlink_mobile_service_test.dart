import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:untitled/earthlink_mobile_service.dart';
import 'package:untitled/earthlink_reseller_service.dart' show EarthlinkException;

// قيم وهمية فقط — لا اعتمادات حقيقية.
const _fakeToken = 'FAKE.aaaa.bbbb';

Map<String, dynamic> _wrap(dynamic value, {bool ok = true, String? error}) => {
  'value': value,
  'responseMessage': null,
  'error': error == null ? null : {'message': error, 'errorCode': 7},
  'statusCode': null,
  'isSuccessful': ok,
};

void main() {
  group('pure parsers', () {
    test('login form carries LoginType=1 and grant_type=password', () {
      final form = earthlinkLoginForm(username: 'agent@x', password: 'secret');
      expect(form['LoginType'], '1');
      expect(form['grant_type'], 'password');
      expect(form['username'], 'agent@x');
      expect(form['password'], 'secret');
    });

    test('token + expiry parse', () {
      final json = {'access_token': _fakeToken, 'token_type': 'Bearer', 'expires_in': 3599};
      expect(parseEarthlinkToken(json), _fakeToken);
      expect(parseEarthlinkExpiresIn(json), 3599);
    });

    test('empty token throws', () {
      expect(() => parseEarthlinkToken({'access_token': ''}), throwsA(isA<EarthlinkException>()));
    });

    test('unwrap returns value on success and throws the error message', () {
      expect(earthlinkUnwrap(_wrap(42)), 42);
      expect(
        () => earthlinkUnwrap(_wrap(null, ok: false, error: 'لا يوجد رصيد')),
        throwsA(predicate((e) => e is EarthlinkException && e.message == 'لا يوجد رصيد')),
      );
    });

    test('plans parse accountIndex and name', () {
      final json = _wrap([
        {'accountIndex': 110, 'accountName': 'Turbo', 'accountDescription': 'd'},
        {'accountIndex': '138', 'accountName': 'Plus'},
        {'accountName': 'no-index-dropped'},
      ]);
      final plans = parseEarthlinkMobilePlans(json);
      expect(plans.length, 2);
      expect(plans.first.accountIndex, 110);
      expect(plans.first.name, 'Turbo');
      expect(plans[1].accountIndex, 138);
    });

    test('balance parses the numeric value', () {
      expect(parseEarthlinkBalance(_wrap(12500)), 12500.0);
    });

    test('account cost reads amount and currency', () {
      final cost = parseEarthlinkCost(_wrap({
        'currencyTypeID': 1,
        'value': 25000,
        'currencySign': 'IQD',
        'currencyISOCode': 'IQD',
      }));
      expect(cost.amount, 25000.0);
      expect(cost.currencySign, 'IQD');
    });

    test('user list reads items and totalCount', () {
      final json = _wrap({
        'totalCount': 233,
        'itemsList': [
          {
            'userObject': {'userId': '001@zox', 'displayName': 'Fake One', 'status': 'Active'},
            'userID': '001@zox',
            'fullName': 'Fake One',
            'accountName': 'Turbo',
            'accountIndex': '110',
            'accountStatus': 'Active',
            'activeDaysLeft': '15',
            'manualExpirationDate': '15/01/2027 12:00 AM',
            'mobileNumber': '0770',
            'canRefill': true,
            'canChangeAccount': false,
          },
        ],
      });
      final result = parseEarthlinkUserList(json);
      expect(result.total, 233);
      expect(result.users.length, 1);
      final u = result.users.first;
      expect(u.userId, '001@zox');
      expect(u.name, 'Fake One');
      expect(u.planName, 'Turbo');
      expect(u.accountIndex, 110);
      expect(u.active, isTrue);
      expect(u.daysLeft, 15);
      expect(u.canRefill, isTrue);
      expect(u.expiration, DateTime(2027, 1, 15, 0, 0));
    });

    test('detail prefers ISO accountExpirationDate', () {
      final u = parseEarthlinkUserDetail(_wrap({
        'userID': '002@zox',
        'displayName': 'Fake Two',
        'accountName': 'Plus',
        'accountIndex': 138,
        'accountStatus': 'Suspended',
        'userActive': false,
        'activeDaysLeft': '0',
        'accountExpirationDate': '2027-03-01T08:30:00',
        'manualExpirationDate': '01/03/2027 08:30 AM',
        'mobileNumber': '',
        'canRefill': true,
        'canChangeAccount': true,
        'canExtendUser': false,
      }));
      expect(u.userId, '002@zox');
      expect(u.active, isFalse);
      expect(u.expiration, DateTime(2027, 3, 1, 8, 30));
      expect(u.canChangeAccount, isTrue);
    });

    test('toSubscriber maps to an earthlink subscriber', () {
      final u = EarthlinkMobileUser.fromJson({
        'userID': '003@zox',
        'fullName': 'Fake Three',
        'accountName': 'Eco',
        'accountIndex': 109,
        'accountStatus': 'Active',
        'activeDaysLeft': '5',
        'accountExpirationDate': '2027-02-10T00:00:00',
        'mobileNumber': '0771',
        'canRefill': true,
      });
      final s = u.toSubscriber();
      expect(s.source, 'earthlink');
      expect(s.sasId, '003@zox');
      expect(s.type, 'Eco');
      expect(s.sasData['accountIndex'], 109);
    });

    test('action result: success and failure', () {
      expect(parseEarthlinkActionResult({'value': true, 'isSuccessful': true}).success, isTrue);
      final fail = parseEarthlinkActionResult(
        _wrap(false, ok: false, error: 'كلمة التفعيل غير صحيحة'),
      );
      expect(fail.success, isFalse);
      expect(fail.message, 'كلمة التفعيل غير صحيحة');
    });
  });

  group('service flows (MockClient)', () {
    EarthlinkMobileService svc(MockClient client) => EarthlinkMobileService(
      username: 'agent@x',
      password: 'secret',
      client: client,
    );

    http.Response jsonResp(Object body) =>
        http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

    test('login posts the form and stores the token; later calls send Bearer', () async {
      String? sentAuth;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/token')) {
          expect(req.bodyFields['grant_type'], 'password');
          expect(req.bodyFields['LoginType'], '1');
          return jsonResp({'access_token': _fakeToken, 'token_type': 'Bearer', 'expires_in': 3599});
        }
        if (req.url.path.endsWith('/accounts/all')) {
          sentAuth = req.headers['authorization'] ?? req.headers['Authorization'];
          return jsonResp(_wrap([
            {'accountIndex': 110, 'accountName': 'Turbo'},
          ]));
        }
        return http.Response('not found', 404);
      });
      final s = svc(client);
      final plans = await s.fetchPlans();
      expect(plans.single.name, 'Turbo');
      expect(sentAuth, 'Bearer $_fakeToken');
    });

    test('changeAccount posts UserId + AccountIndex and reads success', () async {
      Map<String, String>? body;
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/token')) {
          return jsonResp({'access_token': _fakeToken, 'expires_in': 3599});
        }
        if (req.url.path.endsWith('/user/chnageaccounttype')) {
          body = req.bodyFields;
          return jsonResp({'value': true, 'isSuccessful': true, 'error': null});
        }
        return http.Response('not found', 404);
      });
      final result = await svc(client).changeAccount(userId: '001@zox', accountIndex: 138);
      expect(result.success, isTrue);
      expect(body?['UserId'], '001@zox');
      expect(body?['AccountIndex'], '138');
    });

    test('accountCost posts AccountID and returns the amount', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/token')) {
          return jsonResp({'access_token': _fakeToken, 'expires_in': 3599});
        }
        if (req.url.path.endsWith('/affiliate/deposit/accountCost')) {
          expect(req.bodyFields['AccountID'], '110');
          return jsonResp(_wrap({'value': 25000, 'currencySign': 'IQD', 'currencyISOCode': 'IQD'}));
        }
        return http.Response('not found', 404);
      });
      final cost = await svc(client).accountCost(110);
      expect(cost.amount, 25000.0);
    });

    test('a failed refill surfaces success=false with the server message', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/token')) {
          return jsonResp({'access_token': _fakeToken, 'expires_in': 3599});
        }
        if (req.url.path.endsWith('/user/newrefilldeposit')) {
          return jsonResp(_wrap(false, ok: false, error: 'لا يوجد رصيد كافٍ'));
        }
        return http.Response('not found', 404);
      });
      final result = await svc(client).refillDeposit(
        userId: '001@zox', customerId: '1', mobileNumber: '0770', depositPassword: 'fake',
      );
      expect(result.success, isFalse);
      expect(result.message, 'لا يوجد رصيد كافٍ');
    });

    test('a 401 on an authed call throws a session error', () async {
      final client = MockClient((req) async {
        if (req.url.path.endsWith('/token')) {
          return jsonResp({'access_token': _fakeToken, 'expires_in': 3599});
        }
        return http.Response('denied', 401);
      });
      expect(svc(client).fetchBalance(), throwsA(isA<EarthlinkException>()));
    });
  });
}
