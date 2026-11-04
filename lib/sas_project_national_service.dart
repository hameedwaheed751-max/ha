import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class SasProjectNationalSettings {
  const SasProjectNationalSettings({
    required this.username,
    required this.password,
    this.baseUrl = 'https://admin.ftth.iq',
    this.clientApp = '53d57a7f-3f89-4e9d-873b-3d071bc6dd9f',
    this.userRole = '0',
  });

  final String username;
  final String password;
  final String baseUrl;
  final String clientApp;
  final String userRole;

  static const _baseUrlKey = 'ftth_sas_base_url';
  static const _usernameKey = 'ftth_sas_username';
  static const _passwordKey = 'ftth_sas_password';
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  static Future<SasProjectNationalSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    String password = '';
    try {
      password = await _secureStorage.read(key: _passwordKey) ?? '';
    } catch (_) {
      password = prefs.getString(_passwordKey) ?? '';
    }
    return SasProjectNationalSettings(
      baseUrl: prefs.getString(_baseUrlKey) ?? 'https://admin.ftth.iq',
      username: prefs.getString(_usernameKey) ?? '',
      password: password,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, baseUrl.trim());
    await prefs.setString(_usernameKey, username.trim());
    try {
      await _secureStorage.write(key: _passwordKey, value: password);
      await prefs.remove(_passwordKey);
    } catch (_) {
      await prefs.setString(_passwordKey, password);
    }
  }
}

class SasProjectNationalData {
  const SasProjectNationalData({
    required this.customers,
    required this.subscriptions,
    required this.sessions,
  });

  final List<Map<String, dynamic>> customers;
  final List<Map<String, dynamic>> subscriptions;
  final List<Map<String, dynamic>> sessions;
}

class SasProjectNationalSyncResult {
  const SasProjectNationalSyncResult({
    required this.read,
    required this.added,
    required this.updated,
  });

  final int read;
  final int added;
  final int updated;
}

/// طرق الدفع التي يعرضها موقع FTTH عند تجديد الاشتراك.
enum FtthPaymentMethod {
  card('الماستر (بطاقة Tabadul)'),
  customerWallet('رصيد المشترك'),
  partnerWallet('رصيد الوكيل');

  const FtthPaymentMethod(this.label);
  final String label;

  /// قيمة رصيد الوكيل لم تُسجَّل بعد من الموقع، فتبقى معطلة حتى نتأكد منها.
  bool get available => this != FtthPaymentMethod.partnerWallet;

  /// الدفع بالمحفظة يفعّل مباشرة، والبطاقة تنتظر إكمال الدفع خارج التطبيق.
  bool get waitsForPayment => this == FtthPaymentMethod.card;

  static FtthPaymentMethod? fromName(String? name) {
    for (final method in values) {
      if (method.name == name) return method;
    }
    return null;
  }
}

/// بيانات الاشتراك كما يقرؤها موقع FTTH قبل التجديد.
class FtthSubscriptionDetail {
  const FtthSubscriptionDetail({
    required this.subscriptionId,
    required this.customerId,
    required this.partnerId,
    required this.bundleId,
    required this.services,
    required this.commitmentPeriodValue,
    required this.expiresAt,
  });

  final String subscriptionId;
  final String customerId;
  final String partnerId;
  final String bundleId;
  final List<Map<String, String>> services;
  final int commitmentPeriodValue;
  final DateTime? expiresAt;

  bool get expired =>
      expiresAt == null || !expiresAt!.isAfter(DateTime.now().toUtc());

  /// الخطة الأساسية الحالية، وقد تكون خطة قديمة لم تعد تُباع مثل FIBER 40.
  String get basePlanId =>
      services
          .firstWhere(
            (s) => s['type'] == 'Base',
            orElse: () => const {},
          )['value']
          ?.toString() ??
      '';

  factory FtthSubscriptionDetail.fromModel(
    String subscriptionId,
    Map<String, dynamic> model,
  ) {
    String idOf(dynamic node) =>
        node is Map ? (node['id'] ?? '').toString().trim() : '';
    final applicable = model['applicableSubscription'];
    final variants = applicable is Map ? applicable['variants'] : null;
    final services = <Map<String, String>>[
      if (variants is List)
        for (final variant in variants.whereType<Map>())
          if (idOf(variant).isNotEmpty && variant['type'] is Map)
            {
              'value': idOf(variant),
              'type': (variant['type']['displayValue'] ?? '').toString(),
            },
    ];
    return FtthSubscriptionDetail(
      subscriptionId: subscriptionId,
      customerId: idOf(model['customer']),
      partnerId: idOf(model['partner']),
      bundleId: applicable is Map
          ? (applicable['bundleId'] ?? '').toString().trim()
          : '',
      services: services,
      commitmentPeriodValue:
          int.tryParse('${model['commitmentPeriodValue'] ?? ''}') ?? 1,
      expiresAt: SasProjectNationalService._parseDate(model['expiredAt']),
    );
  }
}

