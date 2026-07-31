import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'sas_http_overrides.dart'
    if (dart.library.io) 'sas_http_overrides_io.dart';

class SasSettings {
  static const _serverKey = 'sas_server_url';
  static const _userKey = 'sas_manager_username';
  static const _passKey = 'sas_manager_password';
  static const _securePassKey = 'sas_manager_password_sec';
  static const _proxyKey = 'sas_web_proxy_url';
  static const _proxyEnv = String.fromEnvironment(
    'SAS_WEB_PROXY_URL',
    defaultValue: '',
  );

  String serverUrl;
  String username;
  String password;
  String webProxyUrl;

  SasSettings({
    required this.serverUrl,
    required this.username,
    required this.password,
    this.webProxyUrl = '',
  });

  static String _normalizeServerUrl(String value) {
    var s = value.trim();
    while (s.startsWith('/')) {
      s = s.substring(1).trim();
    }
    if (s.isEmpty) return '';
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'https://$s';
    }
    final uri = Uri.parse(s);
    final host = uri.host.toLowerCase();
    if (host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host.endsWith('.localhost')) {
      return '';
    }
    if (s.startsWith('http://')) {
      // Production SAS traffic must be HTTPS. If a user enters a bare host or
      // an http:// URL, normalize it to HTTPS instead of silently sending
      // credentials over an insecure channel.
      s = 'https://${s.substring('http://'.length)}';
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static String _normalizeProxyUrl(String value) {
    var s = value.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.isEmpty) return '';
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'https://$s';
    }
    return s;
  }

  static String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  /// جلب إعدادات SAS من Firebase RTDB
  static Future<void> _pullSasFromFirebase() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      dynamic data;

      bool hasNonEmpty(dynamic map, String key) {
        if (map is! Map) return false;
        final v = map[key];
        return v != null && v.toString().trim().isNotEmpty;
      }

      // المسار القديم: agents/{uid}/sas
      final legacySnapshot = await FirebaseDatabase.instance
          .ref('agents/$uid/sas')
          .get()
          .timeout(const Duration(seconds: 8));
      data = legacySnapshot.value;

      // المسار الحالي: agents/{uid}_{sasUsername}/sas
      // إذا كان المسار القديم يحتوي قيماً فارغة (placeholders) فلا نعتبره صالحاً.
      // نقرأ currentAgentId أو sasUsername من profile ثم نحاول المسار الجديد.
      final legacyValid = hasNonEmpty(data, 'serverUrl') && hasNonEmpty(data, 'username');
      if (!legacyValid) {
        final profileSnapshot = await FirebaseDatabase.instance
            .ref('agents/$uid/profile')
            .get()
            .timeout(const Duration(seconds: 5));
        final profileData = profileSnapshot.value;
        if (profileData is Map) {
          final currentAgentId = (profileData['currentAgentId'] ?? '').toString().trim();
          final sasUsername = (profileData['sasUsername'] ?? '').toString().trim();
          if (currentAgentId.isNotEmpty) {
            final currentSnapshot = await FirebaseDatabase.instance
                .ref('agents/$currentAgentId/sas')
                .get()
                .timeout(const Duration(seconds: 8));
            data = currentSnapshot.value;
          } else if (sasUsername.isNotEmpty) {
            final currentSnapshot = await FirebaseDatabase.instance
                .ref('agents/${uid}_$sasUsername/sas')
                .get()
                .timeout(const Duration(seconds: 8));
            data = currentSnapshot.value;
          }
        }
      }

      if (data is! Map) return;
      final sasData = Map<String, dynamic>.from(data);

      final p = await SharedPreferences.getInstance();

      if (sasData['serverUrl'] != null) {
        await p.setString(_serverKey, _normalizeServerUrl(sasData['serverUrl'].toString()));
      }
      if (sasData['username'] != null) {
        await p.setString(_userKey, sasData['username'].toString());
      }
      final proxyCandidate =
          sasData['webProxyUrl'] ?? sasData['proxyUrl'] ?? sasData['renderProxyUrl'];
      if (proxyCandidate != null && proxyCandidate.toString().trim().isNotEmpty) {
        await p.setString(_proxyKey, _normalizeProxyUrl(proxyCandidate.toString()));
      }
      if (sasData['password'] != null && sasData['password'].toString().isNotEmpty) {
        try {
          await SasApiService._secureStorage.write(
            key: _securePassKey,
            value: sasData['password'].toString(),
          );
        } catch (_) {
          await p.setString(_passKey, sasData['password'].toString());
        }
      }
      debugPrint('SAS settings pulled from Firebase successfully');
    } catch (e) {
      debugPrint('SAS Firebase pull failed: $e');
    }
  }

  static Future<SasSettings> load() async {
    final p = await SharedPreferences.getInstance();

    // نحاول نجلب من Firebase أولاً
    try {
      await _pullSasFromFirebase().timeout(const Duration(seconds: 5));
    } catch (_) {}

    final proxyFromPrefs = [
      p.getString(_proxyKey),
      p.getString('web_proxy_url'),
      p.getString('proxy_url'),
      p.getString('render_proxy_url'),
    ].firstWhere(
      (v) => v != null && v.trim().isNotEmpty,
      orElse: () => null,
    );

    return SasSettings(
      serverUrl: p.getString(_serverKey)?.trim().isNotEmpty == true
          ? _normalizeServerUrl(p.getString(_serverKey)!)
          : '',
      username: p.getString(_userKey)?.trim().isNotEmpty == true
          ? p.getString(_userKey)!.trim()
          : 'يوزر الساس',
      password: await _loadPassword(p),
      webProxyUrl: proxyFromPrefs != null && proxyFromPrefs.trim().isNotEmpty
          ? _normalizeProxyUrl(proxyFromPrefs)
          : _normalizeProxyUrl(_proxyEnv),
    );
  }

  Future<void> save() async {
    final cleanedServerUrl = _normalizeServerUrl(serverUrl);
    if (cleanedServerUrl.isEmpty) {
      throw SasApiException('عنوان SAS لا يمكن أن يكون فارغاً');
    }
    final p = await SharedPreferences.getInstance();
    await p.setString(_serverKey, cleanedServerUrl);
    await p.setString(_userKey, username.trim());
    final cleanedProxyUrl = _normalizeProxyUrl(webProxyUrl);
    if (cleanedProxyUrl.isNotEmpty) {
      await p.setString(_proxyKey, cleanedProxyUrl);
      await p.setString('web_proxy_url', cleanedProxyUrl);
      await p.setString('proxy_url', cleanedProxyUrl);
      await p.setString('render_proxy_url', cleanedProxyUrl);
    } else {
      await p.remove(_proxyKey);
      await p.remove('web_proxy_url');
      await p.remove('proxy_url');
      await p.remove('render_proxy_url');
    }
    // store password in secure storage if available
    try {
      await SasApiService._secureStorage.write(key: _securePassKey, value: password);
    } catch (_) {
      // fallback to SharedPreferences if secure storage unavailable
      await p.setString(_passKey, password);
    }

    // حفظ في Firebase RTDB
    if (_uid != null) {
      try {
        final emailKey = (FirebaseAuth.instance.currentUser?.email ?? '')
            .trim()
            .toLowerCase();
        final normalizedSasUser = username.trim();
        final agentKey = emailKey.isNotEmpty
            ? '${emailKey}__${normalizedSasUser.toLowerCase()}'
            : normalizedSasUser.toLowerCase();

        // المعرف الجديد: uid_sasUsername
        final agentId = '${_uid}_$normalizedSasUser';
        final agentRef = FirebaseDatabase.instance.ref('agents/$agentId');
        final sasRef = agentRef.child('sas');
        await sasRef.set({
          'serverUrl': cleanedServerUrl,
          'username': normalizedSasUser,
          'password': password,
          if (cleanedProxyUrl.isNotEmpty) 'webProxyUrl': cleanedProxyUrl,
        }).timeout(const Duration(seconds: 8));
        
        await agentRef.child('profile').update({
          'email': emailKey,
          'emailKey': emailKey,
          'sasUsername': normalizedSasUser,
          'agentKey': agentKey,
          'status': 'active',
        }).timeout(const Duration(seconds: 5));

        // اترك مؤشراً في مسار uid القديم حتى يتمكن تسجيل الدخول التالي من
        // اكتشاف agentId المركب ثم تحميل الإعدادات والبيانات من المسار الصحيح.
        await FirebaseDatabase.instance.ref('agents/$_uid/profile').update({
          'email': emailKey,
          'emailKey': emailKey,
          'sasUsername': normalizedSasUser,
          'agentKey': agentKey,
          'currentAgentId': agentId,
          'status': 'active',
        }).timeout(const Duration(seconds: 5));
        
        // حذف بيانات SAS القديمة فقط بعد ترك المؤشر أعلاه.
        try {
          await FirebaseDatabase.instance.ref('agents/$_uid/sas').remove().timeout(const Duration(seconds: 3));
        } catch (_) {}
        
        debugPrint('SAS settings saved to Firebase with agentId=$agentId');
      } catch (e) {
        debugPrint('Failed to save SAS to Firebase: $e');
      }
    }
  }

  static Future<String> _loadPassword(SharedPreferences p) async {
    try {
      final v = await SasApiService._secureStorage.read(key: _securePassKey);
      if (v != null && v.isNotEmpty) return v;
    } catch (_) {
      // ignore and fallback
    }
    // Do NOT ship a hard-coded default password. Return empty string if none.
    return p.getString(_passKey) ?? '';
  }
}

