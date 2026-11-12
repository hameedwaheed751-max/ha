import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

/// معرّف الأدمن — الوحيد الذي يعتمد المتاجر أو يحذف متجر غيره.
const String kStoresAdminUid = 'wE10WciDVudIOJziBurjhBxpDfO2';

/// متجر وكيل في قسم «المشتريات»: معلومات عامة فقط (اسم، رابط، شعار، واتساب،
/// وصف) — بلا أي كلمة مرور أو توكن. يُفتح داخل التطبيق لعرض أجهزة الوكيل.
@immutable
class Store {
  const Store({
    required this.key,
    required this.name,
    required this.url,
    required this.ownerUid,
    required this.ownerName,
    required this.approved,
    this.logoUrl = '',
    this.whatsapp = '',
    this.description = '',
    this.updatedAt = 0,
  });

  /// مفتاح Firebase (push id).
  final String key;
  final String name;

  /// رابط المتجر (https).
  final String url;

  /// شعار اختياري؛ إن غاب تُستعمل أيقونة الموقع.
  final String logoUrl;

  /// رقم واتساب اختياري للطلب.
  final String whatsapp;
  final String description;

  /// uid الوكيل المالك (للتعديل/الحذف والإسناد).
  final String ownerUid;

  /// اسم المكتب للعرض.
  final String ownerName;

  /// يبدأ false؛ لا يضبطه true إلا الأدمن.
  final bool approved;
  final int updatedAt;

  /// الشعار المعروض: المخصص إن وُجد، وإلا أيقونة موقع المتجر.
  String get logo {
    if (logoUrl.trim().isNotEmpty) return logoUrl.trim();
    final host = Uri.tryParse(url)?.host ?? '';
    return 'https://www.google.com/s2/favicons?domain=$host&sz=64';
  }

  static Store? fromSnapshot(String key, Object? value) {
    if (value is! Map) return null;
    final name = '${value['name'] ?? ''}'.trim();
    final url = '${value['url'] ?? ''}'.trim();
    final ownerUid = '${value['ownerUid'] ?? ''}'.trim();
    if (name.isEmpty || url.isEmpty || ownerUid.isEmpty) return null;
    return Store(
      key: key,
      name: name,
      url: url,
      ownerUid: ownerUid,
      ownerName: '${value['ownerName'] ?? ''}'.trim(),
      approved: value['approved'] == true,
      logoUrl: '${value['logoUrl'] ?? ''}'.trim(),
      whatsapp: '${value['whatsapp'] ?? ''}'.trim(),
      description: '${value['description'] ?? ''}'.trim(),
      updatedAt: value['updatedAt'] is int
          ? value['updatedAt'] as int
          : int.tryParse('${value['updatedAt'] ?? ''}') ?? 0,
    );
  }
}

/// بيانات متجر يُدخلها الوكيل (تُنظَّف قبل التحقق والكتابة).
@immutable
class StoreSubmission {
  StoreSubmission({
    required String name,
    required String url,
    String logoUrl = '',
    String whatsapp = '',
    String description = '',
  })  : name = name.trim(),
        url = url.trim(),
        logoUrl = logoUrl.trim(),
        whatsapp = whatsapp.trim(),
        description = description.trim();

  final String name;
  final String url;
  final String logoUrl;
  final String whatsapp;
  final String description;
}

/// دليل متاجر الوكلاء المشترك. المصدر في Firebase تحت `stores`. متجر الوكيل
/// لا يظهر لبقية الوكلاء إلا بعد موافقة الأدمن (`approved`).
class StoreDirectoryService {
  static const _node = 'stores';

  static bool get _ready => Firebase.apps.isNotEmpty;

  /// يتحقق من بيانات المتجر قبل الكتابة. يُرجع رسالة خطأ عربية أو null إن صحّت.
  static String? validateSubmission(StoreSubmission s) {
    if (s.name.isEmpty) return 'اكتب اسم المتجر';
    if (s.name.length > 80) return 'اسم المتجر طويل (80 حرفاً كحدٍّ أقصى)';
    if (s.url.isEmpty) return 'اكتب رابط المتجر';
    if (!s.url.startsWith('https://')) {
      return 'يجب أن يبدأ الرابط بـ https://';
    }
    final host = Uri.tryParse(s.url)?.host ?? '';
    if (host.isEmpty) return 'رابط المتجر غير صحيح';
    if (s.url.length > 300) return 'رابط المتجر طويل جداً';
    if (s.logoUrl.length > 500) return 'رابط الشعار طويل جداً';
    if (s.whatsapp.length > 30) return 'رقم الواتساب طويل جداً';
    if (s.description.length > 200) {
      return 'الوصف طويل (200 حرف كحدٍّ أقصى)';
    }
    return null;
  }

