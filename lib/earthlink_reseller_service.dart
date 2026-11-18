import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// خدمة وكيل إيرثلنك عبر لوحة الوكلاء الويب admin.earthlink.iq.
///
/// ليست SAS4 ولا FTTH: إنها بوابة ASP.NET WebForms على IIS، المصادقة فيها
/// بكوكي جلسة (.ASPXFORMSDEMO) لا بتوكن، وكل تعديل يتطلب سحب حقول
/// __VIEWSTATE/__EVENTVALIDATION من صفحة ثم إعادتها في POST.
///
/// مبنية من ملفات HAR حقيقية للوكيل، دون طباعة أي اعتماد أو PIN أو توكن.

class EarthlinkException implements Exception {
  const EarthlinkException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'EarthlinkException($message)';
}

/// إعدادات حساب وكيل إيرثلنك، تُحفظ كما تُحفظ إعدادات FTTH: اسم المستخدم
/// والرابط في SharedPreferences وفي Firebase (agents/{uid}/earthlink_reseller،
/// مسموح به بقواعد agents)، وكلمة المرور في التخزين الآمن على الجهاز فقط.
class EarthlinkResellerSettings {
  const EarthlinkResellerSettings({
    required this.username,
    required this.password,
    this.baseUrl = 'https://admin.earthlink.iq',
  });

  final String username;
  final String password;
  final String baseUrl;

  static const _baseUrlKey = 'earthlink_base_url';
  static const _usernameKey = 'earthlink_username';
  static const _passwordKey = 'earthlink_password';
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  static DatabaseReference? _remoteRef() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return uid == null
        ? null
        : FirebaseDatabase.instance.ref('agents/$uid/earthlink_reseller');
  }

  static Future<bool> _pullFromFirebase(SharedPreferences prefs) async {
    final ref = _remoteRef();
    if (ref == null) return true;
    final value = (await ref.get().timeout(const Duration(seconds: 5))).value;
    if (value is! Map) return false;
    final username = (value['username'] ?? '').toString().trim();
    if (username.isEmpty) return false;
    final baseUrl = (value['baseUrl'] ?? '').toString().trim();
    if (baseUrl.isNotEmpty) await prefs.setString(_baseUrlKey, baseUrl);
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

  static Future<EarthlinkResellerSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    var foundRemote = true;
    try {
      foundRemote = await _pullFromFirebase(prefs);
    } catch (error) {
      debugPrint('[Earthlink] settings pull failed: $error');
    }
    final settings = await _loadLocal(prefs);
    if (!foundRemote && settings.isComplete) await settings.save();
    return settings;
  }

  static Future<EarthlinkResellerSettings> _loadLocal(
    SharedPreferences prefs,
  ) async {
    String password = '';
    try {
      password = await _secureStorage.read(key: _passwordKey) ?? '';
    } catch (_) {
      password = prefs.getString(_passwordKey) ?? '';
    }
    return EarthlinkResellerSettings(
      baseUrl: prefs.getString(_baseUrlKey) ?? 'https://admin.earthlink.iq',
      username: prefs.getString(_usernameKey) ?? '',
      password: password,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, baseUrl.trim());
    await prefs.setString(_usernameKey, username.trim());
    await _storePassword(prefs, password);
    try {
      await _remoteRef()
          ?.update({
            'baseUrl': baseUrl.trim(),
            'username': username.trim(),
            'updatedAt': ServerValue.timestamp,
          })
          .timeout(const Duration(seconds: 8));
    } catch (error) {
      debugPrint('[Earthlink] settings save to Firebase failed: $error');
    }
  }

  bool get isComplete => username.trim().isNotEmpty && password.isNotEmpty;

  bool get needsPassword => username.trim().isNotEmpty && password.isEmpty;

  static const missingPasswordMessage =
      'أدخل كلمة مرور وكيل إيرثلنك على هذا الجهاز ثم احفظ. '
      'تُحفظ على الجهاز فقط.';
}

/// حقل مخفي في صفحة ASP.NET (مثل __VIEWSTATE) كما يظهر في وسم input.
String? extractHiddenField(String html, String name) {
  // <input type="hidden" name="__VIEWSTATE" id="..." value="..." />
  // قد يختلف ترتيب السمات، فنبحث عن الاسم ثم أقرب value بعده.
  final nameIdx = html.indexOf('name="$name"');
  if (nameIdx < 0) return null;
  final valueMatch = RegExp(
    r'value="([^"]*)"',
  ).firstMatch(html.substring(nameIdx));
  return valueMatch?.group(1);
}