class SasApiException implements Exception {
  final String message;
  SasApiException(this.message);
  @override
  String toString() => message;
}

class SasApiService {
  // Web builds must use the deployed HTTPS proxy. The value comes from
  // SAS_WEB_PROXY_URL or from persisted app settings; it is intentionally not
  // hard-coded to localhost.
  static const String _webProxyBaseRaw = String.fromEnvironment(
    'SAS_WEB_PROXY_URL',
    defaultValue: 'https://ha-0cs7.onrender.com',
  );
  static const bool _useProxyOnWeb = bool.fromEnvironment(
    'SAS_USE_PROXY',
    defaultValue: true,
  );
  static const String _proxyToken = String.fromEnvironment(
    'SAS_PROXY_TOKEN',
    defaultValue: '',
  );
  static final Map<int, List<Map<String, dynamic>>> _extensionCache = {};
  static final Map<int, DateTime> _extensionCacheAt = {};

  static const _passphrase = 'abcdefghijuklmno0123456789012345';
  final SasSettings settings;
  String? _token;
  // true after proxy returns a 403 from upstream — switch to direct for this session
  bool _directFallback = false;
  final Map<int, dynamic> _profileCache = {};
  static final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  SasApiService(this.settings) {
    if (kDebugMode) {
      configureSasHttpOverrides(allowBadCertificates: true);
    }
  }