/// خطة يبيعها FTTH الآن، كما تعرضها خطوة اختيار الباقة في الموقع.
class FtthPlan {
  const FtthPlan({
    required this.basePlanId,
    required this.bundleId,
    required this.name,
    required this.speed,
    required this.vasIds,
  });

  final String basePlanId;
  final String bundleId;
  final String name;
  final String speed;

  /// الخدمات الإضافية المسموحة مع هذه الخطة لهذا الاشتراك.
  final Set<String> vasIds;

  String get label => speed.isEmpty ? name : '$name — $speed';

  static FtthPlan? fromJson(dynamic json) {
    if (json is! Map) return null;
    final id = (json['basePlanId'] ?? '').toString().trim();
    final bundleId = (json['bundleId'] ?? '').toString().trim();
    if (id.isEmpty || bundleId.isEmpty) return null;
    final variants = json['variants'];
    return FtthPlan(
      basePlanId: id,
      bundleId: bundleId,
      name: (json['planName'] ?? id).toString(),
      speed: (json['speed'] ?? '').toString(),
      vasIds: {
        if (variants is List)
          for (final v in variants.whereType<Map>())
            if (v['type'] is Map && v['type']['displayValue'] == 'Vas')
              (v['id'] ?? '').toString(),
      },
    );
  }
}

/// ما سيُطلب من FTTH: الخطة والخدمات وعدد الأشهر، وهل هو تجديد أم تغيير.
class FtthRenewalOrder {
  const FtthRenewalOrder({
    required this.bundleId,
    required this.basePlanId,
    required this.services,
    required this.commitmentPeriodValue,
    required this.renew,
  });

  final String bundleId;
  final String basePlanId;
  final List<Map<String, String>> services;
  final int commitmentPeriodValue;

  /// موقع FTTH يجدد بنفس الخطة إن سمح الاشتراك بالتجديد، وإلا يطلب "تغيير".
  final bool renew;

  String get planOperationType => renew ? 'Renew' : 'Change';

  factory FtthRenewalOrder.current(FtthSubscriptionDetail detail) =>
      FtthRenewalOrder(
        bundleId: detail.bundleId,
        basePlanId: detail.basePlanId,
        services: detail.services,
        commitmentPeriodValue: detail.commitmentPeriodValue,
        renew: true,
      );
}

/// ما يحتاجه الوكيل لاختيار الخطة والمدة وطريقة التفعيل.
class FtthActivationQuote {
  const FtthActivationQuote({
    required this.detail,
    required this.price,
    required this.partnerBalance,
    required this.customerBalance,
    this.selectedOrder,
    this.plans = const [],
    this.commitmentPeriods = const [],
    this.renewAllowed,
  });

  final FtthSubscriptionDetail detail;
  final double price;
  final double? partnerBalance;
  final double? customerBalance;

  /// الطلب الذي حُسب له السعر؛ null يعني الخطة الحالية كما هي.
  final FtthRenewalOrder? selectedOrder;
  final List<FtthPlan> plans;
  final List<int> commitmentPeriods;

  /// null حين تعذرت قراءة الإجراءات المسموحة من FTTH.
  final bool? renewAllowed;

  FtthRenewalOrder get order =>
      selectedOrder ?? FtthRenewalOrder.current(detail);

  /// الخطة الحالية إن كانت ما تزال تُباع، وإلا BASIC أو أول خطة متاحة.
  FtthPlan? get defaultPlan {
    for (final id in [detail.basePlanId, 'BASIC']) {
      for (final plan in plans) {
        if (plan.basePlanId == id) return plan;
      }
    }
    return plans.isEmpty ? null : plans.first;
  }

  bool get currentPlanSold =>
      plans.isEmpty || plans.any((p) => p.basePlanId == detail.basePlanId);

  int get defaultPeriod {
    if (commitmentPeriods.isEmpty ||
        commitmentPeriods.contains(detail.commitmentPeriodValue)) {
      return detail.commitmentPeriodValue;
    }
    return commitmentPeriods.contains(1) ? 1 : commitmentPeriods.first;
  }

