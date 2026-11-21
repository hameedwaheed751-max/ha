import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'services/trial_guard_service.dart';

/// خدمة وكيل «فايبر اكس» عبر منصّة OpenRADIUS الحديثة.
///
/// ليست SAS4 ولا FTTH ولا إيرثلنك: واجهتها API حديثة بصيغة JSON على
/// api.fiberx-openradius.net، والمصادقة عبر Keycloak (OAuth2/OIDC) برمز
/// Bearer JWT (لا كوكيز جلسة ولا ViewState). الدفع من محفظة الوكيل مثل FTTH.
///
/// مبنية من ملف HAR حقيقي للوكيل، دون طباعة أي اعتماد أو توكن.

class FiberXException implements Exception {
  const FiberXException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'FiberXException($message)';
}

/// العناوين الثابتة لمنصّة فايبر اكس (من HAR الوكيل).
class FiberXEndpoints {
  static const authRealm =
      'https://auth.fiberx-openradius.net/realms/openradius';
  static const tokenUrl = '$authRealm/protocol/openid-connect/token';
  static const authorizeUrl = '$authRealm/protocol/openid-connect/auth';
  static const apiBase = 'https://api.fiberx-openradius.net';
  static const clientId = 'openradius-web';
  static const redirectUri = 'https://agentportal.fiberx-systems.net/';
  static const scope = 'openid email profile';
}

/// إعدادات حساب وكيل فايبر اكس، تُحفظ كما FTTH/إيرثلنك: اسم المستخدم في
/// SharedPreferences وفي Firebase (agents/{uid}/fiberx)، وكلمة المرور في
/// التخزين الآمن على الجهاز فقط.
class FiberXSettings {
  const FiberXSettings({required this.username, required this.password});

  final String username;
  final String password;

  static const _usernameKey = 'fiberx_username';
  static const _passwordKey = 'fiberx_password';
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  static DatabaseReference? _remoteRef() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return uid == null
        ? null
        : FirebaseDatabase.instance.ref('agents/$uid/fiberx');
  }

  static Future<bool> _pullFromFirebase(SharedPreferences prefs) async {
    final ref = _remoteRef();
    if (ref == null) return true;
    final value = (await ref.get().timeout(const Duration(seconds: 5))).value;
    if (value is! Map) return false;
    final username = (value['username'] ?? '').toString().trim();
    if (username.isEmpty) return false;
    await prefs.setString(_usernameKey, username);
    final password = (value['password'] ?? '').toString();
    if (password.isNotEmpty && (await _loadLocal(prefs)).password.isEmpty) {
      await _storePassword(prefs, password);
    }
    return true;
  }

  static Future<void> _storePassword(
    SharedPreferences prefs,
    String password,
  ) async {
    try {
      await _secureStorage.write(key: _passwordKey, value: password);
      await prefs.remove(_passwordKey);
    } catch (_) {
      await prefs.setString(_passwordKey, password);
    }
  }

  static Future<FiberXSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    var foundRemote = true;
    try {
      foundRemote = await _pullFromFirebase(prefs);
    } catch (error) {
      debugPrint('[FiberX] settings pull failed: $error');
    }
    final settings = await _loadLocal(prefs);
    if (!foundRemote && settings.isComplete) await settings.save();
    return settings;
  }

  static Future<FiberXSettings> _loadLocal(SharedPreferences prefs) async {
    String password = '';
    try {
      password = await _secureStorage.read(key: _passwordKey) ?? '';
    } catch (_) {
      password = prefs.getString(_passwordKey) ?? '';
    }
    return FiberXSettings(
      username: prefs.getString(_usernameKey) ?? '',
      password: password,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_usernameKey, username.trim());
    await _storePassword(prefs, password);
    try {
      await _remoteRef()
          ?.update({
            'username': username.trim(),
            'updatedAt': ServerValue.timestamp,
          })
          .timeout(const Duration(seconds: 8));
    } catch (error) {
      debugPrint('[FiberX] settings save to Firebase failed: $error');
    }
  }

  bool get isComplete => username.trim().isNotEmpty && password.isNotEmpty;

  bool get needsPassword => username.trim().isNotEmpty && password.isEmpty;

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_usernameKey);
    await prefs.remove(_passwordKey);
    try {
      await _secureStorage.delete(key: _passwordKey);
    } catch (_) {}
    try {
      await _remoteRef()?.remove().timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  static const missingPasswordMessage =
      'أدخل كلمة مرور وكيل فايبر اكس على هذا الجهاز ثم احفظ. '
      'تُحفظ على الجهاز فقط.';
}