  String get _webProxyBase {
    var proxy = settings.webProxyUrl.trim().isNotEmpty
        ? settings.webProxyUrl.trim()
        : _webProxyBaseRaw.trim();
    while (proxy.endsWith('/')) {
      proxy = proxy.substring(0, proxy.length - 1);
    }
    if (proxy.isEmpty) {
      throw SasApiException(
        'رابط بروكسي Render غير محدد. شغّل التطبيق مع '
        '--dart-define=SAS_WEB_PROXY_URL=https://YOUR-PROXY.onrender.com '
        'أو احفظ الرابط في إعدادات التطبيق.',
      );
    }
    if (!proxy.startsWith('http://') && !proxy.startsWith('https://')) {
      proxy = 'https://$proxy';
    }
    final uri = Uri.parse(proxy);
    final host = uri.host.toLowerCase();
    if (host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host.endsWith('.localhost')) {
      throw SasApiException('رابط البروكسي المحلي غير مسموح. استخدم بروكسي Render عبر HTTPS.');
    }
    if (uri.scheme != 'https') {
      throw SasApiException('رابط البروكسي يجب أن يستخدم HTTPS: $proxy');
    }
    return proxy;
  }

  String get _sasInputNormalized {
    return SasSettings._normalizeServerUrl(settings.serverUrl);
  }

  String get _sasOrigin {
    final uri = Uri.parse(_sasInputNormalized);
    final path = uri.path.isNotEmpty && uri.path != '/' ? uri.path : '';
    return '${uri.scheme}://${uri.authority}$path';
  }

  String get _sasApiBase {
    final inputUri = Uri.parse(_sasInputNormalized);
    var path = inputUri.path;

    if (path.isEmpty || path == '/') {
      return '$_sasOrigin/admin/api/index.php/api/';
    }

    path = path.replaceAll(RegExp(r'/+$'), '');
    final lowerPath = path.toLowerCase();
    final standardMatch = RegExp(r'(/admin)?/api/index\.php/api', caseSensitive: false).firstMatch(path);
    if (standardMatch != null) {
      final canonicalBase = lowerPath.contains('/admin/api/index.php/api')
          ? '/admin/api/index.php/api'
          : '/api/index.php/api';
      return '$_sasOrigin$canonicalBase/';
    }

    // If a full endpoint is pasted, strip common action suffixes.
    path = path.replaceAll(RegExp(r'/(login|auth)$', caseSensitive: false), '');

    if (!path.toLowerCase().contains('/api/')) {
      return '$_sasOrigin/admin/api/index.php/api/';
    }

    return '$_sasOrigin${path.endsWith('/') ? path : '$path/'}';
  }

  String get _base {
    if (kIsWeb) {
      if (useDirectConnection || _directFallback) {
        return _sasApiBase;
      }

      final webProxyBase = _webProxyBase;
      final sasPath = Uri.parse(_sasApiBase).path;
      final cleanSasPath = sasPath.endsWith('/') ? sasPath.substring(0, sasPath.length - 1) : sasPath;
      final proxyUrl = '$webProxyBase/sas$cleanSasPath';
      debugPrint('Proxy base URL: $proxyUrl');
      return proxyUrl;
    }
    return _sasApiBase;
  }

  /// Check if direct connection should be used
  static bool get useDirectConnection {
    return kIsWeb ? !_useProxyOnWeb : true;
  }

  /// Check if the web proxy is reachable
  Future<bool> checkProxyHealth() async {
    if (!kIsWeb) return true;
    
    // If direct connection is enabled, skip proxy check
    if (useDirectConnection) {
      debugPrint('Direct connection enabled, skipping proxy health check');
      return true;
    }
    
    final proxyBase = _webProxyBase;
    
    try {
      debugPrint('Checking proxy health: $proxyBase/health');
      final response = await http.get(
        Uri.parse('$proxyBase/health'),
      ).timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200) {
        debugPrint('Proxy health check passed: $proxyBase');
        return true;
      } else {
        debugPrint('Proxy health check failed with status: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Proxy health check failed: $e');
    }
    
    return false;
  }

  Uri _uriFor(String route) {
    final base = _base;
    // Ensure route starts with / and doesn't have double slashes
    final cleanRoute = route.startsWith('/') ? route : '/$route';
    // Remove any double slashes that might occur
    final cleanBase = base.endsWith('/')
    ? base.substring(0, base.length - 1)
    : base;
    final uri = Uri.parse('$cleanBase$cleanRoute');
    debugPrint('Full URI: $uri');
    return uri;
  }

  void _addProxyTarget(Map<String, String> headers) {
    if (kIsWeb && !useDirectConnection && !_directFallback) {
      headers['X-SAS-Target'] = _sasOrigin.isNotEmpty ? _sasOrigin : _sasInputNormalized;
      if (_proxyToken.trim().isNotEmpty) {
        headers['X-Proxy-Token'] = _proxyToken.trim();
      }
    }
  }

  String _newSessionId() {
    final random = Random.secure();
    String hex(int length) => List.generate(
          length,
          (_) => random.nextInt(16).toRadixString(16),
        ).join();
    return '${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}';
  }

  Future<void> login() async {
    final username = settings.username.trim();
    final password = settings.password;

    dynamic data;
    Object? firstError;

    try {
      data = await _post('login', {
        'username': username,
        'password': password,
      }, authenticated: false);
    } catch (e) {
      firstError = e;
      // إذا رفض البروكسي الطلب (403 من السيرفر العلوي) انتقل للاتصال المباشر
      if (kIsWeb && !_directFallback && _isProxyBlockedError(e)) {
        debugPrint('Proxy blocked by SAS upstream (403), retrying direct');
        _directFallback = true;
        _token = null;
        try {
          data = await _post('login', {'username': username, 'password': password}, authenticated: false);
          firstError = null;
        } catch (e2) {
          firstError = e2;
        }
      }
    }

    // بعض أنظمة SAS (مثل JT) ترسل language و session_id مع تسجيل الدخول.
    // نجرب هذه الصيغة فقط إذا لم تنجح الطريقة الأساسية.
    if (data is! Map || data['token'] == null) {
      try {
        data = await _post('login', {
          'username': username,
          'password': password,
          'language': 'en',
          'session_id': _newSessionId(),
        }, authenticated: false);
      } catch (e) {
        if (firstError != null) {
          throw SasApiException(
            'فشل تسجيل الدخول بالطريقتين: $firstError | $e',
          );
        }
        rethrow;
      }
    }

    if (data is! Map || data['token'] == null) {
      throw SasApiException('تم الاتصال لكن لم يرجع SAS رمز دخول Token');
    }

    _token = data['token'].toString();
  }

