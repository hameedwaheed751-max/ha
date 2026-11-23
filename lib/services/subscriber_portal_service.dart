// صلة تطبيق وكيل نت بخدمة «مشترك نت» في البوابة (/api/v1/agent/*).
// الخدمة مطفأة على الخادم حتى تُفعَّل؛ كل شيء هنا يفشل بهدوء عندها.
// العقد: C:\Mushtaraknet\docs\SUBSCRIBER_API.md

import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models.dart';
import 'user_role_service.dart';

class PortalException implements Exception {
  const PortalException(this.code, {this.statusCode});

  /// رمز الخادم، أو `portal_disabled` إذا كانت الخدمة مطفأة، أو `network`.
  final String code;
  final int? statusCode;

  String get message => switch (code) {
    'portal_disabled' => 'خدمة مشترك نت غير مفعّلة بعد',
    'phone_missing' => 'أضف رقم هاتف المشترك أولاً',
    'record_already_linked' => 'المشترك مرتبط بالتطبيق مسبقاً',
    'not_linked' => 'المشترك غير مربوط بتطبيق مشترك نت',
    'subscription_not_found' => 'احفظ المشترك ثم أعد المحاولة',
    'forbidden' => 'خدمة مشترك نت متاحة للوكلاء ذوي الاشتراك الفعّال',
    'invalid_state' => 'تغيّرت حالة الطلب، حدّث القائمة',
    'rate_limited' => 'محاولات كثيرة، انتظر قليلاً',
    'too_many_announcements' => 'وصلت إلى حد ثلاثة إعلانات في اليوم، حاول غداً',
    'network' => 'تعذر الاتصال بالخادم',
    _ => 'تعذر تنفيذ الطلب ($code)',
  };

  @override
  String toString() => message;
}

class PortalInvitation {
  const PortalInvitation({
    required this.id,
    required this.code,
    required this.maskedPhone,
    required this.expiresAt,
  });

  final String id;
  final String code;
  final String maskedPhone;
  final DateTime expiresAt;

  /// الرمز مقسوماً لسهولة القراءة: ABCD-EFGH.
  String get displayCode =>
      code.length == 8 ? '${code.substring(0, 4)}-${code.substring(4)}' : code;

  factory PortalInvitation.fromJson(Map<String, dynamic> j) => PortalInvitation(
    id: '${j['id'] ?? ''}',
    code: '${j['code'] ?? ''}',
    maskedPhone: '${j['masked_phone'] ?? ''}',
    expiresAt: DateTime.tryParse('${j['expires_at']}')?.toLocal() ?? DateTime.now(),
  );
}

class PortalRenewal {
  const PortalRenewal({
    required this.id,
    required this.number,
    required this.subscriberId,
    required this.subscriberName,
    required this.packageName,
    required this.quotedPrice,
    required this.status,
    required this.createdAt,
    this.previousEndDate,
    this.rejectReason = '',
    this.currentPackageName = '',
    this.packageChange = false,
  });

  final String id;
  final String number;
  final String subscriberId;
  final String subscriberName;
  final String packageName;
  final double quotedPrice;
  final String status;
  final DateTime createdAt;
  final DateTime? previousEndDate;
  final String rejectReason;

  /// باقة المشترك وقت الطلب؛ تختلف عن [packageName] إن طلب تغيير الباقة.
  final String currentPackageName;
  final bool packageChange;

  /// سطر الباقة في بطاقة الطلب.
  String get packageLine => packageChange
      ? 'تغيير الباقة: $currentPackageName ← $packageName'
      : packageName;

  bool get isOpen => status == 'pending' || status == 'approved';

  String get statusLabel => switch (status) {
    'pending' => 'بانتظار ردّك',
    'approved' => 'مقبول — بانتظار التفعيل',
    'completed' => 'تم التجديد',
    'rejected' => 'مرفوض',
    'cancelled' => 'ألغاه المشترك',
    'failed' => 'تعذّر التنفيذ',
    _ => status,
  };