/// الرموز الثلاثة التي يجب إعادتها في أي POST إلى صفحة WebForms.
class AspxTokens {
  const AspxTokens({
    required this.viewState,
    required this.viewStateGenerator,
    required this.eventValidation,
  });

  final String viewState;
  final String viewStateGenerator;
  final String eventValidation;

  /// يقرأ الرموز من HTML صفحة. يرمي إن غابت، فالصفحة غالباً صفحة دخول
  /// (انتهت الجلسة) لا الصفحة المطلوبة.
  static AspxTokens parse(String html) {
    final vs = extractHiddenField(html, '__VIEWSTATE');
    final gen = extractHiddenField(html, '__VIEWSTATEGENERATOR');
    final ev = extractHiddenField(html, '__EVENTVALIDATION');
    if (vs == null || ev == null) {
      throw const EarthlinkException(
        'انتهت جلسة إيرثلنك أو تعذّر قراءة الصفحة. أعد تسجيل الدخول.',
      );
    }
    return AspxTokens(
      viewState: vs,
      viewStateGenerator: gen ?? '',
      eventValidation: ev,
    );
  }
}

/// جسم طلب الدخول إلى /Login.aspx كما في HAR (أسماء حقول ASP.NET Login).
Map<String, String> earthlinkLoginBody({
  required String username,
  required String password,
  required AspxTokens tokens,
  String loginCount = '0',
}) => {
  '__LASTFOCUS': '',
  '__EVENTTARGET': '',
  '__EVENTARGUMENT': '',
  '__VIEWSTATE': tokens.viewState,
  '__VIEWSTATEGENERATOR': tokens.viewStateGenerator,
  '__EVENTVALIDATION': tokens.eventValidation,
  'Logincountf': loginCount,
  'Login1\$UserName': username,
  'Login1\$Password': password,
  'Login1\$LoginButton': 'تسجيل الدخول',
};

/// يحلّل ترويسة Set-Cookie (أو عدة ترويسات مدموجة بفاصلة من حزمة http)
/// إلى أزواج اسم=قيمة، متجاهلاً سمات الكوكي (Path/Expires/HttpOnly...).
Map<String, String> parseSetCookie(String? raw) {
  final out = <String, String>{};
  if (raw == null || raw.isEmpty) return out;
  // افصل عند فاصلة تسبق مباشرةً زوج اسم=قيمة جديد (لا فاصلة داخل Expires).
  final parts = raw.split(RegExp(r',(?=\s*[A-Za-z0-9_.\-]+=)'));
  for (final part in parts) {
    final pair = part.split(';').first.trim();
    final eq = pair.indexOf('=');
    if (eq <= 0) continue;
    final name = pair.substring(0, eq).trim();
    final value = pair.substring(eq + 1).trim();
    if (name.isEmpty) continue;
    out[name] = value;
  }
  return out;
}

/// مشترك إيرثلنك كما يرجعه WebAPIs/api/Users/GetUserDisplayInfo (JSON نظيف).
class EarthlinkSubscriber {
  const EarthlinkSubscriber({
    required this.userId,
    required this.displayName,
    required this.accountName,
    required this.accountStatus,
    required this.packageType,
    required this.mobileNumber,
    required this.daysLeft,
    required this.expirationDate,
    required this.canRefill,
    required this.canChangeAccount,
  });

  final String userId;
  final String displayName;
  final String accountName; // اسم الباقة
  final String accountStatus; // Active / Suspended ...
  final String packageType; // MonthlyPrepaid ...
  final String mobileNumber;
  final int daysLeft;
  final String expirationDate;
  final bool canRefill;
  final bool canChangeAccount;

