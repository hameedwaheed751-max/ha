import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/sas_api_service.dart';

void main() {
  group('supportsCardActivation', () {
    test('true for the otto-isp panel host', () {
      expect(
        SasApiService.supportsCardActivation('https://sas.otto-isp.com/admin'),
        isTrue,
      );
      expect(
        SasApiService.supportsCardActivation('sas.otto-isp.com'),
        isTrue,
      );
    });

    test('false for other companies and for empty input', () {
      expect(
        SasApiService.supportsCardActivation('https://pro.mysvcs.net'),
        isFalse,
      );
      expect(
        SasApiService.supportsCardActivation('https://admin.ftth.iq'),
        isFalse,
      );
      expect(SasApiService.supportsCardActivation(''), isFalse);
      expect(SasApiService.supportsCardActivation('not a url'), isFalse);
    });

    test('is not fooled by the name appearing elsewhere in the url', () {
      expect(
        SasApiService.supportsCardActivation('https://evil.com/otto-isp.com'),
        isFalse,
      );
    });
  });

  group('buildCardActivatePayload', () {
    test('matches the SAS4 card-activation shape from the HAR', () {
      final p = SasApiService.buildCardActivatePayload(
        userId: 300064,
        pin: '11112222333344',
        price: 20000,
        units: 1,
        issueInvoice: 0,
        transactionId: 'tx-1',
      );
      expect(p['method'], 'card');
      expect(p['pin'], '11112222333344');
      expect(p['user_id'], 300064);
      expect(p['money_collected'], 1);
      expect(p['issue_invoice'], 0);
      expect(p['transaction_id'], 'tx-1');
      expect(p['activation_units'], 1);
      expect(p.containsKey('user_price'), isTrue);
    });

    test('falls back to safe defaults when price/units are missing', () {
      final p = SasApiService.buildCardActivatePayload(
        userId: 1,
        pin: '123',
        transactionId: 'tx',
      );
      expect(p['user_price'], 1);
      expect(p['activation_units'], 1);
      expect(p['issue_invoice'], 0);
    });
  });

  group('translateSasError', () {
    test('translates known card errors to Arabic', () {
      expect(
        SasApiService.translateSasError('rsp_error_invalid_card'),
        contains('البطاقة'),
      );
      expect(
        SasApiService.translateSasError('RSP_ERROR_INVALID_CARD'),
        contains('البطاقة'),
      );
    });

    test('returns the original text for unknown codes', () {
      expect(
        SasApiService.translateSasError('rsp_error_insufficient_balance'),
        'rsp_error_insufficient_balance',
      );
      expect(SasApiService.translateSasError('رفض SAS'), 'رفض SAS');
    });
  });
}