  factory PortalRenewal.fromJson(Map<String, dynamic> j) => PortalRenewal(
    id: '${j['id'] ?? ''}',
    number: '${j['number'] ?? ''}',
    subscriberId: '${j['subscriber_id'] ?? ''}',
    subscriberName: '${j['subscriber_name'] ?? ''}',
    packageName: '${j['package_name'] ?? ''}',
    quotedPrice: (j['quoted_price'] as num?)?.toDouble() ?? 0,
    status: '${j['status'] ?? ''}',
    createdAt: DateTime.tryParse('${j['created_at']}')?.toLocal() ?? DateTime.now(),
    previousEndDate: j['previous_end_date'] == null
        ? null
        : DateTime.tryParse('${j['previous_end_date']}'),
    rejectReason: '${j['reject_reason'] ?? ''}',
    currentPackageName: '${j['current_package_name'] ?? ''}',
    packageChange: j['package_change'] == true,
  );
}

/// إعدادات مشترك نت لدى الوكيل.
class PortalSettings {
  const PortalSettings({required this.showDebt, required this.allowPackageChange});

  final bool showDebt;
  final bool allowPackageChange;

  factory PortalSettings.fromJson(Map<String, dynamic> j) => PortalSettings(
    showDebt: j['show_debt'] == true,
    allowPackageChange: j['allow_package_change'] == true,
  );
}

/// باقات الوكيل كما يراها المشترك عند طلب تغيير الباقة: الاسم والسعر فقط، بلا تكرار.
List<Map<String, dynamic>> buildPortalCatalog(Iterable<PackagePlan> packages) {
  final seen = <String>{};
  return [
    for (final p in packages)
      if (p.name.trim().isNotEmpty && seen.add(p.name.trim().toLowerCase()))
        {'name': p.name.trim(), 'price': p.price},
  ];
}

class SubscriberPortalClient {
  SubscriberPortalClient({
    required String gatewayUrl,
    required this._getIdToken,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
  }) : _base = '${gatewayUrl.trim().replaceAll(RegExp(r'/+$'), '')}/api/v1/agent',
       _client = client ?? http.Client();

  static const String _configuredGatewayUrl = String.fromEnvironment(
    'WAHA_GATEWAY_URL',
    defaultValue: 'https://netagentiraq.duckdns.org',
  );

  factory SubscriberPortalClient.forCurrentUser() => SubscriberPortalClient(
    gatewayUrl: _configuredGatewayUrl,
    getIdToken: () async => FirebaseAuth.instance.currentUser?.getIdToken(),
  );

  final String _base;
  final Future<String?> Function() _getIdToken;
  final http.Client _client;
  final Duration timeout;

  Future<dynamic> _send(String method, String path, {Object? body}) async {
    final token = await _getIdToken();
    if (token == null || token.isEmpty) {
      throw const PortalException('unauthorized', statusCode: 401);
    }
    final request = http.Request(method, Uri.parse('$_base$path'))
      ..headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    http.Response response;
    try {
      response = await http.Response.fromStream(
        await _client.send(request).timeout(timeout),
      );
    } catch (_) {
      throw const PortalException('network');
    }
    Object? decoded;
    try {
      // الردود JSON بترميز UTF-8 دائماً، حتى لو غاب charset من الترويسة.
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      decoded = null;
    }
    final envelope = decoded is Map ? decoded : null;
    if (response.statusCode == 200 && envelope?['success'] == true) {
      return envelope!['data'];
    }
    // الخدمة مطفأة: المسار غير مركّب، فيرد Express بصفحة 404 بلا غلاف JSON.
    if (response.statusCode == 404 && envelope == null) {
      throw const PortalException('portal_disabled', statusCode: 404);
    }
    throw PortalException(
      '${envelope?['error'] ?? 'server_error'}',
      statusCode: response.statusCode,
    );
  }

  Future<PortalInvitation> createInvitation(String subscriberId) async =>
      PortalInvitation.fromJson(
        Map<String, dynamic>.from(
          await _send(
            'POST',
            '/subscriber-invitations',
            body: {'subscriber_id': subscriberId},
          ) as Map,
        ),
      );

  Future<Set<String>> linkedSubscriberIds() async {
    final data = await _send('GET', '/subscriber-links') as List;
    return {for (final l in data) '${(l as Map)['subscriber_id']}'};
  }

  /// رمز إشعارات هذا الجهاز: تصله طلبات التجديد وتذاكر الدعم فوراً.
  Future<void> registerDevice(String token, {String platform = 'android'}) =>
      _send('POST', '/devices', body: {'token': token, 'platform': platform});

