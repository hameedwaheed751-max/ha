import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'subscriber_portal_service.dart';

/// الشاشة التي يفتحها إشعار ضُغط عليه.
enum AgentPushTarget {
  /// طلبات تجديد مشترك نت.
  renewals,

  /// تذاكر دعم مشترك نت.
  tickets,

  /// الدردشة العامة.
  chat,

  /// طلبات اشتراك الوكلاء (للمدير).
  agentRequests,

  /// المشتركون الذين تنتهي اشتراكاتهم قريباً (الملخص الصباحي).
  expiringSubscribers,

  /// اشتراك الوكيل نفسه: تكفي الشاشة الرئيسية.
  home;

  /// رسالة الدردشة والتطبيق مفتوح: شارة الدردشة تكفي، بلا شريط مزعج.
  bool get showsBanner => this != chat;
}

AgentPushTarget? pushTargetFor(Map<String, dynamic> data) =>
    switch ('${data['kind'] ?? ''}') {
      'renewal' => AgentPushTarget.renewals,
      'ticket' => AgentPushTarget.tickets,
      'chat' => AgentPushTarget.chat,
      'agent_request' => AgentPushTarget.agentRequests,
      'digest' => AgentPushTarget.expiringSubscribers,
      'my_subscription' => AgentPushTarget.home,
      _ => null,
    };

/// يسجّل رمز إشعارات الجهاز في البوابة، ويتابع تجدّده، ويلغيه عند الخروج.
/// لا يرمي أبداً: الإشعار تحسين، وغيابه لا يعطّل شيئاً في التطبيق.
class AgentPushRegistrar {
  AgentPushRegistrar({
    required this._getToken,
    required this._tokenRefresh,
    required this._register,
    required this._unregister,
  });

  final Future<String?> Function() _getToken;
  final Stream<String> _tokenRefresh;
  final Future<void> Function(String token) _register;
  final Future<void> Function(String token) _unregister;

  String? _token;
  StreamSubscription<String>? _refresh;

  Future<void> start() async {
    await _refresh?.cancel();
    _refresh = _tokenRefresh.listen(_save);
    try {
      final token = await _getToken();
      if (token != null && token.isNotEmpty) await _save(token);
    } catch (e) {
      debugPrint('agent push token failed: $e');
    }
  }

  Future<void> _save(String token) async {
    _token = token;
    try {
      await _register(token);
    } catch (e) {
      debugPrint('agent push register failed: $e');
    }
  }

  Future<void> stop() async {
    await _refresh?.cancel();
    _refresh = null;
    final token = _token;
    _token = null;
    if (token == null) return;
    try {
      await _unregister(token);
    } catch (e) {
      debugPrint('agent push unregister failed: $e');
    }
  }
}

/// مفتاح Web Push (VAPID) لمشروع وكيل نت: عام، يأتي وقت البناء من بيئة Render.
/// فارغ = لا إشعارات على الويب.
const String _webVapidKey = String.fromEnvironment('FIREBASE_WEB_VAPID_KEY');

/// على الويب يفتح الضغط على الإشعار التطبيقَ بالرابط `/?push=<kind>`.
AgentPushTarget? pushTargetFromUri(Uri uri) {
  final kind = uri.queryParameters['push'];
  return kind == null ? null : pushTargetFor({'kind': kind});
}

/// عرض «فعّل الإشعارات» على الويب مرة في الأسبوع على الأكثر.
bool shouldOfferWebPush({required DateTime? lastOfferedAt, required DateTime now}) =>
    lastOfferedAt == null ||
    now.difference(lastOfferedAt) >= const Duration(days: 7);

/// إشعارات وكيل نت الفورية (Android والويب): مشترك نت، والدردشة، وطلبات
/// الاشتراك، وتذكير اشتراك الوكيل، والملخص الصباحي.
class AgentPush {
  AgentPush._();
  static final AgentPush instance = AgentPush._();

  AgentPushRegistrar? _registrar;
  StreamSubscription<RemoteMessage>? _opened;
  StreamSubscription<RemoteMessage>? _foreground;
  void Function(AgentPushTarget target)? _onOpen;
  void Function(AgentPushTarget target, String title, String body)? _onForeground;
  bool _launchLinkHandled = false;

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool get _web => kIsWeb && _webVapidKey.isNotEmpty;
  static bool get supported => _android || _web;

