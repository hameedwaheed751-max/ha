import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'payment_request_service.dart';
import 'user_role_service.dart';

/// رفض الخادم لأن البصمة مسجلة لحساب آخر. يحمل رسالة واضحة للمستخدم فلا
/// تُطمَس خلف «حدث خطأ غير متوقع».
class TrialClaimedException implements UserFacingException {
  const TrialClaimedException(this.message);
  final String message;
  @override
  String get userMessage => message;
  @override
  String toString() => message;
}

enum TrialClaimResult { owned, otherAccount, unknown }

/// بصمة كما يراها المدير: نوعها، ومن يملكها، وما تمثله إن عُرف.
class TrialClaimEntry {
  const TrialClaimEntry({
    required this.kind,
    required this.hash,
    required this.ownerUid,
    required this.ownerEmail,
    required this.at,
    required this.label,
  });

  final String kind;
  final String hash;
  final String ownerUid;
  final String ownerEmail;
  final DateTime? at;

  /// الرقم أو الساس الذي تطابقه البصمة من بيانات الوكيل، وإلا فارغ.
  final String label;

  String get kindLabel => switch (kind) {
    TrialGuardService.phonesKind => 'رقم هاتف',
    TrialGuardService.sasKind => 'ساس RADIUS',
    _ => 'ساس FTTH',
  };
}

/// يمنع تكرار الباقة المجانية بحسابات جديدة: كل رقم هاتف وكل حساب ساس يُسجَّل
/// لأول حساب يستخدمه. البصمة hash فلا يُخزَّن الرقم ولا بيانات الساس نصاً،
/// وقواعد Firebase تمنع الكتابة فوق بصمة حساب آخر أو حذفها.
class TrialGuardService {
  static const _salt = 'netagent-trial-v1';
  static const phonesKind = 'phones';
  static const sasKind = 'sas';
  static const ftthKind = 'ftth';

  static String _hash(String kind, String value) =>
      sha256.convert(utf8.encode('$_salt|$kind|$value')).toString();

  /// آخر 10 أرقام، فيتساوى 07xx و+9647xx و9647xx.
  static String normalizePhone(String phone) {
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    final western = phone.split('').map((c) {
      final i = arabic.indexOf(c);
      return i >= 0 ? '$i' : c;
    }).join();
    final digits = western.replaceAll(RegExp(r'\D'), '');
    return digits.length > 10 ? digits.substring(digits.length - 10) : digits;
  }

  /// عنوان السيرفر بلا بروتوكول ولا مسار ولا www، مع اسم المستخدم.
  static String normalizeSas(String serverUrl, String username) {
    var host = serverUrl.trim().toLowerCase();
    final parsed = Uri.tryParse(host.contains('://') ? host : 'http://$host');
    if (parsed != null && parsed.host.isNotEmpty) host = parsed.host;
    if (host.startsWith('www.')) host = host.substring(4);
    return '$host|${username.trim().toLowerCase()}';
  }

  static String phoneHash(String phone) =>
      _hash(phonesKind, normalizePhone(phone));
  static String sasHash(String serverUrl, String username) =>
      _hash(sasKind, normalizeSas(serverUrl, username));
  static String ftthHash(String username) =>
      _hash(ftthKind, username.trim().toLowerCase());

  static bool get _firebaseReady => Firebase.apps.isNotEmpty;

  /// يسجل البصمة للحساب الحالي. القواعد ترفض إذا كانت لحساب آخر.
  static Future<TrialClaimResult> claim(String kind, String hash) async {
    if (!_firebaseReady) return TrialClaimResult.unknown;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return TrialClaimResult.unknown;
    try {
      await FirebaseDatabase.instance
          .ref('trialClaims/$kind/$hash')
          .set({'uid': uid, 'at': ServerValue.timestamp})
          .timeout(const Duration(seconds: 10));
      return TrialClaimResult.owned;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') return TrialClaimResult.otherAccount;
      debugPrint('trial claim $kind failed: $e');
      return TrialClaimResult.unknown;
    } catch (e) {
      debugPrint('trial claim $kind failed: $e');
      return TrialClaimResult.unknown;
    }
  }

  static bool get isAdmin =>
      _firebaseReady &&
      FirebaseAuth.instance.currentUser?.uid == UserRoleService.trustedAdminUid;

  static bool get onFreeTrial =>
      AppStore.subscriptionPlan == PaymentPlanCatalog.free15Days;

  /// يُستدعى قبل التجربة المجانية. الرقم المستخدم سابقاً بحساب آخر يُرفض.
  static Future<String> claimTrialPhone(String phone) async {
    final normalized = normalizePhone(phone);
    if (normalized.length < 10) {
      throw const TrialClaimedException('أدخل رقم هاتف صحيحاً');
    }
    final hash = phoneHash(phone);
    final result = await claim(phonesKind, hash);
    if (result == TrialClaimResult.otherAccount) {
      throw const TrialClaimedException(
        'استُخدم رقم الهاتف هذا في باقة مجانية سابقة. اختر باقة مدفوعة.',
      );
    }
    if (result == TrialClaimResult.unknown) {
      throw const TrialClaimedException(
        'تعذر التحقق من رقم الهاتف، تأكد من الاتصال وأعد المحاولة',
      );
    }
    return hash;
  }

  static const _sasMessage =
      'حساب الساس هذا مرتبط بحساب آخر في التطبيق، ولا تتوفر مزامنته في '
      'الباقة المجانية. اشترك بباقة مدفوعة أو تواصل مع الإدارة.';

  /// يُستدعى قبل كل مزامنة. يسجل الساس لأول حساب يربطه، ويمنع المزامنة فقط
  /// لحساب في الباقة المجانية إذا كان الساس لحساب آخر. فشل الاتصال لا يمنع.
  static Future<void> ensureSasAllowed(String serverUrl, String username) =>
      _ensure(sasKind, sasHash(serverUrl, username), username);