  Future<void> unregisterDevice(String token) =>
      _send('POST', '/devices/unregister', body: {'token': token});

  Future<void> unlink(String subscriberId) =>
      _send('DELETE', '/subscriber-links/${Uri.encodeComponent(subscriberId)}');

  Future<void> putSummary(String subscriberId, Map<String, dynamic> summary) =>
      _send(
        'PUT',
        '/subscriber-summaries/${Uri.encodeComponent(subscriberId)}',
        body: summary,
      );

  Future<bool> showDebt() async =>
      (await _send('GET', '/portal-settings') as Map)['show_debt'] == true;

  Future<void> setShowDebt(bool value) =>
      _send('PUT', '/portal-settings', body: {'show_debt': value});

  Future<PortalSettings> settings() async => PortalSettings.fromJson(
    Map<String, dynamic>.from(await _send('GET', '/portal-settings') as Map),
  );

  /// يسمح للمشترك بطلب باقة أخرى من باقات المكتب عند التجديد.
  Future<void> setAllowPackageChange(bool value) =>
      _send('PUT', '/portal-settings', body: {'allow_package_change': value});

  Future<void> putCatalog(List<Map<String, dynamic>> packages) =>
      _send('PUT', '/portal-packages', body: {'packages': packages});

  /// إعلان لكل المشتركين المربوطين؛ يعيد عدد من وصلهم.
  Future<int> announce(String text) async {
    final data = await _send('POST', '/announcements', body: {'text': text.trim()});
    return ((data as Map)['recipients'] as num?)?.toInt() ?? 0;
  }

  Future<List<PortalRenewal>> renewals({String status = ''}) async {
    final query = status.isEmpty ? '' : '?status=$status';
    final data = await _send('GET', '/renewal-requests$query') as List;
    return [
      for (final r in data) PortalRenewal.fromJson(Map<String, dynamic>.from(r as Map)),
    ];
  }

  Future<PortalRenewal> approve(String id) async => PortalRenewal.fromJson(
    Map<String, dynamic>.from(
      await _send('POST', '/renewal-requests/$id/decision', body: {'decision': 'approve'}) as Map,
    ),
  );

  Future<PortalRenewal> reject(String id, String reason) async =>
      PortalRenewal.fromJson(
        Map<String, dynamic>.from(
          await _send(
            'POST',
            '/renewal-requests/$id/decision',
            body: {'decision': 'reject', 'reason': reason},
          ) as Map,
        ),
      );

  Future<PortalRenewal> complete(String id, DateTime newEndDate) async =>
      PortalRenewal.fromJson(
        Map<String, dynamic>.from(
          await _send(
            'POST',
            '/renewal-requests/$id/result',
            body: {'result': 'completed', 'new_end_date': newEndDate.toIso8601String()},
          ) as Map,
        ),
      );

  Future<PortalRenewal> fail(String id, String note) async => PortalRenewal.fromJson(
    Map<String, dynamic>.from(
      await _send(
        'POST',
        '/renewal-requests/$id/result',
        body: {'result': 'failed', 'note': note},
      ) as Map,
    ),
  );

  Future<List<PortalTicket>> supportTickets({String status = ''}) async {
    final query = status.isEmpty ? '' : '?status=$status';
    final data = await _send('GET', '/support-tickets$query') as List;
    return [
      for (final t in data) PortalTicket.fromJson(Map<String, dynamic>.from(t as Map)),
    ];
  }

  Future<PortalTicket> replyToTicket(String id, String text) async =>
      PortalTicket.fromJson(
        Map<String, dynamic>.from(
          await _send('POST', '/support-tickets/$id/messages', body: {'text': text}) as Map,
        ),
      );

  Future<PortalTicket> closeTicket(String id) async => PortalTicket.fromJson(
    Map<String, dynamic>.from(await _send('POST', '/support-tickets/$id/close') as Map),
  );
}

class PortalTicketMessage {
  const PortalTicketMessage({
    required this.fromSubscriber,
    required this.author,
    required this.text,
    required this.at,
  });

  final bool fromSubscriber;
  final String author;
  final String text;
  final DateTime at;

  factory PortalTicketMessage.fromJson(Map<String, dynamic> j) => PortalTicketMessage(
    fromSubscriber: j['from_subscriber'] == true,
    author: '${j['author'] ?? ''}',
    text: '${j['text'] ?? ''}',
    at: DateTime.tryParse('${j['at']}')?.toLocal() ?? DateTime.now(),
  );
}

