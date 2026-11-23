import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'earthlink_reseller_service.dart'
    show EarthlinkException, EarthlinkResellerSettings, parseEarthlinkDate;
import 'models.dart';
import 'services/trial_guard_service.dart';

/// واجهة تطبيق وكلاء إيرثلنك `rapi.earthlink.iq` (REST/JSON، OAuth2 Bearer).
///
/// بديل بوابة الويب `admin.earthlink.iq` (التي تتطلب VPN): هذه تعمل **بلا VPN**
/// وبواجهة JSON نظيفة. مبنية من HAR حقيقي لتطبيق `com.earthlinktele.resellers`،
/// دون طباعة أي اعتماد أو توكن. أجسام POST بصيغة form-urlencoded؛ نمط الرد
/// العام: `{value, responseMessage, error:{message,errorCode}, isSuccessful}`.
const String kEarthlinkMobileBase = 'https://rapi.earthlink.iq/api/reseller';

/// `rapi.earthlink.iq` خلف Cloudflare وقد يحجب الـUser-Agent الافتراضي،
/// فنطابق تطبيق الوكلاء (من الـHAR) لتفادي الحجب.
const String kEarthlinkUserAgent =
    'Resellers/4.1.0 (com.earthlink.reseller; build:5; iOS 27.0.1) Alamofire/5.4.4';

/// باقة إيرثلنك من `/accounts/all` (accountIndex = معرّف الباقة للإجراءات).
class EarthlinkMobilePlan {
  const EarthlinkMobilePlan({
    required this.accountIndex,
    required this.name,
    this.description = '',
  });

  final int accountIndex;
  final String name;
  final String description;
}

/// كلفة باقة من `/affiliate/deposit/accountCost` (المبلغ المخصوم من الوكيل).
class EarthlinkCost {
  const EarthlinkCost({
    required this.amount,
    required this.currencySign,
    required this.currencyIso,
  });

  final double amount;
  final String currencySign;
  final String currencyIso;
}

/// مشترك من `/user/all` (itemsList) أو `/user/{id}` — الحقول متطابقة الأسماء.
class EarthlinkMobileUser {
  const EarthlinkMobileUser({
    required this.userId,
    required this.name,
    required this.planName,
    required this.accountIndex,
    required this.status,
    required this.active,
    required this.daysLeft,
    required this.expiration,
    required this.mobile,
    required this.canRefill,
    required this.canChangeAccount,
    required this.canExtend,
  });

  final String userId;
  final String name;
  final String planName;
  final int accountIndex;
  final String status;
  final bool active;
  final int daysLeft;
  final DateTime? expiration;
  final String mobile;
  final bool canRefill;
  final bool canChangeAccount;
  final bool canExtend;

  static int _toInt(dynamic v) {
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}'.trim()) ?? 0;
  }

  static String _str(dynamic v) => '${v ?? ''}'.trim();

  /// يقبل عنصر itemsList أو كائن `value` من تفاصيل مشترك. الحقول متطابقة
  /// عدا أن القائمة تضع الاسم في `fullName` والتفاصيل في `displayName`.
  static EarthlinkMobileUser fromJson(dynamic json) {
    if (json is! Map) {
      throw const EarthlinkException('رد غير متوقع من إيرثلنك');
    }
    final userObject = json['userObject'];
    final userId = _str(
      json['userID'] ??
          json['userId'] ??
          (userObject is Map ? userObject['userId'] : null),
    );
    final name = _firstNonEmpty([
      json['fullName'],
      json['displayName'],
      json['arName'],
      if (userObject is Map) userObject['displayName'],
      userId,
    ]);
    final status = _str(
      json['accountStatus'] ??
          json['status'] ??
          (userObject is Map ? userObject['status'] : null),
    );
    return EarthlinkMobileUser(
      userId: userId,
      name: name,
      planName: _str(json['accountName']),
      accountIndex: _toInt(json['accountIndex']),
      status: status,
      active: json['userActive'] == true || status.toLowerCase() == 'active',
      daysLeft: _toInt(json['activeDaysLeft']),
      expiration: _expiry(json),
      mobile: _str(json['mobileNumber'] ?? json['mobileNumber2']),
      canRefill: json['canRefill'] == true,
      canChangeAccount: json['canChangeAccount'] == true,
      canExtend: json['canExtendUser'] == true,
    );
  }

  static String _firstNonEmpty(List<dynamic> values) {
    for (final v in values) {
      final s = _str(v);
      if (s.isNotEmpty) return s;
    }
    return '';
  }

  /// الانتهاء من accountExpirationDate (ISO) ثم manualExpirationDate
  /// (DD/MM/YYYY hh:mm AM/PM) ثم تقدير من activeDaysLeft.
  static DateTime? _expiry(Map json) {
    final iso = _str(json['accountExpirationDate']);
    final isoParsed = iso.isEmpty ? null : DateTime.tryParse(iso);
    if (isoParsed != null) return isoParsed;
    final manual = parseEarthlinkDate(_str(json['manualExpirationDate']));
    if (manual != null) return manual;
    final days = _toInt(json['activeDaysLeft']);
    return days > 0 ? DateTime.now().add(Duration(days: days)) : null;
  }

  /// يحوّله لمشترك NetAgent (source=earthlink). التاريخ المجهول = الآن.
  Subscriber toSubscriber() {
    final end = expiration ?? DateTime.now();
    return Subscriber(
      user: userId,
      name: name.isNotEmpty ? name : userId,
      phone: mobile,
      address: '',
      ip: '',
      type: planName,
      price: 0,
      startDate: end,
      endDate: end,
      active: active,
      source: 'earthlink',
      sasId: userId,
      sasOnline: false,
      sasData: {
        'provider': 'إيرثلنك',
        'earthlink_uid': userId,
        'status': status,
        'plan': planName,
        'accountIndex': accountIndex,
        'canRefill': canRefill,
        'canChangeAccount': canChangeAccount,
      },
    );
  }
}