  static Future<void> ensureFtthAllowed(String username) =>
      _ensure(ftthKind, ftthHash(username), username);

  /// للوكلاء الذين سبقوا البصمات: يسجل رقم هاتفهم مرة عند فتح التطبيق حتى
  /// لا يُستخدم لتجربة مجانية بحساب جديد. لا يمنع الوكيل نفسه من أي شيء.
  static Future<void> claimExistingPhone() async {
    if (!_firebaseReady || isAdmin) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final snapshot = await FirebaseDatabase.instance
          .ref('agents/$uid/profile/phone')
          .get()
          .timeout(const Duration(seconds: 10));
      final phone = (snapshot.value ?? '').toString();
      if (normalizePhone(phone).length < 10) return;
      final hash = phoneHash(phone);
      final prefs = await SharedPreferences.getInstance();
      final doneKey = 'trialPhoneClaimed_$uid';
      if (prefs.getString(doneKey) == hash) return;
      final result = await claim(phonesKind, hash);
      // رقم مسجل لحساب آخر لا يُعاد فحصه كل مرة؛ المدير يراه في نافذة البصمات.
      if (result != TrialClaimResult.unknown) {
        await prefs.setString(doneKey, hash);
      }
    } catch (e) {
      debugPrint('existing phone claim failed (non-fatal): $e');
    }
  }

  static DatabaseReference get _claimsRef =>
      FirebaseDatabase.instance.ref('trialClaims');

  /// للمدير: بصمات الوكيل، وبصمات رقمه وساسه إن كانت مسجلة لحساب آخر.
  static Future<List<TrialClaimEntry>> claimsForAgent({
    required String uid,
    String phone = '',
  }) async {
    final db = FirebaseDatabase.instance;
    final candidates = <String, String>{}; // '$kind/$hash' → label
    if (normalizePhone(phone).length >= 10) {
      candidates['$phonesKind/${phoneHash(phone)}'] = phone.trim();
    }
    Future<Map?> read(String path) async {
      try {
        final value = (await db.ref(path).get()).value;
        return value is Map ? value : null;
      } catch (_) {
        return null;
      }
    }

    final sas = await read('agents/$uid/sas');
    final sasUser = (sas?['username'] ?? '').toString().trim();
    final sasServer = (sas?['serverUrl'] ?? '').toString().trim();
    if (sasUser.isNotEmpty) {
      final host = normalizeSas(sasServer, sasUser).split('|').first;
      candidates['$sasKind/${sasHash(sasServer, sasUser)}'] =
          '$sasUser @ $host';
    }
    final ftth = await read('agents/$uid/ftth_sas');
    final ftthUser = (ftth?['username'] ?? '').toString().trim();
    if (ftthUser.isNotEmpty) {
      candidates['$ftthKind/${ftthHash(ftthUser)}'] = ftthUser;
    }

    final found = <String, Map>{};
    for (final kind in const [phonesKind, sasKind, ftthKind]) {
      final owned = await _claimsRef
          .child(kind)
          .orderByChild('uid')
          .equalTo(uid)
          .get();
      final value = owned.value;
      if (value is Map) {
        for (final entry in value.entries) {
          if (entry.value is Map) {
            found['$kind/${entry.key}'] = entry.value as Map;
          }
        }
      }
    }
    for (final key in candidates.keys) {
      if (found.containsKey(key)) continue;
      final claim = await read('trialClaims/$key');
      if (claim != null) found[key] = claim;
    }

    final emails = <String, String>{};
    Future<String> emailOf(String owner) async {
      if (owner.isEmpty) return '';
      return emails[owner] ??= await () async {
        try {
          final v = await db.ref('agents/$owner/profile/email').get();
          return (v.value ?? '').toString();
        } catch (_) {
          return '';
        }
      }();
    }

    final entries = <TrialClaimEntry>[];
    for (final entry in found.entries) {
      final parts = entry.key.split('/');
      final owner = (entry.value['uid'] ?? '').toString();
      final at = entry.value['at'];
      entries.add(
        TrialClaimEntry(
          kind: parts.first,
          hash: parts.last,
          ownerUid: owner,
          ownerEmail: await emailOf(owner),
          at: at is num
              ? DateTime.fromMillisecondsSinceEpoch(at.toInt())
              : null,
          label: candidates[entry.key] ?? '',
        ),
      );
    }
    entries.sort((a, b) => a.kind.compareTo(b.kind));
    return entries;
  }

  /// للمدير: يحرر البصمة فيسجلها أول حساب يستخدمها بعد ذلك.
  static Future<void> deleteClaim(TrialClaimEntry entry) =>
      _claimsRef.child('${entry.kind}/${entry.hash}').remove();

  static Future<void> _ensure(String kind, String hash, String username) async {
    if (username.trim().isEmpty || !_firebaseReady || isAdmin) return;
    // بصمة سُجلت لهذا الحساب لا تُكتب مع كل مزامنة، فيبقى تاريخها تاريخ أول
    // ربط. المرفوضة تُفحص كل مرة، فتعمل المزامنة فور حذف المدير لها.
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final doneKey = 'trialClaimed_${kind}_$uid';
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      if (prefs.getString(doneKey) == hash) return;
    } catch (_) {}
    final result = await claim(kind, hash);
    if (result == TrialClaimResult.owned) {
      try {
        await prefs?.setString(doneKey, hash);
      } catch (_) {}
    }
    if (result == TrialClaimResult.otherAccount && onFreeTrial) {
      throw const TrialClaimedException(_sasMessage);
    }
  }
}