/// تذكرة دعم من مشترك مربوط بتطبيق مشترك نت.
class PortalTicket {
  const PortalTicket({
    required this.id,
    required this.number,
    required this.subscriberId,
    required this.subscriberName,
    required this.category,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.messages,
  });

  final String id;
  final String number;
  final String subscriberId;
  final String subscriberName;
  final String category;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<PortalTicketMessage> messages;

  /// المشترك ينتظر ردّ الوكيل.
  bool get awaitingAgent => status == 'open';
  bool get isClosed => status == 'closed';

  String get statusLabel => switch (status) {
    'open' => 'بانتظار ردّك',
    'answered' => 'تم الرد',
    'closed' => 'مغلقة',
    _ => status,
  };

  String get categoryLabel => switch (category) {
    'connection' => 'مشكلة اتصال',
    'subscription' => 'الاشتراك',
    'billing' => 'المحاسبة',
    'help' => 'مساعدة',
    _ => 'استفسار',
  };

  factory PortalTicket.fromJson(Map<String, dynamic> j) => PortalTicket(
    id: '${j['id'] ?? ''}',
    number: '${j['number'] ?? ''}',
    subscriberId: '${j['subscriber_id'] ?? ''}',
    subscriberName: '${j['subscriber_name'] ?? ''}',
    category: '${j['category'] ?? ''}',
    status: '${j['status'] ?? ''}',
    createdAt: DateTime.tryParse('${j['created_at']}')?.toLocal() ?? DateTime.now(),
    updatedAt: DateTime.tryParse('${j['updated_at']}')?.toLocal() ?? DateTime.now(),
    messages: [
      for (final m in (j['messages'] as List? ?? const []))
        PortalTicketMessage.fromJson(Map<String, dynamic>.from(m as Map)),
    ],
  );
}

/// الملخص المنقّى للمشترك (D5-ب): أرقام محسوبة بنفس getters التطبيق،
/// بلا اسم مستخدم الساس ولا الملاحظات ولا sasData. نقيّة.
Map<String, dynamic> buildPortalSummary(Subscriber s, {DateTime? lastSasSync}) {
  final payments = [...s.payments]..sort((a, b) => b.at.compareTo(a.at));
  final totalPaid = s.paymentsTotal;
  return {
    'subscriber_name': s.name,
    'package_name': s.type,
    'price': s.price.round(),
    'start_date': s.startDate.toIso8601String(),
    'end_date': s.endDate.toIso8601String(),
    'disabled': s.disabled,
    'connection': lastSasSync == null ? 'unknown' : (s.isOnline ? 'online' : 'offline'),
    if (lastSasSync != null) 'last_synced_at': lastSasSync.toIso8601String(),
    'finance': {
      'balance_due': s.remaining.round(),
      // المستحق = الرسوم − المدفوع، فالرسوم تُشتق من الرقمين المعروضين للوكيل.
      'total_charges': (totalPaid + s.remaining).round(),
      'total_paid': totalPaid.round(),
      'entries': [
        for (var i = 0; i < payments.length && i < 40; i++)
          {
            'id': 'p${payments[i].at.millisecondsSinceEpoch}_$i',
            'date': payments[i].at.toIso8601String(),
            'type': 'payment',
            'amount': -payments[i].amount.round(),
            'description': 'دفعة',
          },
      ],
    },
  };
}

/// الطلبات التي نُفّذت فعلاً: تاريخ انتهاء المشترك تقدّم عمّا كان عليه عند الطلب،
/// بأي طريقة تفعيل (فردي، جماعي، FTTH، أو من لوحة الساس). نقيّة.
List<(PortalRenewal, DateTime)> renewalsToComplete(
  Iterable<PortalRenewal> renewals,
  Map<String, Subscriber> subscribersById,
) {
  final result = <(PortalRenewal, DateTime)>[];
  for (final r in renewals) {
    if (!r.isOpen || r.previousEndDate == null) continue;
    final s = subscribersById[r.subscriberId];
    if (s == null) continue;
    if (s.endDate.isAfter(r.previousEndDate!.add(const Duration(hours: 12)))) {
      result.add((r, s.endDate));
    }
  }
  return result;
}

