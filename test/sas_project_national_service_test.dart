import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:untitled/sas_project_national_service.dart';

// الردود منسوخة من ملفات HAR لموقع admin.ftth.iq، دون أي اتصال حقيقي.
Map<String, dynamic> _subscriptionModel({
  String expiredAt = '2026-09-28T16:59:52.000Z',
}) => {
  'model': {
    'applicableSubscription': {
      'bundleId': 'FTTH_BASIC',
      'variants': [
        {
          'id': 'BASIC',
          'type': {'displayValue': 'Base'},
        },
        {
          'id': 'IPTV',
          'type': {'displayValue': 'Vas'},
        },
      ],
    },
    'customer': {'id': '2276234'},
    'partner': {'id': '2025839'},
    'expiredAt': expiredAt,
    'commitmentPeriodValue': 1,
  },
};

class _Fake {
  final requests = <http.Request>[];
  int tokenCalls = 0;
  int unauthorizedOnce = 0;
  Object? changeResponse = {'paymentUrl': null, 'orderNumber': null};
  int subscriptionPages = 1;

  late final client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    http.Response json(Object body, [int status = 200]) =>
        http.Response(jsonEncode(body), status);
    if (path == '/api/auth/Contractor/token') {
      tokenCalls++;
      return json({'access_token': 'test-token-$tokenCalls'});
    }
    if (unauthorizedOnce > 0) {
      unauthorizedOnce--;
      return http.Response('', 401);
    }
    if (path == '/api/subscriptions/8010490') return json(_subscriptionModel());
    if (path == '/api/subscriptions/calculate-price') {
      return json({
        'model': {
          'totalPrice': {'value': 29000.0, 'currency': 'IQD'},
        },
      });
    }
    if (path == '/api/partners/2025839/wallets/balance') {
      return json({
        'model': {'balance': 3834},
      });
    }
    if (path == '/api/customers/2276234/wallets/balance') {
      return json({
        'model': {'balance': 35000},
      });
    }
    if (path == '/api/subscriptions/8010490/change') {
      return json(changeResponse!);
    }
    if (path == '/api/orders/cancel') return http.Response('', 200);
    if (path == '/api/subscriptions') {
      final page = int.parse(request.url.queryParameters['pageNumber']!);
      final size = int.parse(request.url.queryParameters['pageSize']!);
      final count = page < subscriptionPages ? size : 1;
      return json({
        'totalCount': size * (subscriptionPages - 1) + 1,
        'items': [
          for (var i = 0; i < count; i++)
            {
              'self': {
                'id': '${request.url.queryParameters['status']}-$page-$i',
              },
            },
        ],
      });
    }
    return http.Response('not found', 404);
  });

  SasProjectNationalService service() => SasProjectNationalService(
    const SasProjectNationalSettings(username: 'agent', password: 'secret'),
    client: client,
  );

  http.Request last(String path) =>
      requests.lastWhere((request) => request.url.path == path);
}