  /// يكتشف إذا كان الخطأ ناتجاً عن رفض السيرفر العلوي للبروكسي (403)
  static bool _isProxyBlockedError(Object e) {
    final msg = e.toString();
    return msg.contains('403') &&
        (msg.contains('upstream returned HTML') || msg.contains('Forbidden') || msg.contains('HTML error'));
  }

  Future<dynamic> fetchUsers() async {
    if (_token == null) await login();

    final all = <Map<String, dynamic>>[];
    final seenUsers = <String>{};
    final seenPages = <String>{};
    const pageSize = 25;

    for (var page = 1; page <= 200; page++) {
      dynamic response;
      Object? lastError;

      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          response = await _post('index/user', {
            'page': page,
            'current': page,
            'page_no': page,
            'start': (page - 1) * pageSize,
            'offset': (page - 1) * pageSize,
            'limit': pageSize,
            'length': pageSize,
            'per_page': pageSize,
            'page_size': pageSize,
          });
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          if (attempt < 3) {
            await Future.delayed(Duration(seconds: attempt));
          }
        }
      }

      if (lastError != null) throw lastError;
      final rows = _extractRows(response);
      if (rows.isEmpty) break;

      final firstProfileName = rows.isNotEmpty
          ? (rows.first['profile_name'] ?? rows.first['profile'] ?? rows.first['package_name'] ?? rows.first['package'] ?? '').toString()
          : 'none';
      debugPrint('SAS fetchUsers row0 profile_name=$firstProfileName');

      // بصمة الصفحة تمنع الدوران إذا تجاهل SAS رقم الصفحة وأعاد نفس البيانات.
      final pageFingerprint = rows.map((row) {
        return (row['id'] ??
                row['user_id'] ??
                row['uid'] ??
                row['username'] ??
                row['user'] ??
                row)
            .toString();
      }).join('|');
      if (!seenPages.add(pageFingerprint)) break;

      var addedThisPage = 0;
      for (final row in rows) {
        final key = (row['id'] ??
                row['user_id'] ??
                row['uid'] ??
                row['username'] ??
                row['user'] ??
                row)
            .toString();
        if (seenUsers.add(key)) {
          all.add(row);
          debugPrint('USER JSON = $row');
          addedThisPage++;
        }
      }

      if (addedThisPage == 0) break;

