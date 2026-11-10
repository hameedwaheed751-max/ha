import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

/// شركة في دليل الساسات المشترك: اسمها ورابط لوحتها وشعارها. لا تحمل أي
/// كلمة مرور أو اسم مستخدم أو معرّف وكيل — بيانات الربط تبقى على كل جهاز.
@immutable
class DirectoryCompany {
  const DirectoryCompany({
    required this.host,
    required this.company,
    required this.serverUrl,
    this.logoUrl = '',
    this.seed = false,
    this.updatedAt = 0,
  });

  /// اسم مضيف اللوحة (بلا بروتوكول ولا www) — مفتاح الدمج والتمييز.
  final String host;

  /// اسم الشركة كما يُعرض للوكيل.
  final String company;

  /// رابط لوحة الساس الذي يُملأ عند الاختيار.
  final String serverUrl;

  /// شعار اختياري؛ إن غاب تُستعمل أيقونة الموقع.
  final String logoUrl;

  /// true للمدخلات الجاهزة في الكود، false لما يُجمَّع من ربط الوكلاء.
  final bool seed;

  final int updatedAt;

  /// الشعار المعروض: المخصص إن وُجد، وإلا أيقونة موقع اللوحة.
  String get logo => logoUrl.trim().isNotEmpty
      ? logoUrl.trim()
      : 'https://www.google.com/s2/favicons?domain=$host&sz=64';

  static DirectoryCompany? fromSnapshot(String key, Object? value) {
    if (value is! Map) return null;
    final serverUrl = '${value['serverUrl'] ?? ''}'.trim();
    final company = '${value['company'] ?? ''}'.trim();
    if (serverUrl.isEmpty || company.isEmpty) return null;
    final host = '${value['host'] ?? ''}'.trim().isNotEmpty
        ? '${value['host']}'.trim().toLowerCase()
        : SasDirectoryService.normalizeHost(serverUrl);
    if (host.isEmpty) return null;
    return DirectoryCompany(
      host: host,
      company: company,
      serverUrl: serverUrl,
      logoUrl: '${value['logoUrl'] ?? ''}'.trim(),
      seed: value['seed'] == true,
      updatedAt: value['updatedAt'] is int
          ? value['updatedAt'] as int
          : int.tryParse('${value['updatedAt'] ?? ''}') ?? 0,
    );
  }
}

/// دليل الشركات المشترك: قائمة جاهزة في الكود تُدمج مع ما يجمّعه التطبيق
/// تلقائياً من الساسات التي يربطها الوكلاء، فيختار الوكيل شركته من قائمة
/// بدل كتابة الرابط. المصدر في Firebase تحت `sasDirectory`.
class SasDirectoryService {
  static const _node = 'sasDirectory';

  /// الشركات المعروفة مسبقاً. تُضاف إليها تلقائياً أي ساسات جديدة. لإضافة
  /// شركة جاهزة ضع رابط لوحتها الصحيح هنا — رابط خاطئ يُفشل الدخول.
  static const List<DirectoryCompany> seed = [
    DirectoryCompany(
      host: 'sas.speednet-iq.com',
      company: 'سبيد نت',
      serverUrl: 'https://sas.speednet-iq.com',
      seed: true,
    ),
  ];

  /// اسم المضيف: بلا بروتوكول ولا مسار ولا www، بحروف صغيرة.
  static String normalizeHost(String serverUrl) {
    var host = serverUrl.trim().toLowerCase();
    if (host.isEmpty) return '';
    final parsed = Uri.tryParse(host.contains('://') ? host : 'http://$host');
    if (parsed != null && parsed.host.isNotEmpty) host = parsed.host;
    if (host.startsWith('www.')) host = host.substring(4);
    return host;
  }

  /// مفتاح ثابت للمضيف صالح لمفاتيح Firebase (لا يحوي نقاطاً).
  static String keyFor(String serverUrl) =>
      sha256.convert(utf8.encode(normalizeHost(serverUrl))).toString();