  /// [onOpen]: ضُغط إشعار → افتح شاشته. [onForeground]: وصل والتطبيق مفتوح.
  /// على Android يُطلب الإذن مباشرة؛ على الويب يُسجَّل الجهاز فقط إن كان الإذن
  /// ممنوحاً، وإلا تعرض الواجهة زر التفعيل ([webPermissionUndecided]).
  Future<void> start({
    required void Function(AgentPushTarget target) onOpen,
    required void Function(AgentPushTarget target, String title, String body)
    onForeground,
  }) async {
    _onOpen = onOpen;
    _onForeground = onForeground;
    if (!supported) return;
    try {
      if (!await SubscriberPortalFeature.isEnabled()) return;
      final messaging = FirebaseMessaging.instance;
      if (kIsWeb) {
        final target = pushTargetFromUri(Uri.base);
        if (target != null && !_launchLinkHandled) {
          _launchLinkHandled = true;
          onOpen(target);
        }
        final settings = await messaging.getNotificationSettings();
        if (settings.authorizationStatus != AuthorizationStatus.authorized) return;
      } else {
        await messaging.requestPermission();
      }
      await _register();
    } catch (e) {
      debugPrint('agent push start failed: $e');
    }
  }

  /// الويب: المتصفح لم يُسأل بعد عن الإذن.
  Future<bool> webPermissionUndecided() async {
    if (!_web) return false;
    try {
      if (!await SubscriberPortalFeature.isEnabled()) return false;
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      return settings.authorizationStatus == AuthorizationStatus.notDetermined;
    } catch (_) {
      return false;
    }
  }

  static const String _offeredAtKey = 'agent_push_web_offered_at';

  /// الويب: هل نعرض «فعّل الإشعارات» الآن؟ (لم يُسأل المتصفح، ولم نعرضه هذا الأسبوع).
  /// يسجّل وقت العرض إن كان الجواب نعم.
  Future<bool> takeWebOffer() async {
    if (!await webPermissionUndecided()) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = DateTime.tryParse(prefs.getString(_offeredAtKey) ?? '');
      final now = DateTime.now();
      if (!shouldOfferWebPush(lastOfferedAt: last, now: now)) return false;
      await prefs.setString(_offeredAtKey, now.toIso8601String());
      return true;
    } catch (_) {
      return false;
    }
  }

  /// الويب: من ضغطة المستخدم (المتصفح يشترطها لطلب الإذن).
  Future<bool> enableOnWeb() async {
    if (!_web) return false;
    try {
      final settings = await FirebaseMessaging.instance.requestPermission();
      if (settings.authorizationStatus != AuthorizationStatus.authorized) return false;
      await _register();
      return true;
    } catch (e) {
      debugPrint('agent web push enable failed: $e');
      return false;
    }
  }

  Future<void> _register() async {
    if (_registrar != null) return;
    final messaging = FirebaseMessaging.instance;
    final client = SubscriberPortalClient.forCurrentUser();
    _registrar = AgentPushRegistrar(
      getToken: () => messaging.getToken(vapidKey: kIsWeb ? _webVapidKey : null),
      tokenRefresh: messaging.onTokenRefresh,
      register: (token) =>
          client.registerDevice(token, platform: kIsWeb ? 'web' : 'android'),
      unregister: client.unregisterDevice,
    );
    await _registrar!.start();

    await _foreground?.cancel();
    _foreground = FirebaseMessaging.onMessage.listen((message) {
      final target = pushTargetFor(message.data);
      if (target == null) return;
      if (target == AgentPushTarget.renewals || target == AgentPushTarget.tickets) {
        SubscriberPortalSync.instance.schedule();
      }
      if (!target.showsBanner) return;
      _onForeground?.call(
        target,
        message.notification?.title ?? '',
        message.notification?.body ?? '',
      );
    });
    if (kIsWeb) return; // الويب: الضغط يمر عبر firebase-messaging-sw.js و ?push=.
    await _opened?.cancel();
    _opened = FirebaseMessaging.onMessageOpenedApp.listen((message) {
      final target = pushTargetFor(message.data);
      if (target != null) _onOpen?.call(target);
    });
    final initial = await messaging.getInitialMessage();
    final target = initial == null ? null : pushTargetFor(initial.data);
    if (target != null) _onOpen?.call(target);
  }

  /// قبل تسجيل الخروج (والتوكن ما زال صالحاً): لا تصل إشعارات هذا الحساب لهذا الجهاز بعدها.
  Future<void> stop() async {
    await _opened?.cancel();
    await _foreground?.cancel();
    _opened = null;
    _foreground = null;
    final registrar = _registrar;
    _registrar = null;
    await registrar?.stop().timeout(const Duration(seconds: 5), onTimeout: () {});
  }
}
