import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/sas_api_service.dart';

void main() {
  test('the usual SAS base stays first', () {
    final c = SasApiService.apiBaseCandidatesFor('https://sas.example.iq');
    expect(c.first, 'https://sas.example.iq/admin/api/index.php/api/');
    expect(c, contains('https://sas.example.iq/api/index.php/api/'));
  });

  test('a panel under a folder keeps the folder', () {
    final c = SasApiService.apiBaseCandidatesFor(
      'https://host.iq:8443/sas4/admin/#/login',
    );
    expect(c.first, 'https://host.iq:8443/admin/api/index.php/api/');
    expect(c, contains('https://host.iq:8443/sas4/admin/api/index.php/api/'));
    expect(c, contains('https://host.iq:8443/sas4/api/index.php/api/'));
  });

  test('no scheme typed also tries plain http', () {
    final c = SasApiService.apiBaseCandidatesFor('sas.example.iq');
    expect(c.first, startsWith('https://'));
    expect(c, contains('http://sas.example.iq/admin/api/index.php/api/'));
  });

  test('a typed https address never falls back to http', () {
    final c = SasApiService.apiBaseCandidatesFor('https://sas.example.iq');
    expect(c.every((b) => b.startsWith('https://')), isTrue);
  });
}