  /// يدمج ما يأتي من السحابة مع القائمة الجاهزة: الجاهزة لا تُستبدل، والمضيف
  /// الواحد مرة واحدة (الأحدث يفوز بين المكرّرات)، ثم ترتيب أبجدي بالاسم.
  static List<DirectoryCompany> mergeWithSeed(List<DirectoryCompany> remote) {
    final byHost = <String, DirectoryCompany>{};
    for (final c in seed) {
      byHost[c.host] = c;
    }
    for (final c in remote) {
      final existing = byHost[c.host];
      if (existing != null && existing.seed) continue; // الجاهزة محميّة
      if (existing != null && existing.updatedAt >= c.updatedAt) continue;
      byHost[c.host] = c;
    }
    final list = byHost.values.toList()
      ..sort((a, b) => a.company.compareTo(b.company));
    return list;
  }

  static bool get _ready => Firebase.apps.isNotEmpty;

  /// يقرأ الدليل مرة ويدمجه مع القائمة الجاهزة. أي خطأ يُرجع الجاهزة فقط.
  static Future<List<DirectoryCompany>> load() async {
    if (!_ready) return mergeWithSeed(const []);
    try {
      final snapshot = await FirebaseDatabase.instance
          .ref(_node)
          .get()
          .timeout(const Duration(seconds: 8));
      final value = snapshot.value;
      final remote = <DirectoryCompany>[];
      if (value is Map) {
        value.forEach((key, entry) {
          final c = DirectoryCompany.fromSnapshot('$key', entry);
          if (c != null) remote.add(c);
        });
      }
      return mergeWithSeed(remote);
    } catch (e) {
      debugPrint('sas directory load failed: $e');
      return mergeWithSeed(const []);
    }
  }

  /// يسجّل ساساً نجح ربطه في الدليل المشترك (اسم + رابط فقط). بلا حجب،
  /// ولا يكتب شيئاً إن كان اسم الشركة فارغاً أو المستخدم غير مسجّل.
  /// يرشّح الحسابات الصالحة للنشر الرجعي: اسم ومضيف غير فارغين، وليست من
  /// المدخلات الجاهزة، والمضيف الواحد مرة واحدة. دالة نقيّة قابلة للاختبار.
  static List<DirectoryCompany> publishable(
    Iterable<DirectoryCompany> accounts,
  ) {
    final seedHosts = seed.map((c) => c.host).toSet();
    final seen = <String>{};
    final out = <DirectoryCompany>[];
    for (final c in accounts) {
      final host = normalizeHost(c.serverUrl);
      if (host.isEmpty || c.company.trim().isEmpty) continue;
      if (seedHosts.contains(host)) continue;
      if (!seen.add(host)) continue;
      out.add(c);
    }
    return out;
  }

  static bool _backfilled = false;

  @visibleForTesting
  static void resetBackfillForTest() => _backfilled = false;

  /// نشر رجعي لمرة واحدة لكل تشغيل: يسجّل ساسات الوكيل المحفوظة مسبقاً في
  /// الدليل (اسم + رابط فقط) كي تظهر دون انتظار ربط جديد. يُستدعى عند فتح
  /// التطبيق؛ آمن للنداء المتكرر لأنه يكتب نفس المفتاح.
  static Future<void> backfill(Iterable<DirectoryCompany> accounts) async {
    if (_backfilled) return;
    _backfilled = true;
    for (final c in publishable(accounts)) {
      await publish(
        company: c.company,
        serverUrl: c.serverUrl,
        logoUrl: c.logoUrl,
      );
    }
  }

  static Future<void> publish({
    required String company,
    required String serverUrl,
    String logoUrl = '',
  }) async {
    if (!_ready) return;
    final name = company.trim();
    final host = normalizeHost(serverUrl);
    if (name.isEmpty || host.isEmpty) return;
    if (FirebaseAuth.instance.currentUser == null) return;
    // لا نلمس مدخلاً جاهزاً بنفس المضيف.
    if (seed.any((c) => c.host == host)) return;
    try {
      await FirebaseDatabase.instance.ref('$_node/${keyFor(serverUrl)}').set({
        'company': name,
        'serverUrl': serverUrl.trim(),
        'host': host,
        if (logoUrl.trim().isNotEmpty) 'logoUrl': logoUrl.trim(),
        'seed': false,
        'updatedAt': ServerValue.timestamp,
      }).timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('sas directory publish failed: $e');
    }
  }
}