      // لا نفترض حجم صفحة SAS؛ بعض السيرفرات ترجع 10 فقط حتى لو طلبنا 25.
      // نستمر إلى أن ترجع صفحة فارغة أو تتكرر نفس الصفحة.
      // بدون تأخير صناعي بين الصفحات؛ سرعة الجلب تعتمد على SAS نفسه.
    }

    return all;
  }

  Future<dynamic> createUser({
    required String username,
    required String password,
    required int profileId,
    required int parentId,
    required String firstName,
    required String lastName,
  }) async {
    if (_token == null) await login();
    return _post('user', {
      'username': username.trim(),
      'password': password,
      'confirm_password': password,
      'profile_id': profileId,
      'parent_id': parentId,
      'firstname': firstName.trim(),
      'lastname': lastName.trim(),
    });
  }

  Future<dynamic> updateUser({
    required String userId,
    required Map<String, dynamic> currentData,
    required String username,
    required String fullName,
    required String phone,
    required String address,
    required String ip,
  }) async {
    if (_token == null) await login();

    // نبدأ من بيانات SAS الخام نفسها حتى لا نسقط حقولاً مطلوبة من الخادم.
    final payload = Map<String, dynamic>.from(currentData);
    final parts = fullName.trim().split(RegExp(r'\s+'));
    final firstName = parts.isEmpty ? fullName.trim() : parts.first;
    final lastName = parts.length > 1 ? parts.sublist(1).join(' ') : '-';

    void setExistingOr(String preferred, List<String> alternatives, dynamic value) {
      String? target;
      if (payload.containsKey(preferred)) {
        target = preferred;
      } else {
        for (final key in alternatives) {
          if (payload.containsKey(key)) {
            target = key;
            break;
          }
        }
      }
      payload[target ?? preferred] = value;
    }

    setExistingOr('username', ['user', 'user_name', 'login'], username.trim());
    setExistingOr('firstname', ['first_name'], firstName);
    setExistingOr('lastname', ['last_name'], lastName);
    if (phone.trim().isNotEmpty) {
      setExistingOr('phone', ['mobile', 'phone_number', 'mobile_number'], phone.trim());
    }
    if (address.trim().isNotEmpty) {
      setExistingOr('address', ['location'], address.trim());
    }
    if (ip.trim().isNotEmpty) {
      setExistingOr('ip', ['ip_address', 'static_ip', 'framed_ip_address'], ip.trim());
    }

    return _put('user/$userId', payload);
  }

  Future<dynamic> disableUsers(List<int> userIds) async {
    if (userIds.isEmpty) {
      throw SasApiException('لم يتم تحديد أي مشترك للتعطيل');
    }
    if (_token == null) await login();

    // SAS real request:
    // POST /api/user/disable
    // encrypted body before encryption: {"user_ids":[...]}
    return _post('user/disable', {
      'user_ids': userIds,
    });
  }

  Future<dynamic> disableUser(int userId) {
    return disableUsers([userId]);
  }

  Future<dynamic> enableUsers(List<int> userIds) async {
    if (userIds.isEmpty) {
      throw SasApiException('لم يتم تحديد أي مشترك لإلغاء التعطيل');
    }
    if (_token == null) await login();

    // SAS counterpart of /user/disable.
    return _post('user/enable', {
      'user_ids': userIds,
    });
  }

  Future<dynamic> enableUser(int userId) {
    return enableUsers([userId]);
  }

    Future<dynamic> extendUser({
    required int userId,
    required int profileId,
    required String transactionId,
    String method = 'reward_points',
  }) async {
    if (_token == null) await login();

    // HAR الحقيقي يجلب تفاصيل Extension المختار قبل التنفيذ:
    // GET /api/profile/{profileId}
    await fetchProfileDetails(profileId);

    // ثم POST /api/user/extend
    final response = await _post('user/extend', {
      'user_id': userId,
      'profile_id': profileId,
      'method': method,
      'transaction_id': transactionId,
    });

    if (response is Map) {
      final status = response['status'];
      final success = response['success'];
      final message = (response['message'] ??
              response['msg'] ??
              response['error'] ??
              response['errors'] ??
              '')
          .toString();
      final low = message.toLowerCase();

      if (success == false ||
          status == false ||
          status == -1 ||
          status == '-1' ||
          status == 0 ||
          status == '0' ||
          (status is num && status >= 400) ||
          low.contains('fail') ||
          low.contains('error')) {
        if (low.contains('insufficient_balance') ||
            low.contains('insufficient balance')) {
          throw SasApiException('الرصيد غير كافٍ');
        }
        throw SasApiException(
          message.trim().isEmpty ? 'رفض SAS عملية التمديد' : message,
        );
      }
    }

    return response;
  }

  Future<dynamic> changeUserProfile({
    required int userId,
    required int profileId,
    String changeType = 'immediate',
  }) async {
    if (_token == null) await login();

    // HAR الحقيقي:
    // POST /api/user/changeProfile
    // {user_id, profile_id, change_type: immediate}
    final response = await _post('user/changeProfile', {
      'user_id': userId,
      'profile_id': profileId,
      'change_type': changeType,
    });

    if (response is Map) {
      final status = response['status'];
      final success = response['success'];
      final message = (response['message'] ??
              response['msg'] ??
              response['error'] ??
              '')
          .toString();
      final low = message.toLowerCase();

      if (success == false ||
          status == false ||
          status == -1 ||
          status == '-1' ||
          status == 0 ||
          status == '0' ||
          (status is num && status >= 400) ||
          low.contains('fail') ||
          low.contains('error')) {
        throw SasApiException(
          message.trim().isEmpty ? 'رفض SAS تغيير الباقة' : message,
        );
      }
    }
    return response;
  }

  dynamic _unwrapSasData(dynamic value) {
    dynamic v = value;
    for (var i = 0; i < 3; i++) {
      if (v is Map && v['data'] != null) {
        v = v['data'];
      } else {
        break;
      }
    }
    return v;
  }

  dynamic _firstDeep(dynamic node, List<String> keys) {
    if (node is Map) {
      for (final key in keys) {
        if (node[key] != null) return node[key];
      }
      for (final value in node.values) {
        final found = _firstDeep(value, keys);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final value in node) {
        final found = _firstDeep(value, keys);
        if (found != null) return found;
      }
    }
    return null;
  }

  num? _asNum(dynamic v) {
    if (v is num) return v;
    return num.tryParse((v ?? '').toString().replaceAll(',', '').trim());
  }

  Future<dynamic> activateUser(
    int userId, {
    String? notifyPhone,
    String? notifyMessage,
  }) async {
    if (_token == null) await login();

    // v095 متعدد الشركات:
    // المصدر الأساسي دائماً هو activationData من نفس SAS المتصل حالياً.
    final rawActivation = await _get('user/activationData/$userId');
    final activation = _unwrapSasData(rawActivation);

    final profileId = int.tryParse(
      (_firstDeep(activation, ['profile_id', 'profileId']) ?? '').toString(),
    );

    // نجلب profile من نفس الشركة إذا توفر، ولا نفشل العملية إن لم يتوفر.
    dynamic profile;
    if (profileId != null) {
      try {
        profile = await _get('profile/$profileId');
      } catch (_) {}
    }

    // اكتشاف طريقة الدفع من رد الشركة نفسها.
    final explicitMethod = _firstDeep(activation, [
      'method',
      'activation_method',
      'payment_method',
      'pay_method',
      'default_method',
    ]);

    final rewardPoints = _asNum(_firstDeep(activation, [
      'reward_points',
      'points',
      'available_points',
    ]));

    final requiredPoints = _asNum(_firstDeep(activation, [
      'required_points',
      'points_required',
    ]));

    String method;
    if (explicitMethod != null && explicitMethod.toString().trim().isNotEmpty) {
      method = explicitMethod.toString().trim();
    } else if (requiredPoints != null &&
        rewardPoints != null &&
        rewardPoints >= requiredPoints) {
      method = 'reward_points';
    } else {
      // SAS Radius الشائع وحساب SpeedNet الحقيقي.
      method = 'credit';
    }

    final price = _asNum(_firstDeep(activation, [
          'user_price',
          'price',
          'unit_price',
          'amount',
          'total',
          'required_amount',
        ])) ??
        _asNum(_firstDeep(profile, [
          'user_price',
          'price',
          'unit_price',
          'amount',
        ]));

    final units = _asNum(_firstDeep(activation, [
          'activation_units',
          'units',
          'unit',
          'months',
        ])) ??
        1;

    final issueInvoiceRaw = _firstDeep(activation, [
      'issue_invoice',
      'invoice',
      'create_invoice',
    ]);

    dynamic issueInvoice = issueInvoiceRaw;
    issueInvoice ??= 0;

    final tx = '${DateTime.now().microsecondsSinceEpoch}-$userId';

    // Payload مرن: الحقول الأساسية + حقول SAS الحديثة.
    // السيرفر المتصل هو الذي يقرر القيم من activationData.
    final payload = <String, dynamic>{
      'method': method,
      'user_id': userId,
      'issue_invoice': issueInvoice,
      'transaction_id': tx,
    };

    if (method == 'credit') {
      payload['pin'] = '';
      payload['money_collected'] =
          _asNum(_firstDeep(activation, ['money_collected'])) ?? 1;
      if (price != null) payload['user_price'] = price;
      payload['activation_units'] = units;
    } else {
      payload['units'] = units;
    }

    final response = await _post(
      'user/activate',
      payload,
    );

    if (response is Map) {
      final status = response['status'];
      final success = response['success'];
      final message = (response['message'] ??
              response['msg'] ??
              response['error'] ??
              response['errors'] ??
              '')
          .toString();
      final text = message.toLowerCase();

      final explicitFailure =
          success == false ||
          status == false ||
          status == -1 ||
          status == '-1' ||
          status == 0 ||
          status == '0' ||
          (status is num && status >= 400) ||
          text.contains('fail') ||
          text.contains('error');

      if (explicitFailure) {
        throw SasApiException(
          message.trim().isEmpty ? 'رفض SAS عملية التفعيل' : message,
        );
      }
    }
    return response;
  }

  Future<dynamic> fetchProfileDetails(int profileId) async {
  if (_profileCache.containsKey(profileId)) {
    return _profileCache[profileId];
  }

  if (_token == null) await login();

  final result = await _get('profile/$profileId');

  _profileCache[profileId] = result;

  debugPrint('PROFILE RESULT TYPE: ${result.runtimeType}');
  debugPrint('PROFILE RESULT: $result');

  return result;
}

  Future<Map<String, dynamic>> fetchDashboardWidgets() async {
    if (_token == null) await login();

    // Endpoints confirmed from the uploaded HAR.
    const widgets = <String, String>{
      'users_count': 'wd_users_count',
      'users_active_count': 'wd_users_active_count',
      'users_online': 'wd_users_online',
      'users_expired_count': 'wd_users_expired_count',
      'users_expiring_in_3_days': 'wd_users_expiring_in_3_days',
      'balance': 'wd_balance',
      'reward_points': 'wd_reward_points',
      'outstanding_debts': 'wd_outstanding_debts',
      'users_expiring_today': 'wd_users_expiring_today',
    };

    final result = <String, dynamic>{};

    // Parallel requests: much faster than waiting one-by-one.
    final entries = await Future.wait(
      widgets.entries.map((e) async {
        try {
          final value = await _get('widgetData/internal/${e.value}');
          return MapEntry<String, dynamic>(e.key, value);
        } catch (_) {
          return MapEntry<String, dynamic>(e.key, null);
        }
      }),
    );

    for (final e in entries) {
      result[e.key] = e.value;
    }
    return result;
  }

  Future<dynamic> fetchUserOverview(int userId) async {
    if (_token == null) await login();
    return await _get('user/overview/$userId');
  }

  Future<dynamic> fetchUser(int userId) async {
    if (_token == null) await login();
    return await _get('user/$userId');
  }

  Future<List<Map<String, dynamic>>> fetchExtendProfiles(int userId) async {
    if (_token == null) await login();

    // التسلسل المثبت من HAR:
    // extensionData للمشترك -> profile_id الحالي -> allowedExtensions
    final extensionData = await _get('user/extensionData/$userId');
    dynamic data = extensionData;
    if (extensionData is Map && extensionData['data'] != null) {
      data = extensionData['data'];
    }
    if (data is! Map) {
      throw SasApiException('رد extensionData غير مفهوم');
    }

    final currentProfileId = int.tryParse(
      (data['profile_id'] ?? data['profileId'] ?? '').toString(),
    );
    if (currentProfileId == null) {
      throw SasApiException('لم يرجع SAS البروفايل الحالي للمشترك');
    }

    final cachedAt = _extensionCacheAt[currentProfileId];
    final cached = _extensionCache[currentProfileId];
    List<Map<String, dynamic>> rows;

    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < const Duration(seconds: 60)) {
      rows = cached.map((e) => Map<String, dynamic>.from(e)).toList();
    } else {
      final allowed = await _get('allowedExtensions/$currentProfileId');
      rows = _extractRows(allowed);
      _extensionCache[currentProfileId] =
          rows.map((e) => Map<String, dynamic>.from(e)).toList();
      _extensionCacheAt[currentProfileId] = DateTime.now();
    }

    if (rows.isEmpty) {
      throw SasApiException('لا توجد Extensions مسموحة لهذا الاشتراك');
    }

    return rows
        .where((e) => e['id'] != null)
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<List<Map<String, dynamic>>> fetchProfiles({int managerId = 5}) async {
    if (_token == null) await login();
    final response = await _get('list/profile/$managerId');
    return _extractRows(response);
  }

  Future<List<Map<String, dynamic>>> fetchConnectedSessions() async {
    if (_token == null) await login();

    final allRows = <Map<String, dynamic>>[];
    final seenPages = <String>{};

    for (int page = 1; page <= 500; page++) {
      final response = await _post('index/online', {
        'page': page,
        'current': page,
        'page_no': page,
        'start': (page - 1) * 10,
        'offset': (page - 1) * 10,
        'limit': 10,
        'length': 10,
        'per_page': 10,
        'page_size': 10,
      });

      final rows = _extractRows(response);

      debugPrint('ONLINE PAGE $page -> ${rows.length}');

      if (rows.isEmpty) break;

      final fingerprint = rows
          .map((e) => (e['id'] ?? e['username'] ?? '').toString())
          .join('|');

      if (!seenPages.add(fingerprint)) {
        debugPrint('ONLINE repeated page, stop.');
        break;
      }

      allRows.addAll(rows);
    }

    debugPrint('TOTAL ONLINE USERS = ${allRows.length}');
    return allRows;
  }

