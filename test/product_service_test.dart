import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:untitled/services/product_service.dart';

/// رافع وهمي يسجّل الاستدعاءات بلا شبكة/Firebase.
class _FakeUploader implements ProductImageUploader {
  _FakeUploader({this.returnUrl, this.rateLimited = false});
  String? returnUrl;
  bool rateLimited;
  final List<({Uint8List bytes, String contentType})> uploads = [];
  final List<String> deletes = [];

  @override
  Future<ImageUploadResult> upload(Uint8List bytes,
      {required String contentType}) async {
    uploads.add((bytes: bytes, contentType: contentType));
    return ImageUploadResult(returnUrl, rateLimited: rateLimited);
  }

  @override
  Future<void> delete(String url) async => deletes.add(url);
}

void main() {
  group('Product.fromSnapshot', () {
    test('parses a record with an images map', () {
      final p = Product.fromSnapshot('k1', {
        'storeKey': 's1',
        'ownerUid': 'u1',
        'ownerName': 'مكتب',
        'description': 'راوتر ممتاز',
        'title': 'TP-Link AX1500',
        'price': 25000,
        'currency': 'د.ع',
        'whatsapp': '07700000000',
        'images': {'0': 'https://x/a.jpg', '1': 'https://x/b.jpg'},
        'updatedAt': 7,
      });
      expect(p, isNotNull);
      expect(p!.description, 'راوتر ممتاز');
      expect(p.title, 'TP-Link AX1500');
      expect(p.price, 25000);
      expect(p.images, ['https://x/a.jpg', 'https://x/b.jpg']);
      expect(p.firstImage, 'https://x/a.jpg');
    });

    test('parses images given as a list', () {
      final p = Product.fromSnapshot('k', {
        'storeKey': 's',
        'ownerUid': 'u',
        'ownerName': 'o',
        'description': 'd',
        'images': ['https://x/a.jpg'],
      });
      expect(p, isNotNull);
      expect(p!.images, ['https://x/a.jpg']);
    });

    test('returns null when description or images missing', () {
      expect(
        Product.fromSnapshot('k', {
          'storeKey': 's',
          'ownerUid': 'u',
          'images': {'0': 'https://x/a.jpg'},
        }),
        isNull,
      );
      expect(
        Product.fromSnapshot('k', {
          'storeKey': 's',
          'ownerUid': 'u',
          'description': 'd',
        }),
        isNull,
      );
    });
  });

  group('validateSubmission', () {
    ProductSubmission sub({
      String description = 'جهاز جيد',
      String title = '',
      double? price,
      String currency = 'د.ع',
      String whatsapp = '',
      List<String>? images,
    }) =>
        ProductSubmission(
          storeKey: 's1',
          description: description,
          title: title,
          price: price,
          currency: currency,
          whatsapp: whatsapp,
          imageUrls: images ?? const ['https://x/a.jpg'],
        );

    test('accepts a valid submission', () {
      expect(ProductService.validateSubmission(sub()), isNull);
    });
    test('rejects blank description', () {
      expect(ProductService.validateSubmission(sub(description: '  ')), isNotNull);
    });
    test('rejects no images', () {
      expect(
        ProductService.validateSubmission(sub(images: const [])),
        isNotNull,
      );
    });
    test('rejects more than 5 images', () {
      expect(
        ProductService.validateSubmission(sub(images: List.filled(6, 'https://x/a.jpg'))),
        isNotNull,
      );
    });
    test('rejects negative price', () {
      expect(ProductService.validateSubmission(sub(price: -1)), isNotNull);
    });
    test('rejects description over 500', () {
      expect(
        ProductService.validateSubmission(sub(description: 'ش' * 501)),
        isNotNull,
      );
    });
    test('accepts a valid price', () {
      expect(ProductService.validateSubmission(sub(price: 30000)), isNull);
    });
  });

  group('uploadImage (gateway)', () {
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]);

    test('delegates to the uploader with the sniffed content type', () async {
      final up = _FakeUploader(
        returnUrl: 'https://netagentiraq.duckdns.org/uploads/u1/abc.jpg',
      );
      final svc = ProductService(uploader: up);
      final r = await svc.uploadImage(XFile.fromData(jpeg, name: 'x.jpg'));
      expect(r.ok, isTrue);
      expect(r.url, up.returnUrl);
      expect(up.uploads.length, 1);
      expect(up.uploads.single.contentType, 'image/jpeg');
    });

    test('returns a not-ok result (without uploading) for empty bytes', () async {
      final up = _FakeUploader(returnUrl: 'https://x/u/a.jpg');
      final svc = ProductService(uploader: up);
      final r = await svc.uploadImage(XFile.fromData(Uint8List(0)));
      expect(r.ok, isFalse);
      expect(up.uploads, isEmpty);
    });

    test('propagates a rate-limited result', () async {
      final svc = ProductService(
        uploader: _FakeUploader(returnUrl: null, rateLimited: true),
      );
      final r = await svc.uploadImage(XFile.fromData(jpeg, name: 'x.jpg'));
      expect(r.ok, isFalse);
      expect(r.rateLimited, isTrue);
    });

    test('deleteImage delegates to the uploader', () async {
      final up = _FakeUploader();
      final svc = ProductService(uploader: up);
      await svc.deleteImage('https://netagentiraq.duckdns.org/uploads/u/a.jpg');
      expect(up.deletes, ['https://netagentiraq.duckdns.org/uploads/u/a.jpg']);
    });
  });

  group('contentTypeFor', () {
    test('detects jpeg/png/webp from magic bytes', () {
      expect(
        ProductService.contentTypeFor(Uint8List.fromList([0xFF, 0xD8, 0xFF])),
        'image/jpeg',
      );
      expect(
        ProductService.contentTypeFor(
          Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        ),
        'image/png',
      );
      expect(
        ProductService.contentTypeFor(
          Uint8List.fromList([
            0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50,
          ]),
        ),
        'image/webp',
      );
    });
    test('falls back to jpeg for unknown bytes', () {
      expect(
        ProductService.contentTypeFor(Uint8List.fromList([1, 2, 3, 4])),
        'image/jpeg',
      );
    });
  });

  group('imagesToDelete', () {
    test('returns old urls no longer referenced', () {
      expect(
        ProductService.imagesToDelete(
          ['https://g/u/a.jpg', 'https://g/u/b.jpg', 'https://g/u/c.jpg'],
          ['https://g/u/b.jpg'],
        ),
        ['https://g/u/a.jpg', 'https://g/u/c.jpg'],
      );
    });
    test('returns empty when nothing was removed', () {
      expect(
        ProductService.imagesToDelete(
          ['https://g/u/a.jpg'],
          ['https://g/u/a.jpg', 'https://g/u/new.jpg'],
        ),
        isEmpty,
      );
    });
  });

  group('GatewayProductImageUploader.parseDeletePath', () {
    const gw = 'https://netagentiraq.duckdns.org';
    test('maps a gateway image url to its delete path', () {
      expect(
        GatewayProductImageUploader.parseDeletePath(
          '$gw/uploads/uidA/abc123.jpg',
          gw,
        ),
        '/api/images/uidA/abc123.jpg',
      );
    });
    test('ignores a foreign host (old Firebase url)', () {
      expect(
        GatewayProductImageUploader.parseDeletePath(
          'https://firebasestorage.googleapis.com/v0/b/x/o/product_images%2Fu%2Fk%2Fa.jpg?alt=media',
          gw,
        ),
        isNull,
      );
    });
    test('ignores a non-uploads path on the gateway host', () {
      expect(
        GatewayProductImageUploader.parseDeletePath('$gw/api/waha/xyz', gw),
        isNull,
      );
    });
  });

  group('filter', () {
    Product dev(String key, String owner, String title, String desc) => Product(
          key: key,
          storeKey: owner,
          ownerUid: owner,
          ownerName: 'o',
          description: desc,
          images: const ['https://x/a.jpg'],
          title: title,
        );
    final all = [
      dev('1', 'me', 'راوتر TP-Link', 'جهاز ممتاز'),
      dev('2', 'other', 'سويتش', 'منفذ 8'),
      dev('3', 'me', 'أنتينا', 'خارجية'),
    ];

    test('query matches title or description', () {
      expect(ProductService.filter(all, query: 'راوتر').map((p) => p.key),
          ['1']);
      expect(ProductService.filter(all, query: 'منفذ').map((p) => p.key),
          ['2']);
    });
    test('ownerUid limits to one owner', () {
      expect(ProductService.filter(all, ownerUid: 'me').map((p) => p.key),
          ['1', '3']);
    });
    test('query + owner combined', () {
      expect(
        ProductService.filter(all, query: 'أنتينا', ownerUid: 'me')
            .map((p) => p.key),
        ['3'],
      );
    });
    test('empty query returns all', () {
      expect(ProductService.filter(all).length, 3);
    });
  });

  group('whatsappInquiry', () {
    Product dev({String title = '', String desc = 'جهاز', double? price, String currency = 'د.ع'}) =>
        Product(
          key: 'k',
          storeKey: 's',
          ownerUid: 'u',
          ownerName: 'o',
          description: desc,
          images: const ['https://x/a.jpg'],
          title: title,
          price: price,
          currency: currency,
        );

    test('names the device by its title and includes the price', () {
      final text = ProductService.whatsappInquiry(
        dev(title: 'راوتر TP-Link AX1500', price: 25000),
      );
      expect(text.contains('راوتر TP-Link AX1500'), isTrue);
      expect(text.contains('25,000 د.ع'), isTrue);
      expect(text.contains('مهتمّ'), isTrue);
    });

    test('omits the price clause when there is no price', () {
      final text = ProductService.whatsappInquiry(dev(title: 'سويتش', price: null));
      expect(text.contains('سويتش'), isTrue);
      expect(text.contains('بسعر'), isFalse);
    });

    test('falls back to a short description when there is no title', () {
      final text = ProductService.whatsappInquiry(
        dev(title: '', desc: 'أنتينا خارجية بحالة ممتازة'),
      );
      expect(text.contains('أنتينا خارجية بحالة ممتازة'), isTrue);
    });
  });

  group('relativeTime', () {
    final now = DateTime(2026, 11, 13, 12, 0, 0);
    int ago(Duration d) => now.subtract(d).millisecondsSinceEpoch;

    test('within a minute → الآن', () {
      expect(ProductService.relativeTime(ago(const Duration(seconds: 10)),
          now: now), 'الآن');
    });
    test('minutes/hours/days', () {
      expect(ProductService.relativeTime(ago(const Duration(minutes: 5)),
          now: now), 'منذ 5 دقيقة');
      expect(ProductService.relativeTime(ago(const Duration(hours: 3)),
          now: now), 'منذ 3 ساعة');
      expect(ProductService.relativeTime(ago(const Duration(days: 2)),
          now: now), 'منذ 2 يوم');
    });
    test('zero timestamp → empty', () {
      expect(ProductService.relativeTime(0, now: now), '');
    });
  });
}