/// نتيجة إجراء (تعبئة/تغيير باقة/تمديد): نجاح + رسالة الخادم.
class EarthlinkMobileResult {
  const EarthlinkMobileResult({required this.success, this.message = ''});
  final bool success;
  final String message;
}

// ===== محلّلات نقيّة (قابلة للاختبار دون شبكة) =====

/// حقول نموذج الدخول (form-urlencoded): LoginType=1، grant_type=password.
Map<String, String> earthlinkLoginForm({
  required String username,
  required String password,
}) => {
  'LoginType': '1',
  'grant_type': 'password',
  'username': username,
  'password': password,
};

/// يستخرج `access_token` من رد `/token`. فارغ ⇒ استثناء.
String parseEarthlinkToken(dynamic json) {
  final token = (json is Map ? json['access_token'] : null)?.toString() ?? '';
  if (token.isEmpty) {
    throw const EarthlinkException('تعذّر تسجيل الدخول إلى إيرثلنك');
  }
  return token;
}

/// ثواني صلاحية التوكن من `expires_in` (افتراض ساعة).
int parseEarthlinkExpiresIn(dynamic json) {
  final v = json is Map ? json['expires_in'] : null;
  if (v is num) return v.toInt();
  return int.tryParse('${v ?? ''}') ?? 3599;
}

/// يفكّ غلاف الرد العام ويعيد `value`؛ يرمي عند `isSuccessful:false`.
dynamic earthlinkUnwrap(dynamic json) {
  if (json is! Map) {
    throw const EarthlinkException('رد غير متوقع من إيرثلنك');
  }
  if (json['isSuccessful'] == false) {
    final error = json['error'];
    final message = error is Map
        ? '${error['message'] ?? ''}'.trim()
        : '${json['responseMessage'] ?? ''}'.trim();
    throw EarthlinkException(
      message.isNotEmpty ? message : 'فشل الطلب في إيرثلنك',
    );
  }
  return json['value'];
}

List<EarthlinkMobilePlan> parseEarthlinkMobilePlans(dynamic json) {
  final value = earthlinkUnwrap(json);
  if (value is! List) return const [];
  final out = <EarthlinkMobilePlan>[];
  for (final item in value) {
    if (item is! Map) continue;
    final idx = item['accountIndex'];
    final index = idx is num
        ? idx.toInt()
        : int.tryParse('${idx ?? ''}'.trim());
    if (index == null) continue;
    out.add(
      EarthlinkMobilePlan(
        accountIndex: index,
        name: '${item['accountName'] ?? ''}'.trim(),
        description: '${item['accountDescription'] ?? ''}'.trim(),
      ),
    );
  }
  return out;
}

/// قائمة المشتركين + العدد الكلي من `/user/all`.
({List<EarthlinkMobileUser> users, int total}) parseEarthlinkUserList(
  dynamic json,
) {
  final value = earthlinkUnwrap(json);
  if (value is! Map) return (users: const [], total: 0);
  final items = value['itemsList'];
  final users = <EarthlinkMobileUser>[];
  if (items is List) {
    for (final item in items) {
      if (item is Map) users.add(EarthlinkMobileUser.fromJson(item));
    }
  }
  final totalRaw = value['totalCount'];
  final total = totalRaw is num
      ? totalRaw.toInt()
      : int.tryParse('${totalRaw ?? ''}') ?? users.length;
  return (users: users, total: total);
}