Future<List<Map<String, dynamic>>> fetchParents() async {
    if (_token == null) await login();
    final response = await _get('manager');

    // manager endpoint may return one object or a list depending on SAS permissions.
    if (response is List) {
      return response
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    if (response is Map) {
      final m = Map<String, dynamic>.from(response);
      for (final key in ['data', 'rows', 'items', 'result', 'managers']) {
        final v = m[key];
        if (v is List) {
          return v
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
        if (v is Map) return [Map<String, dynamic>.from(v)];
      }
      return [m];
    }
    return const [];
  }


  Future<dynamic> fetchExtensionData(int userId) async {
    if (_token == null) await login();
    return _get('user/extensionData/$userId');
  }

  Future<Map<String, dynamic>> fetchDashboardWallet(int userId) async {
    final raw = await fetchExtensionData(userId);

    dynamic findValue(dynamic node, List<String> wantedKeys) {
      if (node is Map) {
        for (final entry in node.entries) {
          final key = entry.key.toString().toLowerCase().trim();
          if (wantedKeys.contains(key) && entry.value != null) {
            return entry.value;
          }
        }
        for (final value in node.values) {
          final found = findValue(value, wantedKeys);
          if (found != null) return found;
        }
      } else if (node is List) {
        for (final value in node) {
          final found = findValue(value, wantedKeys);
          if (found != null) return found;
        }
      }
      return null;
    }

    dynamic balance = findValue(raw, const [
      'balance',
      'user_balance',
    ]);

    dynamic rewardPoints = findValue(raw, const [
      'reward_points.balance',
      'reward_points_balance',
      'rewardpoints.balance',
    ]);

    if (rewardPoints == null) {
      dynamic rewards = findValue(raw, const ['reward_points', 'rewardpoints']);
      if (rewards is Map) {
        rewardPoints = rewards['balance'] ??
            rewards['points'] ??
            rewards['value'];
      } else if (rewards is num) {
        rewardPoints = rewards;
      }
    }

    if (balance == null && rewardPoints == null) {
      throw SasApiException(
        'رد extensionData لا يحتوي بيانات الرصيد أو النقاط',
      );
    }

    return <String, dynamic>{
      'balance': balance,
      'reward_points': rewardPoints,
    };
  }

  Future<int> testConnection() async {
    debugPrint('Testing connection to SAS...');
    
    // Check proxy only when it is explicitly enabled for Flutter Web.
    if (kIsWeb && !useDirectConnection) {
      final proxyUrl = _webProxyBase;
      if (proxyUrl.isEmpty) {
        throw SasApiException(
          'رابط البروكسي غير محدد\n\n'
          'الحلول:\n'
          '1. انشر بروكسي SAS على Render\n'
          '2. شغّل التطبيق مع SAS_WEB_PROXY_URL أو احفظ رابط البروكسي في الإعدادات\n\n'
          'يجب أن يكون الرابط HTTPS'
        );
      }
      
      // Check proxy health
      final proxyOk = await checkProxyHealth();
      if (!proxyOk) {
        throw SasApiException(
          'البروكسي غير متاح\n\n'
          'تأكد من:\n'
          '1. نشر البروكسي على Render وأن /health يعمل\n'
          '2. تحديث رابط البروكسي في SAS_WEB_PROXY_URL أو إعدادات التطبيق\n'
          '3. أن الرابط يبدأ بـ https://\n\n'
          'رابط البروكسي الحالي: $proxyUrl'
        );
      }
    }
    
    await login().timeout(const Duration(seconds: 20));
    final users = await fetchUsers().timeout(const Duration(seconds: 30));
    debugPrint('Connection successful!');
    return _extractRows(users).length;
  }

  List<Map<String, dynamic>> extractUsers(dynamic response) => _extractRows(response);

  List<Map<String, dynamic>> _extractRows(dynamic v) {
    dynamic x = v;
    if (x is Map) {
      for (final key in ['data', 'rows', 'users', 'items', 'result']) {
        if (x[key] is List) { x = x[key]; break; }
        if (x[key] is Map) {
          final nested = _extractRows(x[key]);
          if (nested.isNotEmpty) return nested;
        }
      }
    }
    if (x is List) {
      return x.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return const [];
  }

  Future<dynamic> _get(String route) async {
    final uri = _uriFor(route);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/plain, */*',
    };
    if (!_directFallback) headers['Allow-Cache-Y'] = 'yes';
    if (kIsWeb && !_directFallback) headers['X-SAS-DIAG'] = '1';
    _addProxyTarget(headers);
    if (_token != null) headers['authorization'] = 'Bearer $_token';

    http.Response res;
    try {
      debugPrint('GET URL: $uri');
      res = await http.get(uri, headers: headers).timeout(const Duration(seconds: 45));
      debugPrint('GET STATUS: ${res.statusCode}');
      
      if (res.statusCode == 401) {
        // try to refresh token once
        try {
          await login();
          if (_token != null) headers['authorization'] = 'Bearer $_token';
          res = await http.get(uri, headers: headers).timeout(const Duration(seconds: 45));
        } catch (_) {
          // fallthrough to error handling below
        }
      }
    } catch (e) {
      if (e is SasApiException) rethrow;
      throw SasApiException('تعذر جلب بيانات SAS: $e');
    }

    if (res.statusCode < 200 || res.statusCode >= 300) {
      final body = res.body.trim();
      final detail = body.isEmpty
          ? ''
          : ': ${body.length > 180 ? body.substring(0, 180) : body}';
      throw SasApiException('SAS رجع خطأ HTTP ${res.statusCode}$detail');
    }

    try {
      return jsonDecode(res.body);
    } catch (_) {
      throw SasApiException('رد SAS غير مفهوم');
    }
  }

  Future<dynamic> _put(String route, Map<String, dynamic> payload) async {
    final uri = _uriFor(route);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/plain, */*',
    };
    if (!_directFallback) headers['Allow-Cache-Y'] = 'yes';
    _addProxyTarget(headers);
    if (_token != null) headers['authorization'] = 'Bearer $_token';

    http.Response res;
    try {
      res = await http.put(
        uri,
        headers: headers,
        body: jsonEncode({
          'payload': _cryptoJsEncrypt(jsonEncode(payload), _passphrase),
        }),
      ).timeout(const Duration(seconds: 45));
      
      if (res.statusCode == 502) {
        final connectionMode = useDirectConnection ? 'الاتصال المباشر' : 'البروكسي';
        throw SasApiException(
          'خطأ 502 من SAS عبر $connectionMode.\n'
          'تأكد من صحة رابط SAS وأن السيرفر متاح من هذا الجهاز/المتصفح.'
        );
      }
      
      if (res.statusCode == 401) {
        try {
          await login();
          if (_token != null) headers['authorization'] = 'Bearer $_token';
          res = await http.put(
            uri,
            headers: headers,
            body: jsonEncode({
              'payload': _cryptoJsEncrypt(jsonEncode(payload), _passphrase),
            }),
          ).timeout(const Duration(seconds: 45));
        } catch (_) {}
      }
    } catch (e) {
      if (e is SasApiException) rethrow;
      throw SasApiException('تعذر تعديل المشترك في SAS: $e');
    }

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw SasApiException(
        'فشل تعديل SAS — HTTP ${res.statusCode}: '
        '${res.body.length > 160 ? res.body.substring(0, 160) : res.body}',
      );
    }

    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map && decoded['status'] != null) {
        final status = int.tryParse(decoded['status'].toString());
        if (status != null && status >= 400) {
          throw SasApiException('SAS رفض التعديل — status $status');
        }
      }
      return decoded;
    } catch (e) {
      if (e is SasApiException) rethrow;
      throw SasApiException(
        'تم إرسال PUT لكن رد SAS غير مفهوم: '
        '${res.body.length > 160 ? res.body.substring(0, 160) : res.body}',
      );
    }
  }

  Future<dynamic> _post(
    String route,
    Map<String, dynamic> payload, {
    bool authenticated = true,
    Map<String, String>? extraHeaders,
  }) async {
    final uri = _uriFor(route);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/plain, */*',
    };
    if (!_directFallback) headers['Allow-Cache-Y'] = 'yes';
    if (kIsWeb && !_directFallback) headers['X-SAS-DIAG'] = '1';
    _addProxyTarget(headers);
    if (extraHeaders != null && extraHeaders.isNotEmpty) {
      headers.addAll(extraHeaders);
    }
    if (authenticated && _token != null) headers['authorization'] = 'Bearer $_token';
    http.Response res;
    try {
      res = await http.post(uri, headers: headers, body: jsonEncode({'payload': _cryptoJsEncrypt(jsonEncode(payload), _passphrase)})).timeout(const Duration(seconds: 45));
      
      if (authenticated && res.statusCode == 401) {
        // attempt to refresh token once then retry
        try {
          await login();
          if (_token != null) headers['authorization'] = 'Bearer $_token';
          res = await http.post(uri, headers: headers, body: jsonEncode({'payload': _cryptoJsEncrypt(jsonEncode(payload), _passphrase)})).timeout(const Duration(seconds: 45));
        } catch (_) {}
      }
    } catch (e) {
      if (e is SasApiException) rethrow;
      throw SasApiException('تعذر الاتصال بخادم SAS: $e');
    }
    if (res.statusCode < 200 || res.statusCode >= 400) {
      final body = res.body.trim();
      final detail = body.isEmpty
          ? ''
          : ': ${body.length > 180 ? body.substring(0, 180) : body}';
      throw SasApiException('SAS رجع خطأ HTTP ${res.statusCode}$detail');
    }
    try {
      return jsonDecode(res.body);
    } catch (_) {
      throw SasApiException('رد SAS غير مفهوم: ${res.body.length > 120 ? res.body.substring(0, 120) : res.body}');
    }
  }

  String _cryptoJsEncrypt(String plainText, String passphrase) {
    final salt = Uint8List.fromList(List<int>.generate(8, (_) => Random.secure().nextInt(256)));
    final derived = _evpBytesToKey(utf8.encode(passphrase), salt, 48);
    final key = enc.Key(Uint8List.fromList(derived.sublist(0, 32)));
    final iv = enc.IV(Uint8List.fromList(derived.sublist(32, 48)));
    final aes = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));
    final cipher = aes.encrypt(plainText, iv: iv).bytes;
    final out = <int>[...ascii.encode('Salted__'), ...salt, ...cipher];
    return base64Encode(out);
  }

  List<int> _evpBytesToKey(List<int> password, List<int> salt, int length) {
    final out = <int>[];
    List<int> block = const [];
    while (out.length < length) {
      block = md5.convert(<int>[...block, ...password, ...salt]).bytes;
      out.addAll(block);
    }
    return out.sublist(0, length);
  }
}