  /// يرشّح ما يراه المستخدم: الأدمن يرى الكل؛ الوكيل يرى المعتمدة + متجره
  /// المعلّق فقط (لا معلّقات غيره). مرتّبة أبجدياً بالاسم. دالة نقيّة.
  static List<Store> visibleFor({
    required List<Store> all,
    required String uid,
    required bool isAdmin,
  }) {
    final out = <Store>[];
    for (final s in all) {
      if (isAdmin || s.approved || s.ownerUid == uid) out.add(s);
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  /// يقرأ كل المتاجر مرة. أي خطأ يُرجع قائمة فارغة.
  Future<List<Store>> load() async {
    if (!_ready) return const [];
    try {
      final snapshot = await FirebaseDatabase.instance
          .ref(_node)
          .get()
          .timeout(const Duration(seconds: 8));
      final value = snapshot.value;
      final out = <Store>[];
      if (value is Map) {
        value.forEach((key, entry) {
          final s = Store.fromSnapshot('$key', entry);
          if (s != null) out.add(s);
        });
      }
      return out;
    } catch (e) {
      debugPrint('stores load failed: $e');
      return const [];
    }
  }

  /// يضيف متجراً جديداً للوكيل (`approved:false`). لا يكتب إن لم يكن مسجّلاً.
  Future<void> submit(
    StoreSubmission s, {
    required String ownerUid,
    required String ownerName,
  }) async {
    if (!_ready || FirebaseAuth.instance.currentUser == null) return;
    if (validateSubmission(s) != null) return;
    try {
      await FirebaseDatabase.instance.ref(_node).push().set({
        'name': s.name,
        'url': s.url,
        if (s.logoUrl.isNotEmpty) 'logoUrl': s.logoUrl,
        if (s.whatsapp.isNotEmpty) 'whatsapp': s.whatsapp,
        if (s.description.isNotEmpty) 'description': s.description,
        'ownerUid': ownerUid,
        'ownerName': ownerName,
        'approved': false,
        'updatedAt': ServerValue.timestamp,
      }).timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('store submit failed: $e');
    }
  }

  /// يعدّل متجر المالك (يبقى `approved:false` حتى يعيد الأدمن اعتماده).
  Future<void> updateOwn(
    String key,
    StoreSubmission s, {
    required String ownerUid,
    required String ownerName,
  }) async {
    if (!_ready || FirebaseAuth.instance.currentUser == null) return;
    if (validateSubmission(s) != null) return;
    try {
      await FirebaseDatabase.instance.ref('$_node/$key').set({
        'name': s.name,
        'url': s.url,
        if (s.logoUrl.isNotEmpty) 'logoUrl': s.logoUrl,
        if (s.whatsapp.isNotEmpty) 'whatsapp': s.whatsapp,
        if (s.description.isNotEmpty) 'description': s.description,
        'ownerUid': ownerUid,
        'ownerName': ownerName,
        'approved': false,
        'updatedAt': ServerValue.timestamp,
      }).timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('store update failed: $e');
    }
  }

  Future<void> deleteOwn(String key) => _remove(key);

  /// اعتماد الأدمن: يضبط `approved:true`.
  Future<void> approve(String key) async {
    if (!_ready || FirebaseAuth.instance.currentUser == null) return;
    try {
      await FirebaseDatabase.instance
          .ref('$_node/$key/approved')
          .set(true)
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('store approve failed: $e');
    }
  }

  Future<void> deleteAny(String key) => _remove(key);

  Future<void> _remove(String key) async {
    if (!_ready || FirebaseAuth.instance.currentUser == null) return;
    try {
      await FirebaseDatabase.instance
          .ref('$_node/$key')
          .remove()
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('store remove failed: $e');
    }
  }
}