// ============================ دوال نقية (قابلة للاختبار) ============================

/// يولّد تحدّي PKCE (S256) من مُتحقِّق: base64url(sha256(verifier)) بلا حشو.
String pkceChallengeS256(String verifier) {
  final digest = sha256.convert(ascii.encode(verifier));
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}

/// مُتحقِّق PKCE عشوائي آمن (أحرف URL-safe، 43–128 محرفاً).
String generateCodeVerifier([Random? random]) {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  final rnd = random ?? Random.secure();
  return List.generate(64, (_) => chars[rnd.nextInt(chars.length)]).join();
}

/// جسم منحة كلمة المرور المباشرة (إن كان العميل يسمح بـ Direct Access Grants).
Map<String, String> fiberxPasswordGrantBody({
  required String username,
  required String password,
}) => {
  'grant_type': 'password',
  'client_id': FiberXEndpoints.clientId,
  'username': username,
  'password': password,
  'scope': FiberXEndpoints.scope,
};

/// جسم تبادل رمز التفويض (Authorization Code + PKCE) برمز وصول.
Map<String, String> fiberxAuthCodeTokenBody({
  required String code,
  required String codeVerifier,
}) => {
  'grant_type': 'authorization_code',
  'client_id': FiberXEndpoints.clientId,
  'code': code,
  'redirect_uri': FiberXEndpoints.redirectUri,
  'code_verifier': codeVerifier,
};

/// جسم تجديد الرمز عبر refresh_token.
Map<String, String> fiberxRefreshBody(String refreshToken) => {
  'grant_type': 'refresh_token',
  'client_id': FiberXEndpoints.clientId,
  'refresh_token': refreshToken,
};

/// يستخرج رابط إرسال نموذج دخول Keycloak من صفحة الدخول (action="...").
/// الرابط يحمل session_code/execution/tab_id اللازمة لإتمام المصادقة.
String? parseKeycloakFormAction(String html) {
  final m = RegExp(
    r'''<form[^>]*\bid=["']kc-form-login["'][^>]*\baction=["']([^"']+)["']''',
    caseSensitive: false,
  ).firstMatch(html);
  if (m != null) return _htmlUnescape(m.group(1)!);
  // بديل: أول نموذج يشير إلى login-actions/authenticate.
  final any = RegExp(
    r'''<form[^>]*\baction=["']([^"']*login-actions/authenticate[^"']*)["']''',
    caseSensitive: false,
  ).firstMatch(html);
  return any == null ? null : _htmlUnescape(any.group(1)!);
}

String _htmlUnescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&#x3D;', '=')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'");

/// يلتقط رمز التفويض من ترويسة Location بعد إرسال الاعتماد، سواء جاء في
/// الاستعلام (?code=) أو في الشظيّة (#code=).
String? extractAuthCode(String? location) {
  if (location == null || location.isEmpty) return null;
  final m = RegExp(r'[?#&]code=([^&]+)').firstMatch(location);
  if (m == null) return null;
  return Uri.decodeComponent(m.group(1)!);
}

/// مشترك فايبر اكس من صف /api/radius/users (JSON غني ونظيف).
class FiberXSubscriber {
  const FiberXSubscriber({
    required this.radiusUserId,
    required this.username,
    required this.name,
    required this.phone,
    required this.planName,
    required this.billingProfileId,
    required this.radiusProfileId,
    required this.balance,
    required this.expiration,
    required this.remainingDays,
    required this.enabled,
    required this.online,
  });

