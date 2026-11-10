import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/services/sas_directory_service.dart';

void main() {
  group('normalizeHost', () {
    test('strips protocol, path and www, lowercases', () {
      expect(
        SasDirectoryService.normalizeHost('HTTPS://WWW.Sas.Speednet-iq.com/admin'),
        'sas.speednet-iq.com',
      );
      expect(
        SasDirectoryService.normalizeHost('sas.speednet-iq.com'),
        'sas.speednet-iq.com',
      );
      expect(
        SasDirectoryService.normalizeHost('http://1.2.3.4:8080/x'),
        '1.2.3.4',
      );
    });
  });

  group('keyFor', () {
    test('same host maps to the same key regardless of scheme or path', () {
      final a = SasDirectoryService.keyFor('https://www.sas.speednet-iq.com/');
      final b = SasDirectoryService.keyFor('http://sas.speednet-iq.com/admin');
      expect(a, b);
      expect(a, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('different hosts map to different keys', () {
      expect(
        SasDirectoryService.keyFor('https://a.example.com'),
        isNot(SasDirectoryService.keyFor('https://b.example.com')),
      );
    });
  });

  group('logo', () {
    test('uses logoUrl when set, else the host favicon', () {
      const withLogo = DirectoryCompany(
        host: 'a.com',
        company: 'A',
        serverUrl: 'https://a.com',
        logoUrl: 'https://cdn/a.png',
      );
      expect(withLogo.logo, 'https://cdn/a.png');

      const noLogo = DirectoryCompany(
        host: 'sas.speednet-iq.com',
        company: 'سبيد نت',
        serverUrl: 'https://sas.speednet-iq.com',
      );
      expect(noLogo.logo, contains('sas.speednet-iq.com'));
      expect(noLogo.logo, startsWith('https://'));
    });
  });

  group('mergeWithSeed', () {
    test('keeps every seed company even with no remote data', () {
      final merged = SasDirectoryService.mergeWithSeed(const []);
      expect(merged, isNotEmpty);
      expect(merged.every((c) => c.seed), isTrue);
    });

    test('adds remote companies and sorts by name', () {
      final merged = SasDirectoryService.mergeWithSeed(const [
        DirectoryCompany(
          host: 'z.example.com',
          company: 'زوز نت',
          serverUrl: 'https://z.example.com',
        ),
        DirectoryCompany(
          host: 'a.example.com',
          company: 'آسيا سيل',
          serverUrl: 'https://a.example.com',
        ),
      ]);
      final hosts = merged.map((c) => c.host).toSet();
      expect(hosts, containsAll(['z.example.com', 'a.example.com']));
      // مرتبة أبجدياً حسب الاسم.
      final names = merged.map((c) => c.company).toList();
      final sorted = [...names]..sort();
      expect(names, sorted);
    });

    test('a remote entry never overrides a seed with the same host', () {
      final seedHost =
          SasDirectoryService.seed.first.host;
      final merged = SasDirectoryService.mergeWithSeed([
        DirectoryCompany(
          host: seedHost,
          company: 'اسم مزيّف',
          serverUrl: 'https://evil.example.com',
        ),
      ]);
      final entry = merged.firstWhere((c) => c.host == seedHost);
      expect(entry.seed, isTrue);
      expect(entry.company, SasDirectoryService.seed.first.company);
      expect(entry.serverUrl, SasDirectoryService.seed.first.serverUrl);
    });

    test('deduplicates remote entries that share a host', () {
      final merged = SasDirectoryService.mergeWithSeed(const [
        DirectoryCompany(
          host: 'dup.example.com',
          company: 'الأحدث',
          serverUrl: 'https://dup.example.com',
          updatedAt: 200,
        ),
        DirectoryCompany(
          host: 'dup.example.com',
          company: 'الأقدم',
          serverUrl: 'https://dup.example.com',
          updatedAt: 100,
        ),
      ]);
      final dups = merged.where((c) => c.host == 'dup.example.com').toList();
      expect(dups, hasLength(1));
    });
  });
}