  /// يبني الطلب كما يبنيه موقع FTTH: الخطة الأساسية ثم الخدمات الإضافية
  /// الحالية التي تسمح بها الخطة المختارة.
  FtthRenewalOrder orderFor(FtthPlan? plan, int months) {
    if (plan == null) {
      final current = FtthRenewalOrder.current(detail);
      return FtthRenewalOrder(
        bundleId: current.bundleId,
        basePlanId: current.basePlanId,
        services: current.services,
        commitmentPeriodValue: months,
        renew: renewAllowed != false,
      );
    }
    return FtthRenewalOrder(
      bundleId: plan.bundleId,
      basePlanId: plan.basePlanId,
      services: [
        {'value': plan.basePlanId, 'type': 'Base'},
        for (final service in detail.services)
          if (service['type'] == 'Vas' &&
              plan.vasIds.contains(service['value']))
            service,
      ],
      commitmentPeriodValue: months,
      renew:
          renewAllowed != false &&
          plan.basePlanId == detail.basePlanId &&
          plan.bundleId == detail.bundleId &&
          months == detail.commitmentPeriodValue,
    );
  }

  FtthActivationQuote withOrder(FtthRenewalOrder order, double price) =>
      FtthActivationQuote(
        detail: detail,
        price: price,
        partnerBalance: partnerBalance,
        customerBalance: customerBalance,
        selectedOrder: order,
        plans: plans,
        commitmentPeriods: commitmentPeriods,
        renewAllowed: renewAllowed,
      );

  double? balanceFor(FtthPaymentMethod method) => switch (method) {
    FtthPaymentMethod.card => null,
    FtthPaymentMethod.customerWallet => customerBalance,
    FtthPaymentMethod.partnerWallet => partnerBalance,
  };

  bool canUse(FtthPaymentMethod method) {
    if (!method.available) return false;
    final balance = balanceFor(method);
    return balance == null && method == FtthPaymentMethod.card ||
        balance != null && balance + 0.0001 >= price;
  }
}

class FtthActivationResult {
  const FtthActivationResult({
    required this.method,
    required this.paymentUrl,
    required this.orderNumber,
  });

  final FtthPaymentMethod method;
  final String paymentUrl;
  final String orderNumber;
}

/// طلب تجديد أُرسل ولم يتأكد تغيّر الاشتراك بعد، فلا يُرسل غيره حتى يُحسم.
class FtthPendingActivation {
  const FtthPendingActivation({
    required this.method,
    required this.price,
    required this.previousExpiresAt,
    required this.createdAt,
    this.paymentUrl = '',
    this.orderNumber = '',
  });

  final FtthPaymentMethod method;
  final double price;
  final DateTime? previousExpiresAt;
  final DateTime createdAt;
  final String paymentUrl;
  final String orderNumber;

  /// يتأكد التجديد حين يصبح تاريخ الانتهاء أبعد مما كان عند الإرسال.
  bool confirmedBy(FtthSubscriptionDetail detail) {
    final now = detail.expiresAt;
    if (now == null) return false;
    final before = previousExpiresAt;
    return before == null
        ? now.isAfter(createdAt.toUtc())
        : now.isAfter(before);
  }

  Map<String, dynamic> toJson() => {
    'method': method.name,
    'price': price,
    'previousExpiresAt': previousExpiresAt?.toUtc().toIso8601String(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'paymentUrl': paymentUrl,
    'orderNumber': orderNumber,
  };

  static FtthPendingActivation? fromJson(dynamic json) {
    if (json is! Map) return null;
    final method = FtthPaymentMethod.fromName(json['method']?.toString());
    final createdAt = SasProjectNationalService._parseDate(json['createdAt']);
    if (method == null || createdAt == null) return null;
    return FtthPendingActivation(
      method: method,
      price: SasProjectNationalService._asDouble(json['price']) ?? 0,
      previousExpiresAt: SasProjectNationalService._parseDate(
        json['previousExpiresAt'],
      ),
      createdAt: createdAt.toLocal(),
      paymentUrl: (json['paymentUrl'] ?? '').toString(),
      orderNumber: (json['orderNumber'] ?? '').toString(),
    );
  }
}

class SasProjectNationalService {
  SasProjectNationalService(this.settings, {http.Client? client})
    : _client = client ?? http.Client(),
      _baseUrl = _normalizeBaseUrl(settings.baseUrl);

  final SasProjectNationalSettings settings;
  final http.Client _client;
  final String _baseUrl;
  String? _accessToken;
  String? _refreshToken;