EarthlinkMobileUser parseEarthlinkUserDetail(dynamic json) {
  final value = earthlinkUnwrap(json);
  return EarthlinkMobileUser.fromJson(value);
}

double parseEarthlinkBalance(dynamic json) {
  final value = earthlinkUnwrap(json);
  if (value is num) return value.toDouble();
  return double.tryParse('${value ?? ''}'.trim()) ?? 0;
}

EarthlinkCost parseEarthlinkCost(dynamic json) {
  final value = earthlinkUnwrap(json);
  if (value is! Map) {
    throw const EarthlinkException('تعذّر قراءة كلفة الباقة');
  }
  final amount = value['value'];
  return EarthlinkCost(
    amount: amount is num
        ? amount.toDouble()
        : double.tryParse('${amount ?? ''}'.trim()) ?? 0,
    currencySign: '${value['currencySign'] ?? ''}'.trim(),
    currencyIso: '${value['currencyISOCode'] ?? ''}'.trim(),
  );
}

/// نجاح إجراء: `isSuccessful:true` و/أو `value:true`.
EarthlinkMobileResult parseEarthlinkActionResult(dynamic json) {
  if (json is! Map) {
    return const EarthlinkMobileResult(success: false);
  }
  final ok = json['isSuccessful'] == true && json['value'] != false;
  final error = json['error'];
  final message = error is Map
      ? '${error['message'] ?? ''}'.trim()
      : '${json['responseMessage'] ?? json['message'] ?? ''}'.trim();
  return EarthlinkMobileResult(success: ok, message: message);
}

// ===== الخدمة =====

class EarthlinkMobileService {
  EarthlinkMobileService({
    required this.username,
    required this.password,
    http.Client? client,
    this.baseUrl = kEarthlinkMobileBase,
  }) : _client = client ?? http.Client();

  EarthlinkMobileService.fromSettings(
    EarthlinkResellerSettings settings, {
    http.Client? client,
    this.baseUrl = kEarthlinkMobileBase,
  }) : username = settings.username,
       password = settings.password,
       _client = client ?? http.Client();

  final String username;
  final String password;
  final http.Client _client;
  final String baseUrl;

  String? _token;
  DateTime? _tokenExpiry;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Map<String, String> _authHeaders() => {
    'Authorization': 'Bearer ${_token ?? ''}',
    'Accept': 'application/json',
    'User-Agent': kEarthlinkUserAgent,
    'Accept-Language': 'ar-IQ;q=1.0, en-GB;q=0.9',
  };

  void _log(String message) => debugPrint('[EarthlinkMobile] $message');

  /// يسجّل الدخول ويخزّن التوكن ومدة صلاحيته (بهامش أمان 60 ثانية).
  Future<void> login() async {
    final response = await _client.post(
      _uri('/token'),
      headers: const {
        'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
        'Accept': 'application/json',
        'User-Agent': kEarthlinkUserAgent,
        'Accept-Language': 'ar-IQ;q=1.0, en-GB;q=0.9',
      },
      body: earthlinkLoginForm(username: username, password: password),
    );
    if (response.statusCode != 200) {
      throw EarthlinkException(
        'تعذّر تسجيل الدخول إلى إيرثلنك',
        statusCode: response.statusCode,
      );
    }
    final json = _decode(response.body);
    _token = parseEarthlinkToken(json);
    final seconds = parseEarthlinkExpiresIn(json);
    _tokenExpiry = DateTime.now().add(Duration(seconds: seconds - 60));
    _log('logged in');
  }

  Future<void> _ensureAuth() async {
    final expiry = _tokenExpiry;
    if (_token == null || expiry == null || DateTime.now().isAfter(expiry)) {
      await login();
    }
  }

  dynamic _decode(String body) {
    if (body.trim().isEmpty) return null;
    try {
      return jsonDecode(body);
    } catch (_) {
      throw const EarthlinkException('رد غير مقروء من إيرثلنك');
    }
  }

  Future<dynamic> _get(String path) async {
    await _ensureAuth();
    final response = await _client.get(_uri(path), headers: _authHeaders());
    if (response.statusCode == 401) {
      throw const EarthlinkException('انتهت جلسة إيرثلنك');
    }
    return _decode(response.body);
  }

  Future<dynamic> _postForm(String path, Map<String, String> form) async {
    await _ensureAuth();
    final response = await _client.post(
      _uri(path),
      headers: {
        ..._authHeaders(),
        'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
      },
      body: form,
    );
    if (response.statusCode == 401) {
      throw const EarthlinkException('انتهت جلسة إيرثلنك');
    }
    return _decode(response.body);
  }

  Future<List<EarthlinkMobilePlan>> fetchPlans() async =>
      parseEarthlinkMobilePlans(await _get('/accounts/all'));