  final String radiusUserId; // id الرقمي (للعمليات)
  final String username; // br-xxxx
  final String name;
  final String phone;
  final String planName;
  final String billingProfileId;
  final String radiusProfileId;
  final double balance;
  final DateTime? expiration;
  final int remainingDays;
  final bool enabled;
  final bool online;

  static String _str(dynamic v) => '${v ?? ''}'.trim();
  static double _dbl(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}'.trim()) ?? 0;
  }

  static int _int(dynamic v) {
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}'.trim()) ?? 0;
  }

  static FiberXSubscriber fromJson(Map data) => FiberXSubscriber(
    radiusUserId: _str(data['id']),
    username: _str(data['username']),
    name: [
      _str(data['firstname']),
      _str(data['lastname']),
    ].where((e) => e.isNotEmpty).join(' ').trim(),
    phone: _str(data['phone']),
    planName: _str(data['profileBillingName'] ?? data['profileName']),
    billingProfileId: _str(data['profileBillingId'] ?? data['profileId']),
    radiusProfileId: _str(data['profileId']),
    balance: _dbl(data['balance']),
    expiration: DateTime.tryParse(_str(data['expiration']))?.toLocal(),
    remainingDays: _int(data['remainingDays']),
    enabled: data['enabled'] == true,
    online: _int(data['onlineStatus']) == 1,
  );
}

/// نتيجة ترقيم قائمة المشتركين.
class FiberXPage {
  const FiberXPage({required this.users, required this.totalPages});
  final List<FiberXSubscriber> users;
  final int totalPages;
}

/// يحلّل رد /api/radius/users: {data:[...], pagination:{totalPages}}.
FiberXPage parseFiberXUsers(dynamic json) {
  if (json is! Map) {
    throw const FiberXException('رد غير متوقع من فايبر اكس');
  }
  final rawData = json['data'];
  final users = <FiberXSubscriber>[];
  if (rawData is List) {
    for (final item in rawData) {
      if (item is Map) users.add(FiberXSubscriber.fromJson(item));
    }
  }
  final pagination = json['pagination'];
  final totalPages = pagination is Map
      ? FiberXSubscriber._int(pagination['totalPages'])
      : 1;
  return FiberXPage(users: users, totalPages: totalPages < 1 ? 1 : totalPages);
}

/// باقة (Billing Profile) من /api/billingprofile/my.
class FiberXPlan {
  const FiberXPlan({
    required this.billingProfileId,
    required this.radiusProfileId,
    required this.name,
    required this.price,
    required this.isActive,
  });

  final String billingProfileId;
  final String radiusProfileId;
  final String name;
  final double price;
  final bool isActive;
}

/// يحلّل قائمة الباقات (مصفوفة مباشرة أو {data:[...]}).
List<FiberXPlan> parseFiberXPlans(dynamic json) {
  final list = json is List
      ? json
      : (json is Map && json['data'] is List ? json['data'] as List : const []);
  final out = <FiberXPlan>[];
  for (final item in list) {
    if (item is! Map) continue;
    final active = item['isActive'] != false && item['isDeleted'] != true;
    out.add(
      FiberXPlan(
        billingProfileId: FiberXSubscriber._str(item['id']),
        radiusProfileId: FiberXSubscriber._str(item['radiusProfileId']),
        name: FiberXSubscriber._str(item['name']),
        price: FiberXSubscriber._dbl(item['price']),
        isActive: active,
      ),
    );
  }
  return out;
}

