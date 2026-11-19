import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:untitled/earthlink_reseller_service.dart';

const _loginPage = '''
<form method="post" action="/Login.aspx">
  <input type="hidden" name="__VIEWSTATE" value="VS1" />
  <input type="hidden" name="__VIEWSTATEGENERATOR" value="GEN1" />
  <input type="hidden" name="__EVENTVALIDATION" value="EV1" />
</form>
''';

// خادم إيرثلنك وهمي: يصدر كوكي جلسة ثم كوكي مصادقة عند دخول صحيح.
class _FakeServer {
  static const goodPassword = 'secret';
  final requests = <http.Request>[];

  late final client = MockClient.streaming((request, bodyStream) async {
    final body = await bodyStream.bytesToString();
    final full = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..body = body;
    requests.add(full);
    final path = request.url.path;

    http.StreamedResponse resp(
      String text,
      int status, {
      Map<String, String> headers = const {},
    }) => http.StreamedResponse(
      Stream.value(utf8.encode(text)),
      status,
      headers: headers,
    );

    if (path == '/Login.aspx' && request.method == 'GET') {
      return resp(
        _loginPage,
        200,
        headers: {'set-cookie': 'ASPNETSESSION=sess1; path=/; HttpOnly'},
      );
    }
    if (path == '/Login.aspx' && request.method == 'POST') {
      final ok = body.contains('Login1%24Password=$goodPassword');
      if (ok) {
        return resp(
          '',
          302,
          headers: {
            'location': '/home.aspx',
            'set-cookie': '.ASPXFORMSDEMO=auth1; path=/; HttpOnly',
          },
        );
      }
      return resp(_loginPage, 200); // بقي في صفحة الدخول = فشل.
    }
    final authed = (request.headers['cookie'] ?? '').contains('.ASPXFORMSDEMO');
    if (path == '/UserManagement.aspx' && request.method == 'GET') {
      if (!authed) return resp(_loginPage, 200);
      // ps=<page>_50: صفحتان كاملتان (50) ثم صفحة أخيرة بصفّين.
      final ps = request.url.queryParameters['ps'] ?? '1_50';
      final page = int.tryParse(ps.split('_').first) ?? 1;
      final count = page <= 2 ? 50 : (page == 3 ? 2 : 0);
      final rows = StringBuffer('<table class="rgMasterTable">');
      for (var i = 0; i < count; i++) {
        final uid = 'p${page}u$i@zox';
        rows.write(
          '<tr class="rgRow"><td>Refill</td><td>$uid مشترك</td>'
          '<td>مشترك</td><td>Paid</td><td>01/01/2026 10:00 AM</td>'
          '<td>Acc. Name : Plus | Acc. Status : Active</td>'
          '<td>Status : Offline</td><td>Mobile : 07700000000</td></tr>',
        );
      }
      rows.write('</table>');
      return resp(rows.toString(), 200);
    }
    if (path == '/Users/ChangeAccount.aspx' && request.method == 'GET') {
      if (!authed) return resp(_loginPage, 200);
      return resp('''
        <select name="AccountTypesDrop\$AccountTypesList">
          <option value="108">Standard</option>
          <option value="138">Plus</option>
          <option value="138">Plus (dup)</option>
          <option value="">-- choose --</option>
        </select>
      ''', 200);
    }
    if (path == '/users/RefillUser.aspx' && request.method == 'GET') {
      if (!authed) return resp(_loginPage, 200);
      return resp(_loginPage, 200); // نفس شكل حقول الرموز المخفية.
    }
    if (path == '/users/RefillUser.aspx' && request.method == 'POST') {
      // نجاح إن حمل الطلب رموز RadAjax والباقة؛ وإلا رد فشل.
      final ok =
          body.contains('__EVENTARGUMENT=refilluser') &&
          body.contains('AccountTypesDrop%24AccountTypesList=138');
      if (ok) {
        return resp(
          '1|#||4|56|updatePanel|RadAjaxManager1SU|Your payment was '
          'accepted by the server and user account has been updated, the '
          'next user expiration date is 18/12/2026 12:59 PM|',
          200,
        );
      }
      return resp(
        '1|#||4|40|updatePanel|wrppaerpanelPanel|Card ID is invalid|',
        200,
      );
    }
    if (path == '/WebAPIs/api/Users/GetUserDisplayInfo') {
      // جلسة منتهية إن لم يصل كوكي المصادقة.
      if (!(request.headers['cookie'] ?? '').contains('.ASPXFORMSDEMO')) {
        return resp(_loginPage, 200);
      }
      return resp(
        jsonEncode({
          'Value': {
            'UserID': request.url.queryParameters['userId'],
            'DisplayName': 'مشترك تجريبي',
            'AccountName': 'Plus',
            'AccountStatus': 'Active',
            'AccountPackageType': 'MonthlyPrepaid',
            'MobileNumber': '07700000000',
            'ActiveDaysLeft': '12',
            'ManualExpirationDate': '12/11/2026 09:49 PM',
            'CanRefill': true,
            'CanChangeAccount': true,
          },
        }),
        200,
      );
    }
    return resp('not found', 404);
  });

