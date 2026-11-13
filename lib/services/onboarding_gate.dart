import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import '../sas_api_service.dart';
import '../sas_project_national_service.dart';
import 'trial_guard_service.dart';

/// بوابة إلزامية لمرة واحدة عند أول دخول: الوكيل على الباقة المجانية لا يدخل
/// وظائف التطبيق قبل ربط ساس (RADIUS أو FTTH) وإتمام أول مزامنة ناجحة. هذا
/// يربط كل تجربة مجانية بساس حقيقي فيمنع الحسابات الوهمية. المدفوع يُذكَّر فقط.
///
/// القرار النقي في [trialOnboardingNeeded] قابل للاختبار بلا شبكة؛ أما
/// [isTrialOnboardingRequired] فيجمع الحالة الفعلية (إعدادات/مزامنة) ويقرّر.
class OnboardingGate {
  static String _flagKey(String uid) => 'trialSasOnboarded_$uid';
  static String _reminderKey(String uid) => 'sasSyncReminderShown_$uid';

  /// القرار النقي. يمرّ الوكيل (لا بوابة) إذا كان مديراً، أو ليس على المجانية،
  /// أو سبق أن أُعلِن مكتملاً، أو ربط ساساً مطابقاً وزامنه فعلاً.
  static bool trialOnboardingNeeded({
    required bool isAdmin,
    required bool onFreeTrial,
    required bool alreadyFlagged,
    required bool hasRadius,
    required bool radiusSynced,
    required bool ftthConfigured,
    required bool ftthHasSubscribers,
  }) {
    if (isAdmin || !onFreeTrial || alreadyFlagged) return false;
    final satisfied =
        (hasRadius && radiusSynced) || (ftthConfigured && ftthHasSubscribers);
    return !satisfied;
  }

  /// يجمع الحالة الفعلية ويقرّر. يثبّت العلامة للوكيل الذي سبق أن ربط وزامن
  /// (وكلاء ما قبل الميزة) فلا تظهر له البوابة.
  static Future<bool> isTrialOnboardingRequired() async {
    if (TrialGuardService.isAdmin) return false;
    if (!TrialGuardService.onFreeTrial) return false;
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_flagKey(uid)) == true) return false;
    } catch (_) {}

    final needed = trialOnboardingNeeded(
      isAdmin: false,
      onFreeTrial: true,
      alreadyFlagged: false,
      hasRadius: (await _safeRadius()).isNotEmpty,
      radiusSynced: AppStore.lastSasSync != null,
      ftthConfigured: await _ftthConfigured(),
      ftthHasSubscribers: _hasFtthSubscribers(),
    );
    if (!needed) {
      try {
        await prefs?.setBool(_flagKey(uid), true);
      } catch (_) {}
    }
    return needed;
  }

  /// يُستدعى بعد أول مزامنة ناجحة من شاشة البوابة.
  static Future<void> markTrialOnboarded() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_flagKey(uid), true);
    } catch (_) {}
  }

  /// للمدفوع: تذكير غير مُلزِم لمرة واحدة بالربط والمزامنة، لمن لم يفعل بعد.
  static Future<bool> shouldShowPaidSyncReminder() async {
    if (TrialGuardService.isAdmin) return false;
    if (TrialGuardService.onFreeTrial) return false; // المجاني له بوابة
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_reminderKey(uid)) == true) return false;
    } catch (_) {}
    final satisfied =
        ((await _safeRadius()).isNotEmpty && AppStore.lastSasSync != null) ||
        (await _ftthConfigured() && _hasFtthSubscribers());
    return !satisfied;
  }

  static Future<void> markPaidReminderShown() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_reminderKey(uid), true);
    } catch (_) {}
  }

  static bool _hasFtthSubscribers() =>
      AppStore.subscribers.any((s) => s.source == 'ftth');

  static Future<List<SasSettings>> _safeRadius() async {
    try {
      return await SasSettings.loadAll();
    } catch (_) {
      return const [];
    }
  }

  static Future<bool> _ftthConfigured() async {
    try {
      final s = await SasProjectNationalSettings.load();
      return s.username.trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