  void _log(String message) {
    debugPrint('[FTTH SAS] $message');
  }

  /// مفاتيح يكتبها التطبيق في sasData ولا تأتي من FTTH، فتبقى عند المزامنة.
  static const pendingActivationKey = 'ftth_pending_activation';
  static const localSasKeys = [
    pendingActivationKey,
    'local_activation_date',
    'activation_date',
  ];

  bool get isAuthenticated => _accessToken?.isNotEmpty == true;
  String? get accessToken => _accessToken;
  String? get refreshToken => _refreshToken;

  static String _normalizeBaseUrl(String value) {
    final normalized = value.trim().replaceFirst(RegExp(r'/+$'), '');
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, 'baseUrl', 'Base URL cannot be empty');
    }
    final uri = Uri.parse(normalized);
    if (uri.scheme != 'https' || uri.host.isEmpty) {
      throw ArgumentError.value(
        value,
        'baseUrl',
        'Base URL must be an HTTPS URL',
      );
    }
    return normalized;
  }

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final cleanPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$_baseUrl$cleanPath').replace(queryParameters: query);
  }

  Map<String, String> _headers({bool authenticated = true}) {
    return {
      'Accept': 'application/json, text/plain, */*',
      'X-Client-App': settings.clientApp,
      'X-User-Role': settings.userRole,
      if (authenticated && isAuthenticated)
        'Authorization': 'Bearer $_accessToken',
    };
  }

  /// موقع FTTH يسمح للمتصفح بكل الرؤوس عبر `*`، والمتصفحات لا تعدّ ذلك
  /// سماحاً بـ Authorization، فتُحجب كل الطلبات بعد الدخول. وبروكسي الويب
  /// لا يصل إلى admin.ftth.iq (يرد 520)، لذلك يعمل FTTH من تطبيق الهاتف فقط.
  static const webUnsupportedMessage =
      'ساس المشروع الوطني لا يعمل من المتصفح لأن موقع FTTH يمنع ذلك. '
      'استخدم تطبيق أندرويد للمزامنة والتفعيل.';

  Future<void> login() async {
    if (kIsWeb) {
      throw const SasProjectNationalException(webUnsupportedMessage);
    }
    _log('login start: POST /api/auth/Contractor/token');
    final response = await _client
        .post(
          _uri('/api/auth/Contractor/token'),
          headers: {
            'Accept': 'application/json, text/plain, */*',
            'Content-Type': 'application/x-www-form-urlencoded',
            'X-Client-App': settings.clientApp,
            'X-User-Role': settings.userRole,
          },
          body: {
            'grant_type': 'password',
            'scope': 'openid profile',
            'client_id': '',
            'username': settings.username.trim(),
            'password': settings.password,
          },
        )
        .timeout(const Duration(seconds: 45));

    _log('login response: HTTP ${response.statusCode}');
    final data = _decodeObject(response, 'FTTH login');
    final accessToken = (data['access_token'] ?? data['token'] ?? '')
        .toString()
        .trim();
    if (accessToken.isEmpty) {
      throw SasProjectNationalException(
        'FTTH login response did not contain an access token',
        statusCode: response.statusCode,
      );
    }
    _accessToken = accessToken;
    _refreshToken = data['refresh_token']?.toString();
    _log('login success: access token received');
  }

  Future<SasProjectNationalData> fetchSubscriberData({
    int pageSize = 100,
  }) async {
    _log('sync start');
    final customers = await fetchCustomers(pageSize: pageSize);
    _log('customers loaded: ${customers.length}');
    final subscriptions = await fetchSubscriptions(pageSize: pageSize);
    _log('subscriptions loaded: ${subscriptions.length}');
    final sessions = await fetchSessions(pageSize: pageSize);
    _log('sessions loaded: ${sessions.length}');
    return SasProjectNationalData(
      customers: customers,
      subscriptions: subscriptions,
      sessions: sessions,
    );
  }

  Future<SasProjectNationalSyncResult> syncSubscribers({
    SasProjectNationalData? data,
  }) async {
    final snapshot = data ?? await fetchSubscriberData();
    final customersById = <String, Map<String, dynamic>>{};
    for (final customer in snapshot.customers) {
      final self = customer['self'];
      if (self is Map && self['id'] != null) {
        customersById[self['id'].toString()] = customer;
      }
    }

    var added = 0;
    var updated = 0;
    for (final subscription in snapshot.subscriptions) {
      final customerRef = subscription['customer'];
      final customerId = customerRef is Map
          ? (customerRef['id'] ?? '').toString()
          : '';
      final customer = customersById[customerId] ?? const <String, dynamic>{};
      final primaryContact = customer['primaryContact'];
      final self = customer['self'];
      final customerName = customerRef is Map
          ? (customerRef['displayValue'] ?? '').toString()
          : '';
      final name = customerName.isNotEmpty
          ? customerName
          : self is Map
          ? (self['displayValue'] ?? '').toString()
          : '';
      final username = (subscription['username'] ?? '').toString().trim();
      final subscriptionId =
          (subscription['self'] is Map
                  ? subscription['self']['id']
                  : subscription['id'])
              ?.toString()
              .trim();
      final startDate = _parseDate(subscription['startedAt']) ?? DateTime.now();
      final endDate = _parseDate(subscription['expires']) ?? startDate;
      final bundle = subscription['bundle'];
      final type = bundle is Map
          ? (bundle['displayValue'] ?? bundle['id'] ?? '').toString()
          : '';
      final activeSession = subscription['activeSession'];
      final ip = activeSession is Map
          ? (activeSession['ipAddress'] ?? '').toString()
          : (subscription['ipAddress'] ?? '').toString();
      final online = subscription['hasActiveSession'] == true;
      final phone = primaryContact is Map
          ? (primaryContact['mobile'] ??
                    primaryContact['phone'] ??
                    primaryContact['secondaryPhone'] ??
                    '')
                .toString()
          : '';
      final user = username.isNotEmpty
          ? username
          : (customerId.isNotEmpty ? customerId : name);
      if (user.trim().isEmpty) continue;

      final sasData = <String, dynamic>{
        'provider': 'ساس المشروع الوطني',
        'customer_id': customerId,
        'subscription_id': subscriptionId ?? '',
        'status': subscription['status'],
        'bundle': bundle,
        'startedAt': subscription['startedAt'],
        'expires': subscription['expires'],
        'activeSession': activeSession,
        'rawCustomer': customer,
        'rawSubscription': subscription,
      };
      final next = Subscriber(
        user: user,
        name: name,
        phone: phone,
        address: '',
        ip: ip,
        type: type,
        price: 0,
        startDate: startDate,
        endDate: endDate,
        active: subscription['status']?.toString().toLowerCase() == 'active',
        source: 'ftth',
        sasId: subscriptionId ?? customerId,
        sasOnline: online,
        sasData: sasData,
      );

      final index = AppStore.subscribers.indexWhere(
        (item) =>
            item.source == 'ftth' &&
            item.sasId.isNotEmpty &&
            item.sasId == next.sasId,
      );
      if (index < 0) {
        AppStore.subscribers.add(next);
        added++;
      } else {
        final existing = AppStore.subscribers[index];
        existing
          ..user = next.user
          ..name = next.name
          ..phone = next.phone
          ..ip = next.ip
          ..type = next.type
          ..startDate = next.startDate
          ..endDate = next.endDate
          ..active = next.active
          ..disabled = next.disabled
          ..sasOnline = next.sasOnline
          ..sasData = {
            for (final key in localSasKeys)
              if (existing.sasData.containsKey(key)) key: existing.sasData[key],
            ...next.sasData,
          };
        updated++;
      }
    }
    await AppStore.save();
    _log('app sync complete: added=$added updated=$updated');
    return SasProjectNationalSyncResult(
      read: snapshot.subscriptions.length,
      added: added,
      updated: updated,
    );
  }

  static DateTime? _parseDate(dynamic value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : DateTime.tryParse(text);
  }

  Future<List<Map<String, dynamic>>> fetchCustomers({int pageSize = 100}) {
    return _fetchPage('/api/customers', pageSize: pageSize);
  }

  Future<List<Map<String, dynamic>>> fetchSubscriptions({
    int pageSize = 100,
  }) async {
    final all = <String, Map<String, dynamic>>{};
    for (final status in ['Active', 'Expired']) {
      final rows = await _fetchPage(
        '/api/subscriptions',
        pageSize: pageSize,
        status: status,
      );
      for (final row in rows) {
        final self = row['self'];
        final id = self is Map ? self['id']?.toString() : row['id']?.toString();
        all[id ?? '${all.length}'] = row;
      }
    }
    return all.values.toList();
  }

  Future<List<Map<String, dynamic>>> fetchSessions({int pageSize = 100}) {
    return _fetchPage('/api/sessions', pageSize: pageSize);
  }

  Future<FtthSubscriptionDetail> fetchSubscription({
    required String subscriptionId,
    required String customerId,
  }) async {
    final id = subscriptionId.trim();
    if (id.isEmpty) {
      throw const SasProjectNationalException('معرّف اشتراك FTTH غير موجود');
    }
    final data = await _getJson(
      '/api/subscriptions/$id',
      query: {if (customerId.trim().isNotEmpty) 'customerId': customerId},
    );
    final model = data is Map ? data['model'] : null;
    if (model is! Map) {
      throw const SasProjectNationalException(
        'لم يرجع موقع FTTH بيانات الاشتراك',
      );
    }
    final detail = FtthSubscriptionDetail.fromModel(
      id,
      Map<String, dynamic>.from(model),
    );
    if (detail.bundleId.isEmpty || detail.services.isEmpty) {
      throw const SasProjectNationalException(
        'لم يرجع موقع FTTH باقة الاشتراك أو خدماته',
      );
    }
    return detail;
  }

  /// السعر الذي سيخصمه FTTH، بعد العروض، كما تحسبه صفحة التجديد.
  Future<double> calculatePrice(
    FtthSubscriptionDetail detail, {
    FtthRenewalOrder? order,
  }) async {
    final o = order ?? FtthRenewalOrder.current(detail);
    final data = await _getJson(
      '/api/subscriptions/calculate-price',
      query: {
        'bundleId': o.bundleId,
        'commitmentPeriodValue': '${o.commitmentPeriodValue}',
        'planOperationType': o.planOperationType,
        'subscriptionId': detail.subscriptionId,
        'services': [for (final service in o.services) jsonEncode(service)],
        'salesType': '0',
      },
    );
    final model = data is Map ? data['model'] : null;
    final total = model is Map ? model['totalPrice'] : null;
    final price = total is Map ? _asDouble(total['value']) : null;
    if (price == null || price <= 0) {
      throw const SasProjectNationalException('لم يرجع موقع FTTH سعر التجديد');
    }
    return price;
  }

  /// الخطط وفترات الالتزام التي يعرضها FTTH لهذا الاشتراك.
  Future<({List<FtthPlan> plans, List<int> periods})> fetchPlans(
    String subscriptionId,
  ) async {
    final data = await _getJson(
      '/api/plans/bundles',
      query: {'includePrices': 'false', 'subscriptionId': subscriptionId},
    );
    final plans = <FtthPlan>[];
    final periods = <int>{};
    for (final item in _extractRows(data)) {
      final subs = item['applicableSubscriptions'];
      if (subs is List) plans.addAll(subs.map(FtthPlan.fromJson).nonNulls);
      final months = item['commitmentPeriods'];
      if (months is List) {
        periods.addAll(months.map((m) => int.tryParse('$m')).nonNulls);
      }
    }
    return (plans: plans, periods: periods.toList()..sort());
  }

  /// هل يسمح FTTH بـ"تجديد" الاشتراك. الاشتراكات على خطط قديمة لا تسمح إلا
  /// بـ"تغيير" الخطة.
  Future<bool?> fetchRenewAllowed({
    required String subscriptionId,
    required String customerId,
  }) async {
    final data = await _getJson(
      '/api/subscriptions/allowed-actions',
      query: {
        'subscriptionIds': subscriptionId,
        if (customerId.trim().isNotEmpty) 'customerId': customerId,
      },
    );
    for (final item in _extractRows(data)) {
      if ('${item['subscriptionId']}' != subscriptionId) continue;
      final actions = item['allowedActions'];
      if (actions is! List) return null;
      return actions.whereType<Map>().any((a) => a['displayValue'] == 'Renew');
    }
    return null;
  }

  Future<double?> fetchPartnerBalance(String partnerId) =>
      _fetchBalance('/api/partners/${partnerId.trim()}/wallets/balance');

  Future<double?> fetchCustomerBalance(String customerId) =>
      _fetchBalance('/api/customers/${customerId.trim()}/wallets/balance');

  Future<double?> _fetchBalance(String path) async {
    final data = await _getJson(path);
    final model = data is Map ? data['model'] : null;
    return model is Map ? _asDouble(model['balance']) : null;
  }

  /// يجمع ما تحتاجه نافذة التفعيل. تعذر قراءة رصيد يعطّل خياره فقط.
  Future<FtthActivationQuote> fetchActivationQuote({
    required String subscriptionId,
    required String customerId,
  }) async {
    final detail = await fetchSubscription(
      subscriptionId: subscriptionId,
      customerId: customerId,
    );
    Future<T?> safely<T>(String what, Future<T?> Function() read) async {
      try {
        return await read();
      } catch (error) {
        _log('$what read failed: $error');
        return null;
      }
    }

    // تعذر قراءة الخطط أو الإجراءات لا يمنع التفعيل بنفس الخطة الحالية.
    final catalog = await safely(
      'plans',
      () => fetchPlans(detail.subscriptionId),
    );
    final renewAllowed = await safely(
      'allowed actions',
      () => fetchRenewAllowed(
        subscriptionId: detail.subscriptionId,
        customerId: detail.customerId.isNotEmpty
            ? detail.customerId
            : customerId,
      ),
    );
    final partnerBalance = detail.partnerId.isEmpty
        ? null
        : await safely(
            'partner balance',
            () => fetchPartnerBalance(detail.partnerId),
          );
    final customerBalance = detail.customerId.isEmpty
        ? null
        : await safely(
            'customer balance',
            () => fetchCustomerBalance(detail.customerId),
          );
    final base = FtthActivationQuote(
      detail: detail,
      price: 0,
      partnerBalance: partnerBalance,
      customerBalance: customerBalance,
      plans: catalog?.plans ?? const [],
      commitmentPeriods: catalog?.periods ?? const [],
      renewAllowed: renewAllowed,
    );
    final order = base.orderFor(base.defaultPlan, base.defaultPeriod);
    return base.withOrder(order, await calculatePrice(detail, order: order));
  }

  /// يرسل طلب التجديد مرة واحدة فقط، ولا يعيده تلقائياً عند الفشل أو انتهاء المهلة.
  Future<FtthActivationResult> activateSubscription({
    required FtthSubscriptionDetail detail,
    required double price,
    required FtthPaymentMethod method,
    FtthRenewalOrder? order,
  }) async {
    if (!method.available) {
      throw SasProjectNationalException('${method.label} غير متاح بعد');
    }
    final id = detail.subscriptionId;
    final o = order ?? FtthRenewalOrder.current(detail);
    final body = <String, dynamic>{
      'simulatedPrice': price,
      'bundleId': o.bundleId,
      'services': o.services,
      'commitmentPeriodValue': o.commitmentPeriodValue,
      'salesType': 0,
      'paymentDetails': switch (method) {
        FtthPaymentMethod.card => {
          'paymentMethod': 'Tabadul',
          'statusPageBaseUrl': '$_baseUrl/page/tabadul-payment-status',
        },
        FtthPaymentMethod.customerWallet => {
          'paymentMethod': 'Wallet',
          'walletSource': 'Customer',
        },
        FtthPaymentMethod.partnerWallet => {
          'paymentMethod': 'Wallet',
          'walletSource': 'Partner',
        },
      },
      'changeType': 1,
    };

    final data = await _postJson(
      '/api/subscriptions/$id/change',
      body,
      referer:
          '$_baseUrl/subscriptions/item/$id/customer/${detail.customerId}/renew-subscription',
    );
    final map = data is Map ? data : const {};
    final paymentUrl = (map['paymentUrl'] ?? '').toString().trim();
    final orderNumber = (map['orderNumber'] ?? '').toString().trim();
    if (method.waitsForPayment && paymentUrl.isEmpty) {
      throw const SasProjectNationalException('لم يرجع موقع FTTH رابط الدفع');
    }
    return FtthActivationResult(
      method: method,
      paymentUrl: paymentUrl,
      orderNumber: orderNumber,
    );
  }

  /// يلغي طلب دفع بالبطاقة لم يُكمل.
  Future<void> cancelOrder(String orderNumber) async {
    await _postJson('/api/orders/cancel', {'orderNumber': orderNumber});
  }

  static double? _asDouble(dynamic value) =>
      value is num ? value.toDouble() : double.tryParse('${value ?? ''}');

  static const _maxPages = 200;

  Future<List<Map<String, dynamic>>> _fetchPage(
    String path, {
    required int pageSize,
    String? status,
  }) async {
    if (pageSize <= 0) {
      throw ArgumentError.value(pageSize, 'pageSize', 'Must be positive');
    }
    final all = <Map<String, dynamic>>[];
    for (var page = 1; page <= _maxPages; page++) {
      final data = await _getJson(
        path,
        query: {
          'pageSize': '$pageSize',
          'pageNumber': '$page',
          if (path == '/api/customers') ...{
            'sortCriteria.property': 'self.displayValue',
            'sortCriteria.direction': 'asc',
          },
          if (path == '/api/subscriptions') ...{
            'sortCriteria.property': 'expires',
            'sortCriteria.direction': 'asc',
            ...?status == null ? null : {'status': status},
            'hierarchyLevel': '0',
          },
          if (path == '/api/sessions') ...{
            'sortCriteria.property': 'username',
            'sortCriteria.direction': 'asc',
            'status': '1',
            'hierarchyLevel': '0',
          },
        },
      );
      final rows = _extractRows(data);
      all.addAll(rows);
      final total = data is Map ? int.tryParse('${data['totalCount']}') : null;
      if (rows.length < pageSize || (total != null && all.length >= total)) {
        break;
      }
    }
    return all;
  }

  Future<dynamic> _getJson(String path, {Map<String, dynamic>? query}) {
    return _send(
      'GET $path',
      () => _client.get(_uri(path, query), headers: _headers()),
    );
  }

  Future<dynamic> _postJson(
    String path,
    Map<String, dynamic> body, {
    String? referer,
  }) {
    return _send(
      'POST $path',
      () => _client.post(
        _uri(path),
        headers: {
          ..._headers(),
          'Content-Type': 'application/json',
          'Origin': _baseUrl,
          'Referer': ?referer,
        },
        body: jsonEncode(body),
      ),
    );
  }

  /// يسجل الدخول عند الحاجة. عند 401 يعيد الطلب مرة واحدة لأن الخادم رفضه
  /// قبل تنفيذه، فلا خطر من تكرار الخصم.
  Future<dynamic> _send(
    String operation,
    Future<http.Response> Function() request,
  ) async {
    if (!isAuthenticated) await login();
    var response = await request().timeout(const Duration(seconds: 45));
    _log('$operation response: HTTP ${response.statusCode}');
    if (response.statusCode == 401) {
      _accessToken = null;
      await login();
      response = await request().timeout(const Duration(seconds: 45));
      _log('$operation retry response: HTTP ${response.statusCode}');
    }
    if (response.statusCode >= 200 &&
        response.statusCode < 300 &&
        response.body.trim().isEmpty) {
      return null;
    }
    return _decode(response, operation);
  }

  static dynamic _decode(http.Response response, String operation) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final reason = _serverReason(response.body);
      throw SasProjectNationalException(
        '$operation failed with HTTP ${response.statusCode}'
        '${reason.isEmpty ? '' : ' — $reason'}',
        statusCode: response.statusCode,
        response: response.body.length > 300
            ? response.body.substring(0, 300)
            : response.body,
      );
    }

    dynamic data;
    try {
      data = jsonDecode(response.body);
    } catch (_) {
      throw SasProjectNationalException(
        '$operation returned invalid JSON',
        statusCode: response.statusCode,
      );
    }
    return data;
  }

  /// سبب الرفض كما يكتبه FTTH، مختصراً، ليظهر للوكيل بدل رقم الخطأ وحده.
  static String _serverReason(String body) {
    dynamic json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return '';
    }
    final parts = <String>[];
    void add(dynamic value) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty && !parts.contains(text)) parts.add(text);
    }

    if (json is Map) {
      for (final key in ['message', 'title', 'detail', 'error_description']) {
        add(json[key]);
      }
      final errors = json['errors'];
      if (errors is Map) {
        for (final value in errors.values) {
          value is List ? value.forEach(add) : add(value);
        }
      } else if (errors is List) {
        for (final e in errors) {
          add(e is Map ? (e['message'] ?? e['description'] ?? e) : e);
        }
      }
    }
    final text = parts.join(' | ');
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }

  static Map<String, dynamic> _decodeObject(
    http.Response response,
    String operation,
  ) {
    final data = _decode(response, operation);
    if (data is! Map) {
      throw SasProjectNationalException(
        '$operation returned an unexpected response',
        statusCode: response.statusCode,
        response: data,
      );
    }
    return Map<String, dynamic>.from(data);
  }

  static List<Map<String, dynamic>> _extractRows(dynamic data) {
    dynamic rows = data;
    if (data is Map) {
      for (final key in [
        'items',
        'content',
        'results',
        'data',
        'customers',
        'subscriptions',
        'sessions',
      ]) {
        if (data[key] is List) {
          rows = data[key];
          break;
        }
      }
    }
    if (rows is! List) return const [];
    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  void dispose() => _client.close();
}

class SasProjectNationalException implements Exception {
  const SasProjectNationalException(
    this.message, {
    this.statusCode,
    this.response,
  });

  final String message;
  final int? statusCode;
  final dynamic response;

  @override
  String toString() => message;
}
