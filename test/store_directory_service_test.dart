import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/services/store_directory_service.dart';

void main() {
  group('Store.fromSnapshot', () {
    test('parses a full record', () {
      final s = Store.fromSnapshot('k1', {
        'name': 'شمس',
        'url': 'https://shams-ftth.vercel.app',
        'ownerUid': 'u1',
        'ownerName': 'مكتب شمس',
        'approved': true,
        'updatedAt': 5,
      });
      expect(s, isNotNull);
      expect(s!.name, 'شمس');
      expect(s.url, 'https://shams-ftth.vercel.app');
      expect(s.ownerName, 'مكتب شمس');
      expect(s.approved, isTrue);
      expect(s.updatedAt, 5);
    });

    test('returns null when name or url missing', () {
      expect(
        Store.fromSnapshot('k', {'url': 'https://x.com', 'ownerUid': 'u'}),
        isNull,
      );
      expect(
        Store.fromSnapshot('k', {'name': 'x', 'ownerUid': 'u'}),
        isNull,
      );
    });

    test('logo falls back to favicon of the url host', () {
      final s = Store.fromSnapshot('k', {
        'name': 'x',
        'url': 'https://shop.example.com/p',
        'ownerUid': 'u',
        'ownerName': 'o',
        'approved': false,
      })!;
      expect(s.logo, contains('domain=shop.example.com'));
    });

    test('logo uses explicit logoUrl when present', () {
      final s = Store.fromSnapshot('k', {
        'name': 'x',
        'url': 'https://a.com',
        'ownerUid': 'u',
        'ownerName': 'o',
        'approved': false,
        'logoUrl': 'https://a.com/logo.png',
      })!;
      expect(s.logo, 'https://a.com/logo.png');
    });
  });

  group('validateSubmission', () {
    StoreSubmission sub({
      String name = 'متجر',
      String url = 'https://a.com',
      String logo = '',
      String wa = '',
      String desc = '',
    }) =>
        StoreSubmission(
          name: name,
          url: url,
          logoUrl: logo,
          whatsapp: wa,
          description: desc,
        );

    test('accepts a valid submission', () {
      expect(StoreDirectoryService.validateSubmission(sub()), isNull);
    });
    test('rejects blank name', () {
      expect(
        StoreDirectoryService.validateSubmission(sub(name: '   ')),
        isNotNull,
      );
    });
    test('rejects blank url', () {
      expect(
        StoreDirectoryService.validateSubmission(sub(url: '  ')),
        isNotNull,
      );
    });
    test('rejects non-https url', () {
      expect(
        StoreDirectoryService.validateSubmission(sub(url: 'http://a.com')),
        isNotNull,
      );
      expect(
        StoreDirectoryService.validateSubmission(
          sub(url: 'javascript:alert(1)'),
        ),
        isNotNull,
      );
      expect(
        StoreDirectoryService.validateSubmission(sub(url: 'a.com')),
        isNotNull,
      );
    });
    test('rejects name over 80 chars', () {
      expect(
        StoreDirectoryService.validateSubmission(sub(name: 'ش' * 81)),
        isNotNull,
      );
    });
  });

  group('visibleFor', () {
    final approved = Store(
      key: 'a',
      name: 'ألف',
      url: 'https://a.com',
      ownerUid: 'u2',
      ownerName: 'o2',
      approved: true,
      updatedAt: 1,
    );
    final myPending = Store(
      key: 'b',
      name: 'باء',
      url: 'https://b.com',
      ownerUid: 'me',
      ownerName: 'me',
      approved: false,
      updatedAt: 1,
    );
    final otherPending = Store(
      key: 'c',
      name: 'جيم',
      url: 'https://c.com',
      ownerUid: 'u3',
      ownerName: 'o3',
      approved: false,
      updatedAt: 1,
    );

    test('agent sees approved + own pending, not others pending', () {
      final v = StoreDirectoryService.visibleFor(
        all: [approved, myPending, otherPending],
        uid: 'me',
        isAdmin: false,
      );
      expect(v.map((s) => s.key), containsAll(['a', 'b']));
      expect(v.map((s) => s.key), isNot(contains('c')));
    });
    test('admin sees everything', () {
      final v = StoreDirectoryService.visibleFor(
        all: [approved, myPending, otherPending],
        uid: 'admin',
        isAdmin: true,
      );
      expect(v.map((s) => s.key), containsAll(['a', 'b', 'c']));
    });
    test('result is sorted by name', () {
      final v = StoreDirectoryService.visibleFor(
        all: [otherPending, approved],
        uid: 'x',
        isAdmin: true,
      );
      expect(v.first.name, 'ألف');
    });
  });
}
