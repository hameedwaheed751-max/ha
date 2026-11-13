import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/services/voucher_store.dart';

void main() {
  group('voucherBuyBody', () {
    test('sends quantity and cardValue as strings (HAR shape)', () {
      expect(
        voucherBuyBody(cardValue: 20000, quantity: 1),
        {'quantity': '1', 'cardValue': '20000'},
      );
    });
  });

  group('parseVoucherBalance', () {
    test('reads the balance string from an auth response', () {
      expect(
        parseVoucherBalance({
          'status': 200,
          'data': {'balance': '232000.000', 'username': 'x'},
        }),
        232000.0,
      );
    });
    test('accepts a direct map and a numeric balance', () {
      expect(parseVoucherBalance({'balance': 50000}), 50000.0);
    });
    test('returns null when absent', () {
      expect(parseVoucherBalance({'data': {}}), isNull);
      expect(parseVoucherBalance('nope'), isNull);
    });
  });

  group('voucherBuySucceeded', () {
    test('true for status 200 with rsp_success', () {
      expect(
        voucherBuySucceeded({'status': 200, 'message': 'rsp_success'}),
        isTrue,
      );
    });
    test('false when the message signals an error', () {
      expect(
        voucherBuySucceeded({
          'status': 200,
          'message': 'rsp_error_insufficient_balance',
        }),
        isFalse,
      );
    });
    test('false for a non-200 status or non-map', () {
      expect(voucherBuySucceeded({'status': 500}), isFalse);
      expect(voucherBuySucceeded('x'), isFalse);
    });
  });

  group('voucherResultMessage', () {
    test('maps known codes to Arabic', () {
      expect(
        voucherResultMessage({'message': 'rsp_success'}),
        'تم شراء الكروت بنجاح',
      );
      expect(
        voucherResultMessage({'message': 'rsp_error_insufficient_balance'}),
        contains('الرصيد غير كافٍ'),
      );
    });
    test('passes through an unknown message', () {
      expect(voucherResultMessage({'message': 'weird'}), 'weird');
    });
  });

  group('CardSeries.parseList', () {
    final response = {
      'current_page': 1,
      'data': [
        {
          'series': '2026-819119',
          'value': '23000.000',
          'qty': 2,
          'used': '1',
          'series_date': '2026-11-12 23:28:05',
          'expiration': '2027-12-31',
          'profile_details': {'id': 5, 'name': 'Standard'},
        },
      ],
    };

    test('parses series, value, qty, used, profile and dates', () {
      final list = CardSeries.parseList(response);
      expect(list.length, 1);
      final s = list.first;
      expect(s.series, '2026-819119');
      expect(s.value, 23000);
      expect(s.qty, 2);
      expect(s.used, 1);
      expect(s.available, 1);
      expect(s.profileName, 'Standard');
      expect(s.expiration, '2027-12-31');
    });

    test('skips rows without a series', () {
      expect(
        CardSeries.parseList({
          'data': [
            {'value': 1},
          ],
        }),
        isEmpty,
      );
    });
  });

  group('CardPin.parseList', () {
    final response = {
      'data': [
        {
          'serialnumber': '2026-788904-1749-12033',
          'pin': '76323652302266',
          'used_at': '2026-11-12 23:28:12',
          'user_id': 300125,
        },
        {
          'serialnumber': '2026-788904-1749-12034',
          'pin': '64991012169097',
          'used_at': null,
          'user_id': null,
        },
      ],
    };

    test('parses pin and used status', () {
      final list = CardPin.parseList(response);
      expect(list.length, 2);
      expect(list[0].pin, '76323652302266');
      expect(list[0].isUsed, isTrue);
      expect(list[1].pin, '64991012169097');
      expect(list[1].isUsed, isFalse);
    });

    test('skips rows without a pin', () {
      expect(
        CardPin.parseList({
          'data': [
            {'serialnumber': 'x'},
          ],
        }),
        isEmpty,
      );
    });
  });

  group('query builders', () {
    test('cardSeriesQuery matches the HAR shape', () {
      final q = cardSeriesQuery();
      expect(q['sortBy'], 'series_date');
      expect(q['direction'], 'desc');
      expect(q['page'], 1);
      expect((q['columns'] as List).contains('series'), isTrue);
    });
    test('seriesCardsQuery matches the HAR shape', () {
      final q = seriesCardsQuery();
      expect(q['sortBy'], 'id');
      expect((q['columns'] as List).contains('pin'), isTrue);
    });
  });

  group('VoucherPurchase.parseList', () {
    final response = {
      'status': 200,
      'data': [
        {
          'id': 2039505,
          'card_value': 20000,
          'qty': 1,
          'status': 0,
          'created_at': '2026-11-13 13:58:07',
        },
        {
          'id': 2039451,
          'card_value': 23000,
          'qty': 5,
          'status': 2,
          'created_at': '2026-11-13 13:26:43',
        },
      ],
    };

    test('parses value, qty, status and date', () {
      final list = VoucherPurchase.parseList(response);
      expect(list.length, 2);
      expect(list.first.cardValue, 20000);
      expect(list.first.qty, 1);
      expect(list.first.status, 0);
      expect(list.first.statusLabel, 'قيد التنفيذ');
      expect(list.first.isComplete, isFalse);
      expect(list[1].statusLabel, 'مكتمل');
      expect(list[1].isComplete, isTrue);
    });

    test('tolerates a non-list payload', () {
      expect(VoucherPurchase.parseList({'data': null}), isEmpty);
      expect(VoucherPurchase.parseList('x'), isEmpty);
    });
  });
}