void main() {
  test('quote reads services, FTTH price and both balances', () async {
    final fake = _Fake();
    final quote = await fake.service().fetchActivationQuote(
      subscriptionId: '8010490',
      customerId: '2276234',
    );

    expect(quote.price, 29000);
    expect(quote.partnerBalance, 3834);
    expect(quote.customerBalance, 35000);
    expect(quote.detail.services, [
      {'value': 'BASIC', 'type': 'Base'},
      {'value': 'IPTV', 'type': 'Vas'},
    ]);
    expect(quote.canUse(FtthPaymentMethod.customerWallet), isTrue);
    expect(quote.canUse(FtthPaymentMethod.card), isTrue);
    // معطل حتى نتأكد من قيمة الموقع، وأيضاً الرصيد غير كافٍ.
    expect(quote.canUse(FtthPaymentMethod.partnerWallet), isFalse);

    final price = fake.last('/api/subscriptions/calculate-price').url;
    expect(price.queryParametersAll['services'], [
      '{"value":"BASIC","type":"Base"}',
      '{"value":"IPTV","type":"Vas"}',
    ]);
    expect(price.queryParameters['planOperationType'], 'Renew');
  });

  test('every request carries the token, including activation', () async {
    final fake = _Fake();
    final service = fake.service();
    final quote = await service.fetchActivationQuote(
      subscriptionId: '8010490',
      customerId: '2276234',
    );
    await service.activateSubscription(
      detail: quote.detail,
      price: quote.price,
      method: FtthPaymentMethod.customerWallet,
    );
    for (final request in fake.requests.where(
      (request) => request.url.path != '/api/auth/Contractor/token',
    )) {
      expect(request.headers['Authorization'], 'Bearer test-token-1');
    }
    expect(fake.tokenCalls, 1);
  });

  test(
    'customer wallet sends the recorded payload and accepts null result',
    () async {
      final fake = _Fake();
      final service = fake.service();
      final detail = await service.fetchSubscription(
        subscriptionId: '8010490',
        customerId: '2276234',
      );
      final result = await service.activateSubscription(
        detail: detail,
        price: 29000,
        method: FtthPaymentMethod.customerWallet,
      );

      expect(result.paymentUrl, isEmpty);
      final body = jsonDecode(
        fake.last('/api/subscriptions/8010490/change').body,
      );
      expect(body['simulatedPrice'], 29000);
      expect(body['paymentDetails'], {
        'paymentMethod': 'Wallet',
        'walletSource': 'Customer',
      });
      expect(body['services'], [
        {'value': 'BASIC', 'type': 'Base'},
        {'value': 'IPTV', 'type': 'Vas'},
      ]);
    },
  );

  test('card returns the payment link and an order can be cancelled', () async {
    final fake = _Fake()
      ..changeResponse = {
        'paymentUrl': 'https://epg.tabadul.iq/pay',
        'orderNumber': 'order-1',
      };
    final service = fake.service();
    final detail = await service.fetchSubscription(
      subscriptionId: '8010490',
      customerId: '2276234',
    );
    final result = await service.activateSubscription(
      detail: detail,
      price: 29000,
      method: FtthPaymentMethod.card,
    );
    expect(result.paymentUrl, 'https://epg.tabadul.iq/pay');
    expect(result.orderNumber, 'order-1');
    final body = jsonDecode(
      fake.last('/api/subscriptions/8010490/change').body,
    );
    expect(body['paymentDetails']['paymentMethod'], 'Tabadul');

    await service.cancelOrder('order-1');
    expect(jsonDecode(fake.last('/api/orders/cancel').body), {
      'orderNumber': 'order-1',
    });
  });

  test(
    'card without a payment link is reported, not treated as paid',
    () async {
      final fake = _Fake();
      final service = fake.service();
      final detail = await service.fetchSubscription(
        subscriptionId: '8010490',
        customerId: '2276234',
      );
      await expectLater(
        service.activateSubscription(
          detail: detail,
          price: 29000,
          method: FtthPaymentMethod.card,
        ),
        throwsA(
          isA<SasProjectNationalException>().having(
            (e) => e.statusCode,
            'statusCode',
            isNull,
          ),
        ),
      );
    },
  );

  test('partner wallet is never sent until confirmed', () async {
    final fake = _Fake();
    final service = fake.service();
    final detail = await service.fetchSubscription(
      subscriptionId: '8010490',
      customerId: '2276234',
    );
    await expectLater(
      service.activateSubscription(
        detail: detail,
        price: 29000,
        method: FtthPaymentMethod.partnerWallet,
      ),
      throwsA(isA<SasProjectNationalException>()),
    );
    expect(fake.requests.where((r) => r.url.path.endsWith('/change')), isEmpty);
  });

  test('a 401 logs in again and repeats the request once', () async {
    final fake = _Fake();
    final service = fake.service();
    await service.login();
    fake.unauthorizedOnce = 1;
    final detail = await service.fetchSubscription(
      subscriptionId: '8010490',
      customerId: '2276234',
    );
    expect(detail.bundleId, 'FTTH_BASIC');
    expect(fake.tokenCalls, 2);
  });

  test('subscriptions are read past the first page', () async {
    final fake = _Fake()..subscriptionPages = 3;
    final rows = await fake.service().fetchSubscriptions(pageSize: 2);
    // صفحتان كاملتان وصفحة أخيرة بصف واحد، لكل من Active وExpired.
    expect(rows, hasLength(10));
  });

  test('pending activation is confirmed only by a later expiry', () {
    final pending = FtthPendingActivation(
      method: FtthPaymentMethod.card,
      price: 29000,
      previousExpiresAt: DateTime.utc(2026, 9, 28, 16, 59, 52),
      createdAt: DateTime(2026, 9, 28, 21),
      orderNumber: 'order-1',
    );
    final restored = FtthPendingActivation.fromJson(
      jsonDecode(jsonEncode(pending.toJson())),
    )!;
    expect(restored.method, FtthPaymentMethod.card);
    expect(restored.orderNumber, 'order-1');

    FtthSubscriptionDetail detail(String expiredAt) =>
        FtthSubscriptionDetail.fromModel(
          '8010490',
          _subscriptionModel(expiredAt: expiredAt)['model'],
        );
    expect(restored.confirmedBy(detail('2026-09-28T16:59:52.000Z')), isFalse);
    expect(restored.confirmedBy(detail('2026-10-28T16:59:52.000Z')), isTrue);
  });
}
