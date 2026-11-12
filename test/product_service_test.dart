import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/services/product_service.dart';

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
}