/// جسم عملية التفعيل/التجديد/تغيير الباقة إلى POST /api/RadiusActivation.
/// تغيير الباقة = تمرير billingProfileId/radiusProfileId مختلفين (الخادم
/// يكتشف التغيير تلقائياً مقارنةً بباقة المشترك الحالية).
Map<String, dynamic> fiberxActivationBody({
  required String radiusUserId,
  required String radiusProfileId,
  required String billingProfileId,
  required num amount,
  required int durationDays,
  required DateTime nextExpireDate,
  bool applyCashback = true,
}) => {
  'radiusUserId': int.tryParse(radiusUserId) ?? radiusUserId,
  'radiusProfileId': int.tryParse(radiusProfileId) ?? radiusProfileId,
  'billingProfileId': int.tryParse(billingProfileId) ?? billingProfileId,
  'amount': amount,
  'durationDays': durationDays,
  'type': 'Activation',
  'paymentMethod': 'Wallet',
  'source': 'Web',
  'isActionBehalf': false,
  'applyCashback': applyCashback,
  'nextExpireDate': nextExpireDate.toUtc().toIso8601String(),
};

/// نتيجة عملية مالية في فايبر اكس.
class FiberXActionResult {
  const FiberXActionResult({
    required this.success,
    required this.message,
    this.newExpiration,
    this.totalCharged,
  });
  final bool success;
  final String message;
  final DateTime? newExpiration;
  final num? totalCharged;
}

/// يحلّل رد /api/RadiusActivation (201). status=="completed" أو
/// currentExpireDate أحدث = نجاح.
FiberXActionResult parseActivationResult(dynamic json) {
  if (json is! Map) {
    return const FiberXActionResult(success: false, message: 'رد غير مقروء');
  }
  final status = '${json['status'] ?? ''}'.toLowerCase();
  final current = DateTime.tryParse('${json['currentExpireDate'] ?? ''}');
  final ok =
      status == 'completed' ||
      status == 'success' ||
      (status.isEmpty && current != null);
  if (ok) {
    return FiberXActionResult(
      success: true,
      message: 'تمت العملية بنجاح.',
      newExpiration: current?.toLocal(),
      totalCharged: json['totalCharged'] is num
          ? json['totalCharged'] as num
          : null,
    );
  }
  final msg = '${json['apiStatusMessage'] ?? json['notes'] ?? ''}'.trim();
  return FiberXActionResult(
    success: false,
    message: msg.isNotEmpty ? msg : 'لم تكتمل العملية (الحالة: $status).',
  );
}

// ============================ العميل ============================

/// عميل منصّة فايبر اكس. يسجّل الدخول عبر Keycloak (منحة كلمة المرور إن
/// سُمح بها، وإلا تدفّق الرمز+PKCE بلا متصفح) ثم يستدعي API برمز Bearer.
class FiberXService {
  FiberXService({
    required this.username,
    required this.password,
    http.Client? client,
  }) : _client = client ?? http.Client();

  FiberXService.fromSettings(FiberXSettings settings, {http.Client? client})
    : username = settings.username,
      password = settings.password,
      _client = client ?? http.Client();

  final String username;
  final String password;
  final http.Client _client;

  String? _accessToken;
  String? _refreshToken;
  DateTime? _expiresAt;

  // كوكيز Keycloak أثناء تدفّق الرمز (AUTH_SESSION_ID وغيرها).
  final Map<String, String> _kcCookies = {};

  bool get isAuthenticated => (_accessToken ?? '').isNotEmpty;

  void _log(String message) => debugPrint('[FiberX] $message');

  static const webUnsupportedMessage =
      'لوحة فايبر اكس لا تعمل من نسخة الويب. استخدم تطبيق أندرويد.';

  void _guardWeb() {
    if (kIsWeb) throw const FiberXException(webUnsupportedMessage);
  }

  Map<String, String> _apiHeaders() => {
    'Accept': 'application/json, text/plain, */*',
    'Authorization': 'Bearer ${_accessToken ?? ''}',
  };

