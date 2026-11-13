import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
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

/// نتيجة رفع صورة: الرابط عند النجاح، و`rateLimited` عند تجاوز حدّ الرفع (429).
@immutable
class ImageUploadResult {
  const ImageUploadResult(this.url, {this.rateLimited = false});
  final String? url;
  final bool rateLimited;
  bool get ok => url != null && url!.isNotEmpty;
}

/// واجهة رفع/حذف صور الأجهزة. قابلة للحقن كي تُختبر الخدمة بلا شبكة/Firebase.
abstract class ProductImageUploader {
  /// يرفع البايتات ويعيد نتيجة فيها الرابط أو إشارة تجاوز الحد.
  Future<ImageUploadResult> upload(Uint8List bytes, {required String contentType});

  /// حذف أفضل جهد لصورة برابطها. يتجاهل بصمت أي رابط لا يخصّ الـ gateway.
  Future<void> delete(String url);
}

/// التطبيق الفعلي: يرفع صور الأجهزة إلى الـ gateway على الـ VPS عبر `/api/images`
/// بتوكن Firebase، ويقدّمها عبر `/uploads/...`. على نمط `WahaNotificationService`.
class GatewayProductImageUploader implements ProductImageUploader {
  GatewayProductImageUploader({
    String? gatewayUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  })  : _gatewayUrl = (gatewayUrl ?? _configuredGatewayUrl).replaceAll(
          RegExp(r'/+$'),
          '',
        ),
        _client = client ?? http.Client();

  static const String _configuredGatewayUrl = String.fromEnvironment(
    'WAHA_GATEWAY_URL',
    defaultValue: 'https://netagentiraq.duckdns.org',
  );

  final String _gatewayUrl;
  final http.Client _client;
  final Duration timeout;

  /// يحوّل رابط صورة الـ gateway إلى مسار الحذف `/api/images/<uid>/<file>`،
  /// أو null إن كان الرابط لمضيف آخر (روابط Firebase قديمة) أو غير صالح. نقيّة.
  static String? parseDeletePath(String url, String gatewayUrl) {
    final u = Uri.tryParse(url);
    final g = Uri.tryParse(gatewayUrl);
    if (u == null || g == null || u.host.isEmpty || u.host != g.host) return null;
    final segs = u.pathSegments;
    if (segs.length != 3 || segs[0] != 'uploads') return null;
    if (segs[1].isEmpty || segs[2].isEmpty) return null;
    return '/api/images/${segs[1]}/${segs[2]}';
  }