  static int _toInt(dynamic v) {
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}'.trim()) ?? 0;
  }

  static String _str(dynamic v) => '${v ?? ''}'.trim();

  /// يقبل الرد الكامل {Value:{...}} أو كائن القيمة مباشرة.
  static EarthlinkSubscriber fromDisplayInfo(dynamic json) {
    if (json is! Map) {
      throw const EarthlinkException('رد غير متوقع من إيرثلنك');
    }
    final v = json['Value'] is Map ? json['Value'] as Map : json;
    return EarthlinkSubscriber(
      userId: _str(v['UserID'] ?? v['UserId']),
      displayName: _str(v['DisplayName']),
      accountName: _str(v['AccountName']),
      accountStatus: _str(v['AccountStatus']),
      packageType: _str(v['AccountPackageType']),
      mobileNumber: _str(v['MobileNumber']),
      daysLeft: _toInt(v['ActiveDaysLeft']),
      expirationDate: _str(v['ManualExpirationDate']),
      canRefill: v['CanRefill'] == true,
      canChangeAccount: v['CanChangeAccount'] == true,
    );
  }
}

/// نتيجة إجراء postback (تعبئة/تغيير باقة). رد Telerik نصي بصيغة دلتا
/// `1|#||4|len|updatePanel|id|<html>...`، فنفحص النص عن نجاح أو خطأ.
class EarthlinkActionResult {
  const EarthlinkActionResult({
    required this.success,
    required this.message,
    this.newExpiration,
  });
  final bool success;
  final String message;
  final String? newExpiration;
}

/// مشترك في جدول المستخدمين (UserManagement.aspx RadGrid)، لمزامنته للقائمة.
class EarthlinkListUser {
  const EarthlinkListUser({
    required this.userId,
    required this.name,
    required this.planName,
    required this.status,
    required this.expiration,
    required this.mobile,
  });

  final String userId;
  final String name;
  final String planName;
  final String status; // Active / Suspended ...
  final String expiration;
  final String mobile;
}