  void _absorbCookies(http.BaseResponse response) {
    final raw = response.headers['set-cookie'];
    if (raw == null || raw.isEmpty) return;
    final parts = raw.split(RegExp(r',(?=\s*[A-Za-z0-9_.\-]+=)'));
    for (final part in parts) {
      final pair = part.split(';').first.trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      _kcCookies[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
    }
  }

  String? get _kcCookieHeader => _kcCookies.isEmpty
      ? null
      : _kcCookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  /// يسجّل الدخول: يجرّب منحة كلمة المرور المباشرة أولاً (أبسط)، وإن رفضها
  /// الخادم ينتقل إلى تدفّق رمز التفويض + PKCE بلا متصفح.
  Future<void> login() async {
    _guardWeb();
    if (password.isEmpty) {
      throw const FiberXException('أدخل كلمة مرور فايبر اكس.');
    }
    try {
      await _loginPasswordGrant();
      _log('login via password grant');
      return;
    } on FiberXException catch (e) {
      _log('password grant unavailable (${e.message}); trying code flow');
    }
    await _loginAuthCode();
    _log('login via authorization-code flow');
  }

  Future<void> _loginPasswordGrant() async {
    final response = await _client.post(
      Uri.parse(FiberXEndpoints.tokenUrl),
      headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
      body: fiberxPasswordGrantBody(username: username, password: password),
    );
    if (response.statusCode != 200) {
      throw FiberXException(
        'منحة كلمة المرور غير مسموحة',
        statusCode: response.statusCode,
      );
    }
    _storeTokens(_decode(response.body));
  }

  Future<void> _loginAuthCode() async {
    final verifier = generateCodeVerifier();
    final challenge = pkceChallengeS256(verifier);
    final state = generateCodeVerifier();

    // 1) صفحة دخول Keycloak: كوكيز الجلسة + رابط إرسال النموذج.
    final authUri = Uri.parse(FiberXEndpoints.authorizeUrl).replace(
      queryParameters: {
        'client_id': FiberXEndpoints.clientId,
        'redirect_uri': FiberXEndpoints.redirectUri,
        'response_type': 'code',
        'response_mode': 'query',
        'scope': FiberXEndpoints.scope,
        'state': state,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
      },
    );
    final loginGet = await _client.get(
      authUri,
      headers: const {'Accept': 'text/html,application/xhtml+xml,*/*'},
    );
    _absorbCookies(loginGet);
    if (loginGet.statusCode != 200) {
      throw FiberXException(
        'تعذّر فتح صفحة دخول فايبر اكس',
        statusCode: loginGet.statusCode,
      );
    }
    final action = parseKeycloakFormAction(loginGet.body);
    if (action == null) {
      throw const FiberXException(
        'تعذّر قراءة نموذج دخول فايبر اكس. حاول لاحقاً.',
      );
    }
    final actionUri = action.startsWith('http')
        ? Uri.parse(action)
        : Uri.parse(FiberXEndpoints.authRealm).resolve(action);

    // 2) إرسال الاعتماد دون متابعة التحويل، لالتقاط رمز التفويض من Location.
    final postReq = http.Request('POST', actionUri)
      ..followRedirects = false
      ..headers.addAll({
        'Content-Type': 'application/x-www-form-urlencoded',
        'Cookie': ?_kcCookieHeader,
      })
      ..bodyFields = {
        'username': username,
        'password': password,
        'credentialId': '',
      };
    final streamed = await _client.send(postReq);
    final postResp = await http.Response.fromStream(streamed);
    _absorbCookies(postResp);
    final location = postResp.headers['location'];
    final code = extractAuthCode(location);
    if (code == null) {
      _log('auth-code login failed: status=${postResp.statusCode}');
      throw const FiberXException(
        'فشل تسجيل الدخول إلى فايبر اكس: تحقق من اسم المستخدم وكلمة المرور.',
      );
    }

    // 3) تبادل الرمز برمز وصول.
    final tokenResp = await _client.post(
      Uri.parse(FiberXEndpoints.tokenUrl),
      headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
      body: fiberxAuthCodeTokenBody(code: code, codeVerifier: verifier),
    );
    if (tokenResp.statusCode != 200) {
      throw FiberXException(
        'تعذّر إصدار رمز الدخول',
        statusCode: tokenResp.statusCode,
      );
    }
    _storeTokens(_decode(tokenResp.body));
  }

  void _storeTokens(dynamic json) {
    if (json is! Map) {
      throw const FiberXException('رد مصادقة غير مقروء');
    }
    _accessToken = '${json['access_token'] ?? ''}';
    _refreshToken = '${json['refresh_token'] ?? ''}';
    final expiresIn = json['expires_in'] is num
        ? (json['expires_in'] as num).toInt()
        : 300;
    _expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
    if (_accessToken!.isEmpty) {
      throw const FiberXException('لم يصدر رمز الدخول');
    }
  }

  Future<void> _ensureToken() async {
    if (!isAuthenticated) {
      throw const FiberXException('غير مسجّل الدخول إلى فايبر اكس.');
    }
    final expiry = _expiresAt;
    final soon =
        expiry != null &&
        DateTime.now().isAfter(expiry.subtract(const Duration(seconds: 30)));
    if (soon && (_refreshToken ?? '').isNotEmpty) {
      try {
        final resp = await _client.post(
          Uri.parse(FiberXEndpoints.tokenUrl),
          headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
          body: fiberxRefreshBody(_refreshToken!),
        );
        if (resp.statusCode == 200) _storeTokens(_decode(resp.body));
      } catch (e) {
        _log('token refresh failed: $e');
      }
    }
  }

  dynamic _decode(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      throw const FiberXException('رد غير مقروء من فايبر اكس');
    }
  }