  Future<String?> _token() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    final token = await user.getIdToken();
    return (token == null || token.isEmpty) ? null : token;
  }

  @override
  Future<ImageUploadResult> upload(
    Uint8List bytes, {
    required String contentType,
  }) async {
    final token = await _token();
    if (token == null) return const ImageUploadResult(null);
    try {
      final resp = await _client
          .post(
            Uri.parse('$_gatewayUrl/api/images'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': contentType,
            },
            body: bytes,
          )
          .timeout(timeout);
      if (resp.statusCode == 429) {
        return const ImageUploadResult(null, rateLimited: true);
      }
      if (resp.statusCode != 200) {
        debugPrint('image upload failed: ${resp.statusCode}');
        return const ImageUploadResult(null);
      }
      final data = jsonDecode(resp.body);
      final url = data is Map ? data['url'] : null;
      return ImageUploadResult((url is String && url.isNotEmpty) ? url : null);
    } catch (e) {
      debugPrint('image upload error: $e');
      return const ImageUploadResult(null);
    }
  }

  @override
  Future<void> delete(String url) async {
    final pathPart = parseDeletePath(url, _gatewayUrl);
    if (pathPart == null) return; // رابط أجنبي (مثل Firebase قديم) — يُتجاهَل.
    final token = await _token();
    if (token == null) return;
    try {
      await _client
          .delete(
            Uri.parse('$_gatewayUrl$pathPart'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(timeout);
    } catch (e) {
      debugPrint('image delete error: $e');
    }
  }
}

/// خدمة أجهزة المتجر. المصدر في Firebase تحت `products`، والصور على خادم الـ
/// VPS (الـ gateway) تحت `/uploads/{uid}/...`. لا اعتماد لكل جهاز — يَرِث اعتماد
/// المتجر؛ الكتابة مقفلة على المالك.
class ProductService {
  ProductService({ProductImageUploader? uploader})
      : _uploader = uploader ?? GatewayProductImageUploader();

  static const _node = 'products';
  static const maxImages = 5;

  final ProductImageUploader _uploader;

  static bool get _ready => Firebase.apps.isNotEmpty;

  /// معرّف جديد لجهاز، كي تُرفع صوره تحت مساره قبل حفظه.
  String newKey() => FirebaseDatabase.instance.ref(_node).push().key ?? '';

  /// الروابط القديمة التي لم تعُد مُشار إليها بعد تعديل (قديمة ناقص الجديدة). نقيّة.
  static List<String> imagesToDelete(
    List<String> oldUrls,
    List<String> newUrls,
  ) {
    final keep = newUrls.toSet();
    return oldUrls.where((u) => u.isNotEmpty && !keep.contains(u)).toList();
  }

  /// نوع المحتوى من البايتات الأولى (ليطابق تحقّق الخادم بالـ magic bytes).
  static String contentTypeFor(Uint8List bytes, {String fallback = 'image/jpeg'}) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 && // R
        bytes[1] == 0x49 && // I
        bytes[2] == 0x46 && // F
        bytes[3] == 0x46 && // F
        bytes[8] == 0x57 && // W
        bytes[9] == 0x45 && // E
        bytes[10] == 0x42 && // B
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    return fallback;
  }

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

  /// يقرأ كل الأجهزة المعروضة (سوق مشترك) مرتّبةً بالأحدث. أي خطأ يُرجع قائمة فارغة.
  Future<List<Product>> loadAll() async {
    if (!_ready) return const [];
    try {
      final snapshot = await FirebaseDatabase.instance
          .ref(_node)
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
      debugPrint('products loadAll failed: $e');
      return const [];
    }
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

  /// يرفع صورة إلى خادم الـ VPS (الـ gateway). نوع المحتوى يُشتَق من البايتات
  /// ليطابق تحقّق الخادم. يعمل جوالاً وويباً. يعيد النتيجة (رابط أو تجاوز حد).
  Future<ImageUploadResult> uploadImage(XFile file, {String? productKey}) async {
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return const ImageUploadResult(null);
    final contentType = contentTypeFor(bytes);
    return _uploader.upload(bytes, contentType: contentType);
  }

  /// يرشّح أجهزة بالبحث (الاسم/الوصف) و/أو بمالك واحد. نقيّة.
  static List<Product> filter(
    List<Product> all, {
    String query = '',
    String? ownerUid,
  }) {
    final q = query.trim();
    return all.where((p) {
      if (ownerUid != null && p.ownerUid != ownerUid) return false;
      if (q.isEmpty) return true;
      return p.title.contains(q) || p.description.contains(q);
    }).toList();
  }

  /// وقت نسبي عربي مختصر من طابع زمني بالمللي ثانية. نقيّة (now قابل للحقن).
  static String relativeTime(int ms, {DateTime? now}) {
    if (ms <= 0) return '';
    final then = DateTime.fromMillisecondsSinceEpoch(ms);
    final diff = (now ?? DateTime.now()).difference(then);
    if (diff.isNegative || diff.inSeconds < 60) return 'الآن';
    if (diff.inMinutes < 60) return 'منذ ${diff.inMinutes} دقيقة';
    if (diff.inHours < 24) return 'منذ ${diff.inHours} ساعة';
    if (diff.inDays < 30) return 'منذ ${diff.inDays} يوم';
    final months = diff.inDays ~/ 30;
    if (months < 12) return 'منذ $months شهر';
    return 'منذ ${diff.inDays ~/ 365} سنة';
  }

  /// نص رسالة واتساب الجاهزة عند الطلب: يذكر اسم الجهاز وسعره ليعرف البائع
  /// الجهاز المقصود فوراً بدل محادثة فارغة. نقيّة وقابلة للاختبار.
  static String whatsappInquiry(Product p) {
    final title = p.title.trim();
    final name = title.isNotEmpty
        ? title
        : (p.description.trim().isNotEmpty
            ? _shortName(p.description.trim())
            : 'الجهاز');
    final buffer = StringBuffer('مرحباً، أنا مهتمّ بـ «$name»');
    if (p.price != null) {
      buffer.write(' بسعر ${_groupThousands(p.price!)} ${p.currency}'.trimRight());
    }
    buffer.write('. هل ما زال متاحاً؟');
    return buffer.toString();
  }

  static String _shortName(String text) {
    final line = text.split('\n').first.trim();
    return line.length <= 40 ? line : '${line.substring(0, 40).trim()}…';
  }

  static String _groupThousands(double v) {
    final n = v == v.roundToDouble() ? v.toInt().toString() : v.toString();
    final b = StringBuffer();
    for (var i = 0; i < n.length; i++) {
      if (i > 0 && (n.length - i) % 3 == 0) b.write(',');
      b.write(n[i]);
    }
    return b.toString();
  }

  /// حذف أفضل جهد لصورة برابطها (يتجاهل روابط غير الـ gateway).
  Future<void> deleteImage(String url) => _uploader.delete(url);

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
    // اقرأ صور السجل الحالية قبل الكتابة، لحذف ما لم يعُد مُشاراً إليه لاحقاً.
    List<String> oldImages = const [];
    try {
      final snap = await FirebaseDatabase.instance
          .ref('$_node/$key')
          .get()
          .timeout(const Duration(seconds: 8));
      final v = snap.value;
      if (v is Map) oldImages = Product._parseImages(v['images']);
    } catch (_) {}
    try {
      await FirebaseDatabase.instance
          .ref('$_node/$key')
          .set(_payload(s, ownerUid: ownerUid, ownerName: ownerName))
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('product update failed: $e');
      return; // الكتابة فشلت — لا تلمس الصور كي لا تُفقَد بيانات الإعلان.
    }
    // السجل كُتب بالصور الجديدة — احذف القديمة غير المُشار إليها أفضل‑جهد.
    for (final url in imagesToDelete(oldImages, s.imageUrls)) {
      await deleteImage(url);
    }
  }

  Future<void> deleteOwn(String key) => _remove(key);

  Future<void> deleteAny(String key) => _remove(key);

  Future<void> _remove(String key) async {
    if (!_ready || FirebaseAuth.instance.currentUser == null) return;
    // اجمع روابط الصور قبل الحذف.
    List<String> images = const [];
    try {
      final snap = await FirebaseDatabase.instance
          .ref('$_node/$key')
          .get()
          .timeout(const Duration(seconds: 8));
      final v = snap.value;
      if (v is Map) images = Product._parseImages(v['images']);
    } catch (_) {}
    try {
      await FirebaseDatabase.instance
          .ref('$_node/$key')
          .remove()
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('product remove failed: $e');
      return; // السجل لم يُحذف — أبقِ صوره.
    }
    // السجل (مصدر الحقيقة) حُذف — احذف صوره أفضل‑جهد؛ الفشل يترك ملفاً يتيماً فقط.
    for (final url in images) {
      await deleteImage(url);
    }
  }
}