String _stripTags(String html) => html
    .replaceAll(RegExp(r'<[^>]+>'), ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&')
    .replaceAll(RegExp(r'[ \t\r\n]+'), ' ')
    .trim();

String _after(String text, String label) {
  final i = text.indexOf(label);
  if (i < 0) return '';
  final rest = text.substring(i + label.length).trimLeft();
  // حتى الفاصل التالي (علامة حقل آخر أو نهاية).
  final m = RegExp(r'^[^:|]+').firstMatch(rest);
  return (m?.group(0) ?? '').trim();
}

/// يحلّل صفوف جدول المستخدمين إلى مشتركين. يعتمد على أعمدة RadGrid الثابتة
/// (اسم المستخدم، تاريخ الانتهاء، Acc. Name/Status، الموبايل).
List<EarthlinkListUser> parseSubscriberGrid(String html) {
  final out = <EarthlinkListUser>[];
  final seen = <String>{};
  final rows = RegExp(
    r'<tr[^>]*class="[^"]*rg(?:Row|AltRow)[^"]*"[^>]*>([\s\S]*?)</tr>',
    caseSensitive: false,
  ).allMatches(html);
  for (final row in rows) {
    final cells = RegExp(
      r'<td[^>]*>([\s\S]*?)</td>',
      caseSensitive: false,
    ).allMatches(row.group(1) ?? '').map((m) => _stripTags(m.group(1)!)).toList();
    if (cells.length < 6) continue;
    final uidText = cells.firstWhere(
      (c) => RegExp(r'\S+@\S+').hasMatch(c),
      orElse: () => '',
    );
    final uid = RegExp(r'(\S+@\S+)').firstMatch(uidText)?.group(1) ?? '';
    if (uid.isEmpty || !seen.add(uid)) continue;
    final accInfo = cells.firstWhere(
      (c) => c.contains('Acc. Name') || c.contains('Acc. Status'),
      orElse: () => '',
    );
    final exp = cells.firstWhere(
      (c) => RegExp(r'^\d{1,2}/\d{1,2}/\d{4}').hasMatch(c),
      orElse: () => '',
    );
    final mob = cells.firstWhere((c) => c.contains('Mobile'), orElse: () => '');
    out.add(
      EarthlinkListUser(
        userId: uid,
        name: _after(uidText, uid).replaceFirst(RegExp(r'^[\s|]+'), '').trim(),
        planName: _after(accInfo, 'Acc. Name :'),
        status: _after(accInfo, 'Acc. Status :'),
        expiration: exp.trim(),
        mobile: _after(mob, 'Mobile :'),
      ),
    );
  }
  return out;
}

/// باقة (نوع اشتراك) كما في قائمة AccountTypes بصفحة تغيير الباقة.
class EarthlinkPlan {
  const EarthlinkPlan({required this.id, required this.name});
  final String id;
  final String name;
}

/// يستخرج باقات من قائمة <option value="id">الاسم</option> في صفحة
/// ChangeAccount.aspx. تغيير الباقة = التعبئة لاحقاً بـ id المختار.
List<EarthlinkPlan> parsePlans(String html) {
  final out = <EarthlinkPlan>[];
  final seen = <String>{};
  for (final m in RegExp(
    r'<option[^>]*value="(\d+)"[^>]*>([^<]*)</option>',
    caseSensitive: false,
  ).allMatches(html)) {
    final id = m.group(1)!;
    final name = (m.group(2) ?? '').trim();
    if (name.isEmpty || !seen.add(id)) continue;
    out.add(EarthlinkPlan(id: id, name: name));
  }
  return out;
}

/// طريقة التعبئة: ببطاقة مسبقة الدفع أو بخصم من رصيد الوكيل (إيداع).
enum EarthlinkRefillMode { card, balance }

extension on EarthlinkRefillMode {
  // قيمة زر الراديو refillgroup كما في صفحة RefillUser.aspx.
  String get radio =>
      this == EarthlinkRefillMode.card ? 'userprepayradio' : 'depositradio';
}

/// جسم إرسال التعبئة إلى /users/RefillUser.aspx، مطابق لعملية ناجحة في HAR.
/// الإرسال الفعلي يُطلق عبر RadAjaxManager1 بوسيطة refilluser (لا زر عادي).
Map<String, String> earthlinkRefillBody({
  required AspxTokens tokens,
  required EarthlinkRefillMode mode,
  required String planId, // AccountTypesDrop$AccountTypesList
  String cardId = '',
  String cardPassword = '',
  String onlinePassword = '',
  bool payLater = true,
  String notes = '',
}) => {
  '__EVENTTARGET': 'RadAjaxManager1',
  '__EVENTARGUMENT': 'refilluser',
  '__LASTFOCUS': '',
  '__VIEWSTATE': tokens.viewState,
  '__VIEWSTATEGENERATOR': tokens.viewStateGenerator,
  '__EVENTVALIDATION': tokens.eventValidation,
  'RadScriptManager1_TSM': '',
  'RadWindowManager1_ClientState': '',
  'refillgroup': mode.radio,
  'PrePayCardIdentifier': mode == EarthlinkRefillMode.card ? cardId : '',
  'PrePayCardPassword': mode == EarthlinkRefillMode.card ? cardPassword : '',
  'AccountTypesDrop\$AccountTypesList': planId,
  'onlinepassword': onlinePassword,
  'payment': 'nopayment',
  'willpayinbox': payLater ? '1' : '0',
  'notesbox': notes,
  '__ASYNCPOST': 'true',
  'RadAJAXControlID': 'RadAjaxManager1',
};

/// يحلّل رد التعبئة (دلتا Telerik). النجاح مؤكَّد من HAR بنص إنجليزي ثابت.
EarthlinkActionResult parseRefillResult(String body) {
  final ok =
      body.contains('account has been updated') ||
      body.contains('payment was accepted');
  if (ok) {
    final exp = RegExp(
      r'expiration date is\s+([0-9/]+\s+[0-9:]+\s*[APMapm]*)',
    ).firstMatch(body);
    return EarthlinkActionResult(
      success: true,
      message: 'تمت التعبئة بنجاح.',
      newExpiration: exp?.group(1)?.trim(),
    );
  }
  // استخرج رسالة خطأ مرئية إن وُجدت، وإلا رسالة عامة.
  final err = RegExp(
    r'(card .*?(used|invalid|wrong)[^<|]*|الرصيد[^<|]*|بطاقة[^<|]*)',
    caseSensitive: false,
  ).firstMatch(body);
  return EarthlinkActionResult(
    success: false,
    message: err?.group(0)?.trim() ?? 'لم تكتمل التعبئة. تحقق من الحالة.',
  );
}

/// عميل لوحة وكلاء إيرثلنك. يحفظ كوكيز الجلسة يدوياً (حزمة http لا تحفظها)
/// ويسحب رموز WebForms قبل كل إجراء كتابة.
class EarthlinkResellerService {
  EarthlinkResellerService({
    required this.username,
    required this.password,
    http.Client? client,
    this.baseUrl = 'https://admin.earthlink.iq',
  }) : _client = client ?? http.Client();

  EarthlinkResellerService.fromSettings(
    EarthlinkResellerSettings settings, {
    http.Client? client,
  }) : username = settings.username,
       password = settings.password,
       baseUrl = settings.baseUrl,
       _client = client ?? http.Client();

  final String username;
  final String password;
  final String baseUrl;
  final http.Client _client;

  /// كوكيز الجلسة (.ASPXFORMSDEMO وASPNETSESSION) بعد الدخول.
  final Map<String, String> _cookies = {};

  bool get isAuthenticated => _cookies.containsKey('.ASPXFORMSDEMO');

  void _log(String message) => debugPrint('[Earthlink] $message');

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final clean = path.startsWith('/') ? path : '/$path';
    final q = query?.map((k, v) => MapEntry(k, '$v'));
    return Uri.parse('$baseUrl$clean').replace(queryParameters: q);
  }

  String? get _cookieHeader => _cookies.isEmpty
      ? null
      : _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  void _absorb(http.BaseResponse response) {
    final raw = response.headers['set-cookie'];
    if (raw == null) return;
    _cookies.addAll(parseSetCookie(raw));
  }

  Map<String, String> _headers({bool json = false, bool form = false}) => {
    'Accept': json
        ? 'application/json, text/plain, */*'
        : 'text/html,application/xhtml+xml,*/*',
    if (form) 'Content-Type': 'application/x-www-form-urlencoded',
    'Cookie': ?_cookieHeader,
  };

  /// نسخة الويب تُحجب (IIS بلا CORS، والكوكي HttpOnly لا يُقرأ من JS).
  static const webUnsupportedMessage =
      'لوحة إيرثلنك لا تعمل من نسخة الويب. استخدم تطبيق أندرويد.';

  void _guardWeb() {
    if (kIsWeb) throw const EarthlinkException(webUnsupportedMessage);
  }

  /// يسجّل الدخول: يسحب الرموز من صفحة الدخول ثم يرسل الاعتماد.
  /// النجاح = تحويل 302 إلى /home.aspx (مع إصدار كوكي .ASPXFORMSDEMO).
  Future<void> login() async {
    _guardWeb();
    if (password.isEmpty) {
      throw const EarthlinkException('أدخل كلمة مرور إيرثلنك.');
    }
    // 1) صفحة الدخول: كوكي جلسة أولي + الرموز.
    final page = await _client.get(_uri('/Login.aspx'), headers: _headers());
    _absorb(page);
    if (page.statusCode != 200) {
      throw EarthlinkException(
        'تعذّر فتح صفحة دخول إيرثلنك',
        statusCode: page.statusCode,
      );
    }
    final tokens = AspxTokens.parse(page.body);

    // 2) إرسال الاعتماد دون متابعة التحويل، لنقرأ 302 ونلتقط كوكي المصادقة.
    final request = http.Request('POST', _uri('/Login.aspx'))
      ..followRedirects = false
      ..headers.addAll(_headers(form: true))
      ..bodyFields = earthlinkLoginBody(
        username: username,
        password: password,
        tokens: tokens,
      );
    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);
    _absorb(response);

    final location = response.headers['location'] ?? '';
    final ok =
        response.statusCode == 302 && location.toLowerCase().contains('home');
    if (!ok) {
      // 200 يعني بقي في صفحة الدخول: اعتماد خاطئ.
      throw const EarthlinkException(
        'فشل تسجيل الدخول إلى إيرثلنك: تحقق من اسم المستخدم وكلمة المرور.',
      );
    }
    if (!isAuthenticated) {
      _log('login redirected but no auth cookie seen');
    }
  }

  /// تفاصيل مشترك عبر WebAPI (JSON نظيف، بلا رموز WebForms).
  Future<EarthlinkSubscriber> fetchSubscriber(String userId) async {
    _guardWeb();
    final response = await _client.get(
      _uri('/WebAPIs/api/Users/GetUserDisplayInfo', {'userId': userId}),
      headers: _headers(json: true),
    );
    _absorb(response);
    final body = response.body.trimLeft();
    // جلسة منتهية: يعيد صفحة دخول HTML بدل JSON.
    if (response.statusCode != 200 || body.startsWith('<')) {
      throw const EarthlinkException(
        'انتهت جلسة إيرثلنك. سجّل الدخول من جديد.',
      );
    }
    return EarthlinkSubscriber.fromDisplayInfo(_decode(body));
  }

  dynamic _decode(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      throw const EarthlinkException('رد غير مقروء من إيرثلنك');
    }
  }

  /// قائمة مشتركي الوكيل من جدول UserManagement (لمزامنتهم في قائمة التطبيق).
  /// الوسائط الافتراضية مطابقة لما يظهر في HAR.
  Future<List<EarthlinkListUser>> fetchSubscribers({
    int userst = 6,
    int t = 5,
  }) async {
    _guardWeb();
    final page = await _client.get(
      _uri('/UserManagement.aspx', {'userst': userst, 't': t}),
      headers: _headers(),
    );
    _absorb(page);
    if (page.statusCode != 200) {
      throw EarthlinkException(
        'تعذّر جلب قائمة المشتركين',
        statusCode: page.statusCode,
      );
    }
    final users = parseSubscriberGrid(page.body);
    // صفحة دخول بدل الجدول = جلسة منتهية.
    if (users.isEmpty && !page.body.contains('rgMasterTable')) {
      throw const EarthlinkException('انتهت جلسة إيرثلنك. سجّل الدخول.');
    }
    return users;
  }

  /// قائمة الباقات المتاحة للمشترك (من صفحة تغيير الباقة). تُعرض في منتقي
  /// الباقة قبل التعبئة؛ اختيار باقة مختلفة يغيّرها عند التعبئة.
  Future<List<EarthlinkPlan>> fetchPlans(String uid) async {
    _guardWeb();
    final page = await _client.get(
      _uri('/Users/ChangeAccount.aspx', {'uid': uid}),
      headers: _headers(),
    );
    _absorb(page);
    final plans = parsePlans(page.body);
    if (page.statusCode != 200 || plans.isEmpty) {
      throw const EarthlinkException(
        'تعذّر جلب الباقات. ربما انتهت الجلسة.',
      );
    }
    return plans;
  }

  /// يفتح صفحة الإجراء ويسحب رموز WebForms الطازجة (مطلوبة لكل POST).
  Future<AspxTokens> _scrape(String path, String uid) async {
    final page = await _client.get(
      _uri(path, {'uid': uid}),
      headers: _headers(),
    );
    _absorb(page);
    if (page.statusCode != 200) {
      throw EarthlinkException(
        'تعذّر فتح صفحة إيرثلنك',
        statusCode: page.statusCode,
      );
    }
    return AspxTokens.parse(page.body);
  }

  /// تعبئة ببطاقة مسبقة الدفع. planId = معرّف نوع الاشتراك (الباقة) للمشترك.
  Future<EarthlinkActionResult> refillByCard({
    required String uid,
    required String cardId,
    required String cardPassword,
    required String planId,
  }) => _refill(
    uid: uid,
    body: (tokens) => earthlinkRefillBody(
      tokens: tokens,
      mode: EarthlinkRefillMode.card,
      planId: planId,
      cardId: cardId,
      cardPassword: cardPassword,
    ),
  );

  /// تعبئة بخصم من رصيد الوكيل. onlinePassword = كلمة مرور حساب المشترك،
  /// payLater=true يعني «سيدفع لاحقاً» (willpayinbox) كما في العملية الناجحة.
  Future<EarthlinkActionResult> refillByBalance({
    required String uid,
    required String planId,
    required String onlinePassword,
    bool payLater = true,
    String notes = '',
  }) => _refill(
    uid: uid,
    body: (tokens) => earthlinkRefillBody(
      tokens: tokens,
      mode: EarthlinkRefillMode.balance,
      planId: planId,
      onlinePassword: onlinePassword,
      payLater: payLater,
      notes: notes,
    ),
  );

  Future<EarthlinkActionResult> _refill({
    required String uid,
    required Map<String, String> Function(AspxTokens) body,
  }) async {
    _guardWeb();
    final tokens = await _scrape('/users/RefillUser.aspx', uid);
    final response = await _client.post(
      _uri('/users/RefillUser.aspx', {'uid': uid}),
      headers: {..._headers(form: true), 'X-MicrosoftAjax': 'Delta=true'},
      body: body(tokens),
    );
    _absorb(response);
    if (response.statusCode != 200) {
      throw EarthlinkException(
        'فشل اتصال التعبئة',
        statusCode: response.statusCode,
      );
    }
    return parseRefillResult(response.body);
  }

  void dispose() => _client.close();
}