  EarthlinkResellerService service({String password = 'secret'}) =>
      EarthlinkResellerService(
        username: 'agent@zox',
        password: password,
        client: client,
      );
}

// كل القيم هنا وهمية؛ البنية فقط منسوخة من شكل HAR لوحة admin.earthlink.iq.
void main() {
  group('extractHiddenField / AspxTokens', () {
    const loginHtml = '''
      <form method="post" action="/Login.aspx">
        <input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="VS123" />
        <input type="hidden" name="__VIEWSTATEGENERATOR" value="GEN456" />
        <input type="hidden" name="__EVENTVALIDATION" id="x" value="EV789" />
        <input name="Login1\$UserName" type="text" />
      </form>
    ''';

    test('reads a hidden field value by name', () {
      expect(extractHiddenField(loginHtml, '__VIEWSTATE'), 'VS123');
      expect(extractHiddenField(loginHtml, '__EVENTVALIDATION'), 'EV789');
      expect(extractHiddenField(loginHtml, 'nope'), isNull);
    });

    test('parse collects the three tokens', () {
      final t = AspxTokens.parse(loginHtml);
      expect(t.viewState, 'VS123');
      expect(t.viewStateGenerator, 'GEN456');
      expect(t.eventValidation, 'EV789');
    });

    test('parse throws when the page is not a WebForms page (session lost)', () {
      expect(
        () => AspxTokens.parse('<html>login required</html>'),
        throwsA(isA<EarthlinkException>()),
      );
    });
  });

  group('earthlinkLoginBody', () {
    test('carries credentials and the scraped tokens (HAR field names)', () {
      final body = earthlinkLoginBody(
        username: 'agent@zox',
        password: 'secret',
        tokens: const AspxTokens(
          viewState: 'VS',
          viewStateGenerator: 'GEN',
          eventValidation: 'EV',
        ),
      );
      expect(body['Login1\$UserName'], 'agent@zox');
      expect(body['Login1\$Password'], 'secret');
      expect(body['__VIEWSTATE'], 'VS');
      expect(body['__EVENTVALIDATION'], 'EV');
      expect(body['Login1\$LoginButton'], isNotEmpty);
    });
  });

  group('parseSetCookie', () {
    test('reads name=value pairs and ignores attributes', () {
      final c = parseSetCookie(
        '.ASPXFORMSDEMO=ABC123; path=/; HttpOnly, ASPNETSESSION=XYZ; path=/',
      );
      expect(c['.ASPXFORMSDEMO'], 'ABC123');
      expect(c['ASPNETSESSION'], 'XYZ');
    });

    test('does not split on a comma inside an Expires date', () {
      final c = parseSetCookie(
        'auth=TOK; expires=Wed, 18 Nov 2026 08:58:39 GMT; path=/',
      );
      expect(c, {'auth': 'TOK'});
    });

    test('tolerates null and empty', () {
      expect(parseSetCookie(null), isEmpty);
      expect(parseSetCookie(''), isEmpty);
    });
  });

  group('EarthlinkSubscriber.fromDisplayInfo', () {
    final response = {
      'Value': {
        'UserID': 'test@zox',
        'DisplayName': 'مشترك تجريبي',
        'AccountName': 'Plus',
        'AccountStatus': 'Active',
        'AccountPackageType': 'MonthlyPrepaid',
        'MobileNumber': '07700000000',
        'ActiveDaysLeft': '12',
        'ManualExpirationDate': '12/11/2026 09:49 PM',
        'CanRefill': true,
        'CanChangeAccount': true,
      },
    };

    test('parses the subscriber fields from the Value wrapper', () {
      final s = EarthlinkSubscriber.fromDisplayInfo(response);
      expect(s.userId, 'test@zox');
      expect(s.displayName, 'مشترك تجريبي');
      expect(s.accountName, 'Plus');
      expect(s.accountStatus, 'Active');
      expect(s.packageType, 'MonthlyPrepaid');
      expect(s.mobileNumber, '07700000000');
      expect(s.daysLeft, 12);
      expect(s.expirationDate, '12/11/2026 09:49 PM');
      expect(s.canRefill, isTrue);
      expect(s.canChangeAccount, isTrue);
    });

    test('accepts a direct value object and defaults missing flags to false', () {
      final s = EarthlinkSubscriber.fromDisplayInfo({
        'UserID': 'x@zox',
        'ActiveDaysLeft': 0,
      });
      expect(s.userId, 'x@zox');
      expect(s.daysLeft, 0);
      expect(s.canRefill, isFalse);
      expect(s.canChangeAccount, isFalse);
    });

    test('throws on a non-map payload', () {
      expect(
        () => EarthlinkSubscriber.fromDisplayInfo('nope'),
        throwsA(isA<EarthlinkException>()),
      );
    });
  });

  group('EarthlinkResellerService.login', () {
    test('scrapes tokens, posts credentials, keeps the auth cookie', () async {
      final server = _FakeServer();
      final service = server.service();
      await service.login();

      expect(service.isAuthenticated, isTrue);
      // أرسل اسم المستخدم والرموز المسحوبة في POST الدخول.
      final post = server.requests.lastWhere(
        (r) => r.method == 'POST' && r.url.path == '/Login.aspx',
      );
      expect(post.body, contains('Login1%24UserName=agent%40zox'));
      expect(post.body, contains('__VIEWSTATE=VS1'));
      expect(post.body, contains('__EVENTVALIDATION=EV1'));
    });

    test('wrong credentials stay on the login page and throw', () async {
      final server = _FakeServer();
      final service = server.service(password: 'wrong');
      await expectLater(
        service.login(),
        throwsA(isA<EarthlinkException>()),
      );
      expect(service.isAuthenticated, isFalse);
    });
  });

  group('EarthlinkResellerService.fetchSubscriber', () {
    test('sends the session cookie and parses the subscriber', () async {
      final server = _FakeServer();
      final service = server.service();
      await service.login();
      final s = await service.fetchSubscriber('test@zox');

      expect(s.userId, 'test@zox');
      expect(s.accountName, 'Plus');
      expect(s.daysLeft, 12);
      final get = server.requests.last;
      expect(get.headers['cookie'], contains('.ASPXFORMSDEMO=auth1'));
    });

    test('an expired session (HTML instead of JSON) throws', () async {
      final server = _FakeServer();
      final service = server.service();
      // بلا تسجيل دخول: لا كوكي مصادقة, فيعيد الخادم صفحة دخول HTML.
      await expectLater(
        service.fetchSubscriber('test@zox'),
        throwsA(isA<EarthlinkException>()),
      );
    });
  });

  group('earthlinkRefillBody', () {
    const tokens = AspxTokens(
      viewState: 'VS',
      viewStateGenerator: 'GEN',
      eventValidation: 'EV',
    );

    test('card mode fills card fields and the RadAjax submit trigger', () {
      final b = earthlinkRefillBody(
        tokens: tokens,
        mode: EarthlinkRefillMode.card,
        planId: '138',
        cardId: '0001',
        cardPassword: '12345678',
      );
      expect(b['__EVENTTARGET'], 'RadAjaxManager1');
      expect(b['__EVENTARGUMENT'], 'refilluser');
      expect(b['refillgroup'], 'userprepayradio');
      expect(b['PrePayCardIdentifier'], '0001');
      expect(b['PrePayCardPassword'], '12345678');
      expect(b['AccountTypesDrop\$AccountTypesList'], '138');
      expect(b['__ASYNCPOST'], 'true');
    });

    test('balance mode uses the deposit radio and no card fields', () {
      final b = earthlinkRefillBody(
        tokens: tokens,
        mode: EarthlinkRefillMode.balance,
        planId: '138',
        onlinePassword: 'pw',
      );
      expect(b['refillgroup'], 'depositradio');
      expect(b['PrePayCardIdentifier'], isEmpty);
      expect(b['onlinepassword'], 'pw');
      expect(b['willpayinbox'], '1');
    });
  });

  group('parseRefillResult', () {
    test('success reads the confirmation and new expiration date', () {
      final r = parseRefillResult(
        'blah user account has been updated, the next user expiration '
        'date is 18/12/2026 12:59 PM|more',
      );
      expect(r.success, isTrue);
      expect(r.newExpiration, '18/12/2026 12:59 PM');
    });

    test('a re-rendered form (no confirmation) is a failure', () {
      final r = parseRefillResult('Card ID is invalid|panel');
      expect(r.success, isFalse);
      expect(r.message, isNotEmpty);
    });
  });

  group('parseEarthlinkDate', () {
    test('reads DD/MM/YYYY with 12-hour AM/PM', () {
      final d = parseEarthlinkDate('27/11/2025 12:46 PM');
      expect(d, DateTime(2025, 11, 27, 12, 46));
      expect(parseEarthlinkDate('01/01/2026 12:00 AM'), DateTime(2026, 1, 1, 0));
      expect(parseEarthlinkDate('05/03/2026 09:30 PM'), DateTime(2026, 3, 5, 21, 30));
    });

    test('date-only and junk', () {
      expect(parseEarthlinkDate('15/06/2026'), DateTime(2026, 6, 15));
      expect(parseEarthlinkDate('no date'), isNull);
    });
  });

  group('parseSubscriberGrid', () {
    const grid = '''
      <table class="rgMasterTable">
      <tr class="rgRow">
        <td>Refill Extend Change</td>
        <td>001@zox ابو فاطمه Affiliate: x</td>
        <td>ابو فاطمه 001 zafranea</td>
        <td>Last Refill : 385 days ago | Payment : All Paid</td>
        <td>27/11/2025 12:46 PM</td>
        <td>Acc. Name : Plus | Acc. Status : Suspended | Days : 0</td>
        <td>Status : Offline</td>
        <td>Mobile : 07700000000 | User Notes :</td>
      </tr>
      <tr class="rgAltRow">
        <td>Refill</td>
        <td>077@zox مشترك ثاني</td>
        <td>مشترك ثاني</td>
        <td>Payment : Paid</td>
        <td>01/01/2026 10:00 AM</td>
        <td>Acc. Name : Standard | Acc. Status : Active</td>
        <td>Status : Online</td>
        <td>Mobile : 07800000000</td>
      </tr>
      </table>
    ''';

    test('reads uid, plan, status, expiration and mobile per row', () {
      final users = parseSubscriberGrid(grid);
      expect(users.length, 2);
      expect(users[0].userId, '001@zox');
      expect(users[0].planName, 'Plus');
      expect(users[0].status, 'Suspended');
      expect(users[0].expiration, '27/11/2025 12:46 PM');
      expect(users[0].mobile, '07700000000');
      expect(users[1].userId, '077@zox');
      expect(users[1].planName, 'Standard');
      expect(users[1].status, 'Active');
    });

    test('empty when there are no grid rows', () {
      expect(parseSubscriberGrid('<html>no grid</html>'), isEmpty);
    });
  });

  group('parsePlans', () {
    test('reads id/name options and drops dups and blanks', () {
      final plans = parsePlans('''
        <option value="108">Standard</option>
        <option value="138">Plus</option>
        <option value="138">Plus again</option>
        <option value="">-- choose --</option>
      ''');
      expect(plans.map((p) => p.id).toList(), ['108', '138']);
      expect(plans.first.name, 'Standard');
    });
  });

  group('EarthlinkResellerService.fetchSubscribers (paging)', () {
    test('walks all pages until a short page, de-duplicating', () async {
      final server = _FakeServer();
      final service = server.service();
      await service.login();
      final users = await service.fetchSubscribers();
      // 50 + 50 + 2 = 102 مشترك عبر ثلاث صفحات.
      expect(users.length, 102);
      // طلب الصفحات بمعامل ps التصاعدي.
      final pages = server.requests
          .where((r) => r.url.path == '/UserManagement.aspx')
          .map((r) => r.url.queryParameters['ps'])
          .toList();
      expect(pages, ['1_50', '2_50', '3_50']);
    });
  });

  group('EarthlinkResellerService.fetchPlans', () {
    test('scrapes the plan picker options', () async {
      final server = _FakeServer();
      final service = server.service();
      await service.login();
      final plans = await service.fetchPlans('test@zox');
      expect(plans.map((p) => p.id), ['108', '138']);
      expect(plans.last.name, 'Plus');
    });
  });

  group('EarthlinkResellerService refill', () {
    test('card refill posts fresh tokens and reads the success date', () async {
      final server = _FakeServer();
      final service = server.service();
      await service.login();
      final r = await service.refillByCard(
        uid: 'test@zox',
        cardId: '0001',
        cardPassword: '12345678',
        planId: '138',
      );
      expect(r.success, isTrue);
      expect(r.newExpiration, '18/12/2026 12:59 PM');
      // سحب الصفحة (GET) ثم إرسال (POST) إلى نفس المسار.
      final posts = server.requests.where(
        (x) => x.method == 'POST' && x.url.path == '/users/RefillUser.aspx',
      );
      expect(posts.single.headers['x-microsoftajax'], 'Delta=true');
    });

    test('balance refill with the wrong plan is reported as failure', () async {
      final server = _FakeServer();
      final service = server.service();
      await service.login();
      final r = await service.refillByBalance(
        uid: 'test@zox',
        planId: '999',
        onlinePassword: 'pw',
      );
      expect(r.success, isFalse);
    });
  });
}
