import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../models.dart';
import 'payment_request_service.dart';
import 'user_role_service.dart';

/// رفض الخادم لأن البصمة مسجلة لحساب آخر.
class TrialClaimedException implements Exception {
  const TrialClaimedException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum TrialClaimResult { owned, otherAccount, unknown }

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

  static bool get _isAdmin =>
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

  static Future<void> _ensure(String kind, String hash, String username) async {
    if (username.trim().isEmpty || _isAdmin) return;
    final result = await claim(kind, hash);
    if (result == TrialClaimResult.otherAccount && onFreeTrial) {
      throw const TrialClaimedException(_sasMessage);
    }
  }
}
