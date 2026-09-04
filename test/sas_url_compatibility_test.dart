import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/sas_api_service.dart';

void main() {
  group('SasApiService.computeOriginFor', () {
    test('bare host normalizes to https origin', () {
      expect(
        SasApiService.computeOriginFor('sas.example.com'),
        'https://sas.example.com',
      );
    });

    test('bare host with trailing slash', () {
      expect(
        SasApiService.computeOriginFor('sas.example.com/'),
        'https://sas.example.com',
      );
    });

    test('host with /speednet prefix returns origin only', () {
      expect(
        SasApiService.computeOriginFor('https://sas.example.com/speednet'),
        'https://sas.example.com',
      );
    });

    test('host with full admin API path returns origin only', () {
      expect(
        SasApiService.computeOriginFor(
          'https://sas.example.com/admin/api/index.php/api',
        ),
        'https://sas.example.com',
      );
    });

    test('host with prefix and full API path returns origin only', () {
      expect(
        SasApiService.computeOriginFor(
          'https://sas.example.com/speednet/admin/api/index.php/api',
        ),
        'https://sas.example.com',
      );
    });
  });

  group('SasApiService.computeApiBaseFor', () {
    test('bare host', () {
      expect(
        SasApiService.computeApiBaseFor('sas.example.com'),
        'https://sas.example.com/admin/api/index.php/api/',
      );
    });

    test('host with /api index.php path', () {
      expect(
        SasApiService.computeApiBaseFor(
          'https://sas.example.com/api/index.php/api',
        ),
        'https://sas.example.com/api/index.php/api/',
      );
    });

    test('host with /speednet prefix + /api index.php', () {
      expect(
        SasApiService.computeApiBaseFor(
          'https://sas.example.com/speednet/api/index.php/api',
        ),
        'https://sas.example.com/speednet/api/index.php/api/',
      );
    });

    test('host with full admin API path', () {
      expect(
        SasApiService.computeApiBaseFor(
          'https://sas.example.com/admin/api/index.php/api',
        ),
        'https://sas.example.com/admin/api/index.php/api/',
      );
    });

    test('host with /speednet prefix + full admin API path', () {
      expect(
        SasApiService.computeApiBaseFor(
          'https://sas.example.com/speednet/admin/api/index.php/api',
        ),
        'https://sas.example.com/speednet/admin/api/index.php/api/',
      );
    });

    test('host with login endpoint stripped', () {
      expect(
        SasApiService.computeApiBaseFor(
          'https://sas.example.com/speednet/admin/api/index.php/api/login',
        ),
        'https://sas.example.com/speednet/admin/api/index.php/api/',
      );
    });

    test('bare /api path without index.php falls back to default admin API', () {
      expect(
        SasApiService.computeApiBaseFor('https://sas.example.com/api'),
        'https://sas.example.com/admin/api/index.php/api/',
      );
    });

    test('bare /speednet/api path falls back to default admin API', () {
      expect(
        SasApiService.computeApiBaseFor('https://sas.example.com/speednet/api'),
        'https://sas.example.com/admin/api/index.php/api/',
      );
    });
  });
}