  Future<double> fetchBalance() async =>
      parseEarthlinkBalance(await _get('/affiliate/deposit/balance'));

  Future<EarthlinkMobileUser> fetchSubscriber(String userId) async =>
      parseEarthlinkUserDetail(await _get('/user/$userId'));

  Future<({List<EarthlinkMobileUser> users, int total})> fetchSubscriberPage({
    int startIndex = 0,
    int rowCount = 50,
    String orderBy = '',
    bool orderDescending = false,
  }) async {
    final json = await _postForm('/user/all', {
      'StartIndex': '$startIndex',
      'RowCount': '$rowCount',
      'OrderBy': orderBy,
      'OrderDescending': orderDescending ? 'true' : 'false',
    });
    return parseEarthlinkUserList(json);
  }

  /// كل المشتركين عبر الصفحات حتى بلوغ العدد الكلي.
  Future<List<EarthlinkMobileUser>> fetchAllSubscribers({
    int pageSize = 50,
    int maxPages = 60,
  }) async {
    final byId = <String, EarthlinkMobileUser>{};
    for (var page = 0; page < maxPages; page++) {
      final result = await fetchSubscriberPage(
        startIndex: page * pageSize,
        rowCount: pageSize,
      );
      if (result.users.isEmpty) break;
      final before = byId.length;
      for (final u in result.users) {
        byId[u.userId] = u;
      }
      final reachedTotal = result.total > 0 && byId.length >= result.total;
      if (byId.length == before || result.users.length < pageSize ||
          reachedTotal) {
        break;
      }
    }
    return byId.values.toList();
  }

  Future<EarthlinkCost> accountCost(int accountIndex) async =>
      parseEarthlinkCost(
        await _postForm('/affiliate/deposit/accountCost', {
          'AccountID': '$accountIndex',
        }),
      );

  Future<EarthlinkMobileResult> changeAccount({
    required String userId,
    required int accountIndex,
  }) async => parseEarthlinkActionResult(
    await _postForm('/user/chnageaccounttype', {
      'UserId': userId,
      'AccountIndex': '$accountIndex',
    }),
  );

  Future<EarthlinkMobileResult> extend(String userId) async =>
      parseEarthlinkActionResult(
        await _postForm('/user/extend/$userId', {'UserID': userId}),
      );

  /// التعبئة/التجديد من رصيد الوكيل.
  ///
  /// ⚠️ **غير مؤكّد بعد:** بُني من التقاط لعملية فاشلة فقط (نعرف الحقول وشكل
  /// الرد، لا إشارة النجاح على عملية ناجحة). يلزم التقاط تعبئة ناجحة قبل
  /// الاعتماد عليه في الإنتاج. راجع [[netagent-earthlink]].
  Future<EarthlinkMobileResult> refillDeposit({
    required String userId,
    required String customerId,
    required String mobileNumber,
    required String depositPassword,
  }) async => parseEarthlinkActionResult(
    await _postForm('/user/newrefilldeposit', {
      'UserId': userId,
      'customerId': customerId,
      'MobileNumber': mobileNumber,
      'DepositPassword': depositPassword,
    }),
  );

  /// يسجّل الدخول عبر تطبيق إيرثلنك (بلا VPN) ويزامن كل المشتركين. يعيد العدد،
  /// أو null إن لم تكتمل إعدادات الربط.
  static Future<int?> syncSaved() async {
    final settings = await EarthlinkResellerSettings.load();
    if (!settings.isComplete) return null;
    final service = EarthlinkMobileService.fromSettings(settings);
    try {
      await service.login();
      final users = await service.fetchAllSubscribers();
      return await service.syncSubscribers(users);
    } finally {
      service.dispose();
    }
  }

  /// يكتب/يحدّث مشتركي إيرثلنك في AppStore (source=earthlink, uid).
  Future<int> syncSubscribers(List<EarthlinkMobileUser> users) async {
    await TrialGuardService.ensureEarthlinkAllowed(username);
    var changed = 0;
    for (final u in users) {
      final sub = u.toSubscriber();
      final index = AppStore.subscribers.indexWhere(
        (item) => item.source == 'earthlink' && item.sasId == u.userId,
      );
      if (index < 0) {
        AppStore.subscribers.add(sub);
      } else {
        AppStore.subscribers[index]
          ..name = sub.name
          ..phone = sub.phone
          ..type = sub.type
          ..endDate = sub.endDate
          ..active = sub.active
          ..sasData = sub.sasData;
      }
      changed++;
    }
    await AppStore.save();
    _log('sync complete: $changed subscribers');
    return changed;
  }

  void dispose() => _client.close();
}
