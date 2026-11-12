import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

/// جهاز معروض للبيع داخل متجر وكيل في «المشتريات»: صورة (أو عدة صور) ووصف،
/// واسم وسعر ورقم واتساب اختيارية. معلومات عامة فقط — لا اعتمادات.
@immutable
class Product {
  const Product({
    required this.key,
    required this.storeKey,
    required this.ownerUid,
    required this.ownerName,
    required this.description,
    required this.images,
    this.title = '',
    this.price,
    this.currency = '',
    this.whatsapp = '',
    this.updatedAt = 0,
  });

  final String key;
  final String storeKey;
  final String ownerUid;
  final String ownerName;
  final String description;
  final List<String> images;
  final String title;
  final double? price;
  final String currency;
  final String whatsapp;
  final int updatedAt;

  String get firstImage => images.isNotEmpty ? images.first : '';

  static List<String> _parseImages(Object? raw) {
    final out = <String>[];
    if (raw is List) {
      for (final v in raw) {
        final s = '${v ?? ''}'.trim();
        if (s.isNotEmpty) out.add(s);
      }
    } else if (raw is Map) {
      // RTDB يخزّن القوائم كخريطة بمفاتيح رقمية؛ نرتّبها بالمفتاح.
      final keys = raw.keys.map((k) => '$k').toList()
        ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
      for (final k in keys) {
        final s = '${raw[k] ?? raw[int.tryParse(k)] ?? ''}'.trim();
        if (s.isNotEmpty) out.add(s);
      }
    }
    return out;
  }

  static Product? fromSnapshot(String key, Object? value) {
    if (value is! Map) return null;
    final description = '${value['description'] ?? ''}'.trim();
    final images = _parseImages(value['images']);
    final ownerUid = '${value['ownerUid'] ?? ''}'.trim();
    final storeKey = '${value['storeKey'] ?? ''}'.trim();
    if (description.isEmpty || images.isEmpty || ownerUid.isEmpty) return null;
    final rawPrice = value['price'];
    return Product(
      key: key,
      storeKey: storeKey,
      ownerUid: ownerUid,
      ownerName: '${value['ownerName'] ?? ''}'.trim(),
      description: description,
      images: images,
      title: '${value['title'] ?? ''}'.trim(),
      price: rawPrice is num
          ? rawPrice.toDouble()
          : double.tryParse('${rawPrice ?? ''}'),
      currency: '${value['currency'] ?? ''}'.trim(),
      whatsapp: '${value['whatsapp'] ?? ''}'.trim(),
      updatedAt: value['updatedAt'] is int
          ? value['updatedAt'] as int
          : int.tryParse('${value['updatedAt'] ?? ''}') ?? 0,
    );
  }
}

/// بيانات جهاز يُدخلها الوكيل (تُنظَّف قبل التحقق والكتابة).
@immutable
class ProductSubmission {
  ProductSubmission({
    required String storeKey,
    required String description,
    required this.imageUrls,
    String title = '',
    this.price,
    String currency = '',
    String whatsapp = '',
  })  : storeKey = storeKey.trim(),
        description = description.trim(),
        title = title.trim(),
        currency = currency.trim(),
        whatsapp = whatsapp.trim();

  final String storeKey;
  final String description;
  final List<String> imageUrls;
  final String title;
  final double? price;
  final String currency;
  final String whatsapp;
}

/// خدمة أجهزة المتجر. المصدر في Firebase تحت `products`، والصور في Firebase
/// Storage تحت `product_images/{uid}/...`. لا اعتماد لكل جهاز — يَرِث اعتماد
/// المتجر؛ الكتابة مقفلة على المالك.
class ProductService {
  static const _node = 'products';
  static const maxImages = 5;

  static bool get _ready => Firebase.apps.isNotEmpty;