/// يعمل بعد كل حفظ ناجح: ينشر ملخصات المشتركين المربوطين التي تغيّرت،
/// ويرسل «تم التجديد» للطلبات المنفّذة. لا يرمي أخطاء أبداً.
class SubscriberPortalSync {
  SubscriberPortalSync({
    required this.client,
    required this.subscribers,
    required this.lastSasSync,
    required this.isEnabled,
    this.packages = _noPackages,
    this.debounce = const Duration(seconds: 4),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static List<PackagePlan> _noPackages() => const [];

  final SubscriberPortalClient client;
  final List<Subscriber> Function() subscribers;
  final DateTime? Function() lastSasSync;
  final Future<bool> Function() isEnabled;

  /// باقات المكتب، تُنشر ليختار منها المشترك عند السماح بتغيير الباقة.
  final List<PackagePlan> Function() packages;
  final Duration debounce;
  final DateTime Function() _now;

  /// طلبات التجديد وتذاكر الدعم بانتظار الوكيل، لشارة القائمة.
  final ValueNotifier<int> openRequests = ValueNotifier(0);

  final Map<String, String> _published = {};
  String? _publishedCatalog;
  Set<String>? _links;
  DateTime? _linksAt;
  DateTime? _pausedUntil;
  Timer? _timer;
  Future<void>? _running;

  static SubscriberPortalSync? _instance;
  static SubscriberPortalSync get instance => _instance ??= SubscriberPortalSync(
    client: SubscriberPortalClient.forCurrentUser(),
    subscribers: () => AppStore.subscribers,
    lastSasSync: () => AppStore.lastSasSync,
    isEnabled: SubscriberPortalFeature.isEnabled,
    packages: () => AppStore.packages,
  );

  void schedule() {
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(run()));
  }

  /// بعد دعوة أو فك ربط: تُعاد قراءة قائمة المربوطين في الدورة التالية.
  void markLinksStale() => _linksAt = null;

  Future<void> run() => _running ??= _run().whenComplete(() => _running = null);

  Future<void> _run() async {
    try {
      if (_pausedUntil != null && _now().isBefore(_pausedUntil!)) return;
      if (!await isEnabled()) return;
      if (_links == null ||
          _linksAt == null ||
          _now().difference(_linksAt!) > const Duration(minutes: 10)) {
        _links = await client.linkedSubscriberIds();
        _linksAt = _now();
      }
      final byId = {for (final s in subscribers()) s.subscriberId: s};
      for (final id in _links!) {
        final s = byId[id];
        if (s == null) continue;
        final summary = buildPortalSummary(s, lastSasSync: lastSasSync());
        final fingerprint = jsonEncode(summary);
        if (_published[id] == fingerprint) continue;
        await client.putSummary(id, summary);
        _published[id] = fingerprint;
      }
      final catalog = buildPortalCatalog(packages());
      final catalogPrint = jsonEncode(catalog);
      if (_publishedCatalog != catalogPrint) {
        await client.putCatalog(catalog);
        _publishedCatalog = catalogPrint;
      }
      final renewals = await client.renewals();
      for (final (request, end) in renewalsToComplete(renewals, byId)) {
        await client.complete(request.id, end);
      }
      final tickets = await client.supportTickets(status: 'open');
      openRequests.value =
          renewals.where((r) => r.status == 'pending').length + tickets.length;
    } on PortalException catch (e) {
      if (e.code == 'portal_disabled' || e.code == 'forbidden') {
        _pausedUntil = _now().add(const Duration(minutes: 30));
      }
      debugPrint('subscriber portal sync skipped: ${e.code}');
    } catch (e) {
      debugPrint('subscriber portal sync error: $e');
    }
  }
}

/// التجربة مع حساب المدير فقط (D11)، حتى يُفتح للوكلاء بعد نجاحها.
class SubscriberPortalFeature {
  /// متاحة لكل وكيل ولحساب المدير. البوابة نفسها ترفض الوكيل غير الفعّال
  /// (قاعدة R1)، فتتوقف المزامنة عنده وتشرح الواجهة السبب.
  static Future<bool> isEnabled() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return false;
    final role = await UserRoleService.resolveRole(uid: uid);
    return role == UserRoleService.adminRole || role == UserRoleService.agentRole;
  }
}