  Uri _api(String path, [Map<String, dynamic>? query]) {
    final clean = path.startsWith('/') ? path : '/$path';
    final q = query?.map((k, v) => MapEntry(k, '$v'));
    return Uri.parse('${FiberXEndpoints.apiBase}$clean')
        .replace(queryParameters: q);
  }

  /// صفحة واحدة من مشتركي الوكيل (مع بحث اختياري).
  Future<FiberXPage> _fetchPage(int page, {String? search}) async {
    await _ensureToken();
    final response = await _client.get(
      _api('/api/radius/users', {
        'page': page,
        'pageSize': _pageSize,
        'sortField': 'createdAt',
        'sortDirection': 'desc',
        'includeDeleted': false,
        if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
      }),
      headers: _apiHeaders(),
    );
    if (response.statusCode == 401) {
      throw const FiberXException('انتهت جلسة فايبر اكس. سجّل الدخول.');
    }
    if (response.statusCode != 200) {
      throw FiberXException(
        'تعذّر جلب مشتركي فايبر اكس',
        statusCode: response.statusCode,
      );
    }
    return parseFiberXUsers(_decode(response.body));
  }

  /// بحث عن مشتركين (الصفحة الأولى تكفي للعرض).
  Future<List<FiberXSubscriber>> searchSubscribers(String query) async {
    _guardWeb();
    final page = await _fetchPage(1, search: query);
    return page.users;
  }

  /// كل مشتركي الوكيل عبر كل الصفحات.
  static const _pageSize = 50;
  Future<List<FiberXSubscriber>> fetchSubscribers({int maxPages = 60}) async {
    _guardWeb();
    final byId = <String, FiberXSubscriber>{};
    final first = await _fetchPage(1);
    for (final u in first.users) {
      byId[u.radiusUserId] = u;
    }
    final lastPage = first.totalPages < maxPages ? first.totalPages : maxPages;
    for (var page = 2; page <= lastPage; page++) {
      final next = await _fetchPage(page);
      if (next.users.isEmpty) break;
      final before = byId.length;
      for (final u in next.users) {
        byId[u.radiusUserId] = u;
      }
      if (byId.length == before) break;
    }
    return byId.values.toList();
  }

  /// باقات الوكيل.
  Future<List<FiberXPlan>> fetchPlans() async {
    _guardWeb();
    await _ensureToken();
    final response = await _client.get(
      _api('/api/billingprofile/my'),
      headers: _apiHeaders(),
    );
    if (response.statusCode != 200) {
      throw FiberXException(
        'تعذّر جلب باقات فايبر اكس',
        statusCode: response.statusCode,
      );
    }
    return parseFiberXPlans(_decode(response.body)).where((p) => p.isActive).toList();
  }