  /// يتحقق من بيانات الجهاز قبل الرفع/الكتابة. رسالة عربية أو null إن صحّت.
  static String? validateSubmission(ProductSubmission s) {
    if (s.description.isEmpty) return 'اكتب وصف الجهاز';
    if (s.description.length > 500) {
      return 'الوصف طويل (500 حرف كحدٍّ أقصى)';
    }
    if (s.imageUrls.isEmpty) return 'أضف صورة واحدة للجهاز على الأقل';
    if (s.imageUrls.length > maxImages) {
      return 'الحد الأقصى $maxImages صور للجهاز';
    }
    if (s.title.length > 80) return 'اسم الجهاز طويل (80 حرفاً كحدٍّ أقصى)';
    if (s.price != null && s.price! < 0) return 'السعر غير صحيح';
    if (s.whatsapp.length > 30) return 'رقم الواتساب طويل جداً';
    return null;
  }

  /// يقرأ أجهزة متجر واحد مرتّبةً بالأحدث. أي خطأ يُرجع قائمة فارغة.
  Future<List<Product>> loadForStore(String storeKey) async {
    if (!_ready) return const [];
    try {
      final snapshot = await FirebaseDatabase.instance
          .ref(_node)
          .orderByChild('storeKey')
          .equalTo(storeKey)
          .get()
          .timeout(const Duration(seconds: 8));
      final value = snapshot.value;
      final out = <Product>[];
      if (value is Map) {
        value.forEach((key, entry) {
          final p = Product.fromSnapshot('$key', entry);
          if (p != null) out.add(p);
        });
      }
      out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return out;
    } catch (e) {
      debugPrint('products load failed: $e');
      return const [];
    }
  }

  /// يرفع صورة إلى Storage ويعيد رابط تنزيلها. يعمل على الجوال والويب
  /// (putData ببايتات الملف)، على نمط رفع الوصولات الموجود.
  Future<String?> uploadImage(XFile file, {required String productKey}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    final ext = file.name.contains('.')
        ? file.name.split('.').last.toLowerCase()
        : 'jpg';
    final contentType = switch (ext) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      _ => 'image/jpeg',
    };
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final ref = FirebaseStorage.instance.ref(
      'product_images/${user.uid}/$productKey/$stamp-${file.name}',
    );
    final task = await ref.putData(
      await file.readAsBytes(),
      SettableMetadata(contentType: contentType),
    );
    return task.ref.getDownloadURL();
  }

  Map<String, Object> _payload(
    ProductSubmission s, {
    required String ownerUid,
    required String ownerName,
  }) {
    return {
      'storeKey': s.storeKey,
      'ownerUid': ownerUid,
      'ownerName': ownerName,
      'description': s.description,
      if (s.title.isNotEmpty) 'title': s.title,
      if (s.price != null) 'price': s.price!,
      if (s.currency.isNotEmpty) 'currency': s.currency,
      if (s.whatsapp.isNotEmpty) 'whatsapp': s.whatsapp,
      'images': s.imageUrls,
      'updatedAt': ServerValue.timestamp,
    };
  }

  Future<void> add(
    ProductSubmission s, {
    required String ownerUid,
    required String ownerName,
  }) async {
    if (!_ready || FirebaseAuth.instance.currentUser == null) return;
    if (validateSubmission(s) != null) return;
    try {
      await FirebaseDatabase.instance
          .ref(_node)
          .push()
          .set(_payload(s, ownerUid: ownerUid, ownerName: ownerName))
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('product add failed: $e');
    }
  }

  Future<void> updateOwn(
    String key,
    ProductSubmission s, {
    required String ownerUid,
    required String ownerName,
  }) async {
    if (!_ready || FirebaseAuth.instance.currentUser == null) return;
    if (validateSubmission(s) != null) return;
    try {
      await FirebaseDatabase.instance
          .ref('$_node/$key')
          .set(_payload(s, ownerUid: ownerUid, ownerName: ownerName))
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('product update failed: $e');
    }
  }

  Future<void> deleteOwn(String key) => _remove(key);

  Future<void> deleteAny(String key) => _remove(key);

  Future<void> _remove(String key) async {
    if (!_ready || FirebaseAuth.instance.currentUser == null) return;
    try {
      await FirebaseDatabase.instance
          .ref('$_node/$key')
          .remove()
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('product remove failed: $e');
    }
  }
}