  /// تفعيل/تجديد/تغيير باقة. durationDays يُحسب افتراضياً 30 يوماً، و
  /// nextExpireDate = (الانتهاء الحالي إن كان مستقبلاً وإلا الآن) + المدّة.
  Future<FiberXActionResult> activate({
    required FiberXSubscriber subscriber,
    required FiberXPlan plan,
    int durationDays = 30,
    num? amount,
    bool applyCashback = true,
  }) async {
    _guardWeb();
    await _ensureToken();
    final now = DateTime.now();
    final base = (subscriber.expiration != null && subscriber.expiration!.isAfter(now))
        ? subscriber.expiration!
        : now;
    final nextExpire = base.add(Duration(days: durationDays));
    final response = await _client.post(
      _api('/api/RadiusActivation'),
      headers: {..._apiHeaders(), 'Content-Type': 'application/json'},
      body: jsonEncode(
        fiberxActivationBody(
          radiusUserId: subscriber.radiusUserId,
          radiusProfileId: plan.radiusProfileId.isNotEmpty
              ? plan.radiusProfileId
              : subscriber.radiusProfileId,
          billingProfileId: plan.billingProfileId,
          amount: amount ?? plan.price,
          durationDays: durationDays,
          nextExpireDate: nextExpire,
          applyCashback: applyCashback,
        ),
      ),
    );
    if (response.statusCode == 401) {
      throw const FiberXException('انتهت جلسة فايبر اكس. سجّل الدخول.');
    }
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw FiberXException(
        'فشل اتصال العملية',
        statusCode: response.statusCode,
      );
    }
    return parseActivationResult(_decode(response.body));
  }

  /// مزامنة مشتركي فايبر اكس المحفوظين إلى قائمة التطبيق (نمط FTTH/إيرثلنك).
  static Future<int?> syncSaved() async {
    final settings = await FiberXSettings.load();
    if (!settings.isComplete) return null;
    final service = FiberXService.fromSettings(settings);
    try {
      await service.login();
      final users = await service.fetchSubscribers();
      return await service.syncSubscribers(users);
    } finally {
      service.dispose();
    }
  }

  /// يكتب/يحدّث مشتركي فايبر اكس في AppStore (source=fiberx، المطابقة على uid).
  Future<int> syncSubscribers(List<FiberXSubscriber> users) async {
    await TrialGuardService.ensureFiberxAllowed(username);
    var changed = 0;
    for (final u in users) {
      final end = u.expiration ?? DateTime.now();
      final sasData = <String, dynamic>{
        'provider': 'فايبر اكس',
        'fiberx_uid': u.radiusUserId,
        'username': u.username,
        'plan': u.planName,
        'billingProfileId': u.billingProfileId,
        'radiusProfileId': u.radiusProfileId,
        'expiration': u.expiration?.toIso8601String() ?? '',
      };
      final index = AppStore.subscribers.indexWhere(
        (item) => item.source == 'fiberx' && item.sasId == u.radiusUserId,
      );
      if (index < 0) {
        AppStore.subscribers.add(
          Subscriber(
            user: u.username.isNotEmpty ? u.username : u.radiusUserId,
            name: u.name.isNotEmpty ? u.name : u.username,
            phone: u.phone,
            address: '',
            ip: '',
            type: u.planName,
            price: 0,
            startDate: end,
            endDate: end,
            active: u.enabled,
            source: 'fiberx',
            sasId: u.radiusUserId,
            sasOnline: u.online,
            sasData: sasData,
          ),
        );
        changed++;
      } else {
        AppStore.subscribers[index]
          ..name = u.name.isNotEmpty ? u.name : u.username
          ..phone = u.phone
          ..type = u.planName
          ..endDate = end
          ..active = u.enabled
          ..sasOnline = u.online
          ..sasData = sasData;
        changed++;
      }
    }
    await AppStore.save();
    _log('sync complete: $changed subscribers');
    return changed;
  }

  void dispose() => _client.close();
}
