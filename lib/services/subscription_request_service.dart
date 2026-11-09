import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';

import 'trial_guard_service.dart';

DateTime? _parseDateTime(dynamic value) {
  if (value is DateTime) return value;
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value);
  }
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  if (value is String && value.trim().isNotEmpty) {
    return DateTime.tryParse(value.trim());
  }
  return null;
}

class SubscriptionRequestModel {
  SubscriptionRequestModel({
    required this.requestId,
    required this.firstName,
    required this.lastName,
    required this.phone,
    required this.email,
    required this.selectedPlan,
    required this.amount,
    required this.paymentMethod,
    this.uid = '',
    this.transferNumber = '',
    this.receiptImageUrl = '',
    this.status = 'pending',
    this.createdAt,
    this.rejectionReason = '',
    this.source = '',
    this.reviewedAt,
    this.isRenewal = false,
    this.collectionPath = 'subscriptionRequests',
    this.deletedAt,
    this.deletedSas = '',
  });

  /// حين حذف المدير الوكيل؛ يبقى طلبه مرفوضاً ليُعرف من حُذف.
  final DateTime? deletedAt;

  /// الساس الذي كان الوكيل مرتبطاً به عند حذفه.
  final String deletedSas;

  /// بطاقة وكيل محذوف: محفوظة عند الحذف، أو مستعادة من بصماته.
  bool get isDeleted =>
      deletedAt != null ||
      collectionPath == SubscriptionRequestService.deletedClaimsPath;

  final String requestId;
  final String uid;
  final String firstName;
  final String lastName;
  final String phone;
  final String email;
  final String selectedPlan;
  final String amount;
  final String paymentMethod;
  final String transferNumber;
  final String receiptImageUrl;
  final String status;
  final String rejectionReason;
  final String source;
  final DateTime? createdAt;
  final DateTime? reviewedAt;
  final bool isRenewal;
  final String collectionPath;

  Map<String, dynamic> toMap() => {
    'requestId': requestId,
    'uid': uid,
    'firstName': firstName,
    'lastName': lastName,
    'phone': phone,
    'email': email,
    'selectedPlan': selectedPlan,
    'amount': amount,
    'paymentMethod': paymentMethod,
    'transferNumber': transferNumber,
    'receiptImageUrl': receiptImageUrl,
    'status': status,
    'rejectionReason': rejectionReason,
    'source': source,
    'isRenewal': isRenewal,
    'createdAt':
        createdAt?.millisecondsSinceEpoch ??
        DateTime.now().millisecondsSinceEpoch,
    'reviewedAt': reviewedAt?.toUtc().toIso8601String(),
  };

  factory SubscriptionRequestModel.fromMap(Map<String, dynamic> data) {
    return SubscriptionRequestModel(
      requestId: (data['requestId'] ?? data['id'] ?? '').toString(),
      uid: (data['uid'] ?? '').toString(),
      firstName: (data['firstName'] ?? '').toString(),
      lastName: (data['lastName'] ?? '').toString(),
      phone: (data['phone'] ?? '').toString(),
      email: (data['email'] ?? '').toString(),
      selectedPlan: (data['selectedPlan'] ?? '').toString(),
      amount: (data['amount'] ?? '').toString(),
      paymentMethod: (data['paymentMethod'] ?? 'Qi Card').toString(),
      transferNumber: (data['transferNumber'] ?? '').toString(),
      receiptImageUrl: (data['receiptImageUrl'] ?? data['receiptImage'] ?? '')
          .toString(),
      status: (data['status'] ?? 'pending').toString(),
      rejectionReason: (data['rejectionReason'] ?? '').toString(),
      source: (data['source'] ?? '').toString(),
      createdAt: _parseDateTime(data['createdAt']),
      reviewedAt: _parseDateTime(data['reviewedAt']),
      isRenewal: data['isRenewal'] == true,
      collectionPath: (data['collectionPath'] ?? 'subscriptionRequests')
          .toString(),
      deletedAt: _parseDateTime(data['deletedAt']),
      deletedSas: (data['deletedSas'] ?? '').toString(),
    );
  }
}

/// بيانات الوكيل كما عدّلها في ملفه الشخصي؛ أحدث من نسخة طلب الاشتراك.
class AgentProfile {
  const AgentProfile({this.name = '', this.phone = '', this.email = ''});

  final String name;
  final String phone;
  final String email;

  static AgentProfile? fromValue(Object? value) {
    if (value is! Map) return null;
    String field(String key) => '${value[key] ?? ''}'.trim();
    final full = '${field('firstName')} ${field('lastName')}'.trim();
    return AgentProfile(
      name: field('name').isNotEmpty ? field('name') : full,
      phone: field('phone'),
      email: field('email'),
    );
  }

  /// الاسم والرقم والبريد من الملف إن وُجدت، وإلا من الطلب.
  String nameOr(String fallback) => name.isNotEmpty ? name : fallback;
  String phoneOr(String fallback) => phone.isNotEmpty ? phone : fallback;
  String emailOr(String fallback) => email.isNotEmpty ? email : fallback;
}

class AgentRequests {
  const AgentRequests({required this.current, required this.older});

  final SubscriptionRequestModel current;
  final List<SubscriptionRequestModel> older;
}

class SubscriptionRequestService {
  static const String adminRootNode = 'admin';
  static const String collectionName = 'subscriptionRequests';
  static const String legacyCollectionName = 'subscription_requests';
  static const String pendingStatus = 'pending';
  static const String approvedStatus = 'approved';
  static const String rejectedStatus = 'rejected';
  static const String reviewingStatus = 'reviewing';

  /// مصدر بطاقات الوكلاء المحذوفين قبل حفظ طلباتهم: بصمات الباقة المجانية.
  static const String deletedClaimsPath = 'trialClaims';
  static const String deletedReason = 'حذف المدير الوكيل وبياناته';
  static const String trustedAdminUid = 'wE10WciDVudIOJziBurjhBxpDfO2';

  /// مهلة حجز الطلب أثناء القبول؛ بعدها يُعد الحجز متروكاً، كأن أُغلق التطبيق
  /// في منتصف القبول.
  static const Duration reviewClaimTimeout = Duration(minutes: 2);

  static DatabaseReference get _root => FirebaseDatabase.instance.ref();

  static String get _adminCollectionPath => '$adminRootNode/$collectionName';

  static bool get _isTrustedAdmin =>
      FirebaseAuth.instance.currentUser?.uid == trustedAdminUid;

  static void _requireTrustedAdmin() {
    if (!_isTrustedAdmin) {
      throw StateError('هذه العملية للمدير فقط');
    }
  }

  static DatabaseReference requestRef(
    String requestId, {
    String collectionPath = collectionName,
  }) {
    if (collectionPath != collectionName &&
        collectionPath != legacyCollectionName) {
      throw ArgumentError.value(
        collectionPath,
        'collectionPath',
        'Unsupported subscription request collection.',
      );
    }
    return _root.child('$adminRootNode/$collectionPath/$requestId');
  }

  static String planLabel(String value) {
    switch (value.trim()) {
      case 'trial':
      case 'free_15_days':
        return 'تجريبي 15 يوم';
      case '3m':
      case 'three_months':
        return '3 أشهر';
      case '6m':
      case 'six_months':
        return '6 أشهر';
      case '1y':
      case 'one_year':
        return 'سنة';
      default:
        return 'تجريبي 15 يوم';
    }
  }

  static String planLabelFor(String? value) => planLabel(value ?? 'trial');

  static bool isTrialPlan(String plan) =>
      plan == 'trial' || plan == 'free_15_days';

  static DateTime startDateForPlan({DateTime? now}) => now ?? DateTime.now();

  /// الطلب المعلق، أو طلب تُرك محجوزاً بعد انقطاع القبول.
  static bool isOpenForReview(Map<String, dynamic> request, {DateTime? now}) {
    final status = request['status'];
    if (status == pendingStatus) return true;
    if (status != reviewingStatus) return false;
    final claimedAt = _parseDateTime(request['reviewedAt']);
    return claimedAt == null ||
        (now ?? DateTime.now()).difference(claimedAt) >= reviewClaimTimeout;
  }

  /// لا يُحذف الطلب أثناء قبوله فقط، لأن القبول قد يكتمل بعد الحذف.
  static bool canDelete(Map<String, dynamic> request) =>
      request['status'] != reviewingStatus || isOpenForReview(request);

  /// بطاقة واحدة لكل وكيل: طلبه المفتوح أو الأحدث، والباقي سجل داخلها.
  static List<AgentRequests> groupByAgent(
    Iterable<SubscriptionRequestModel> requests,
  ) {
    final groups = <String, List<SubscriptionRequestModel>>{};
    for (final request in requests) {
      final key = request.uid.isNotEmpty
          ? request.uid
          : request.email.isNotEmpty
          ? request.email.toLowerCase()
          : request.requestId;
      groups.putIfAbsent(key, () => []).add(request);
    }
    int createdAt(SubscriptionRequestModel request) =>
        request.createdAt?.millisecondsSinceEpoch ?? 0;
    bool isOpen(SubscriptionRequestModel request) =>
        request.status == pendingStatus || request.status == reviewingStatus;

    final agents = groups.values.map((items) {
      items.sort((a, b) => createdAt(b).compareTo(createdAt(a)));
      final current = items.firstWhere(isOpen, orElse: () => items.first);
      return AgentRequests(
        current: current,
        older: items.where((item) => !identical(item, current)).toList(),
      );
    }).toList();
    agents.sort((a, b) => createdAt(b.current).compareTo(createdAt(a.current)));
    return agents;
  }

  static Stream<DateTime?> watchSubscriptionEnd(String uid) {
    _requireTrustedAdmin();
    return _root
        .child('agents/$uid/subscription/endDate')
        .onValue
        .map((event) => _parseDateTime(event.snapshot.value));
  }

  /// يحذف كل بيانات الوكيل من Firebase دفعة واحدة: حسابه في agents
  /// ومساره القديم، وكل طلبات اشتراكه، ثم صور إيصالاته.
  /// تبقى بصمات التجربة المجانية حتى لا يعود بتجربة جديدة، ويبقى حساب
  /// الدخول لأن حذفه يحتاج صلاحيات الخادم.
  static Future<AgentDeletionResult> deleteAgentCompletely(String uid) async {
    _requireTrustedAdmin();
    final id = uid.trim();
    if (id.isEmpty || id.contains('/')) {
      throw ArgumentError.value(uid, 'uid', 'معرف الوكيل غير صالح');
    }
    if (id == trustedAdminUid) {
      throw StateError('لا يمكن حذف حساب المدير');
    }

    final profileValue = (await _root.child('agents/$id/profile').get()).value;
    final profile = profileValue is Map
        ? Map<String, dynamic>.from(profileValue)
        : const <String, dynamic>{};
    final sasValue = (await _root.child('agents/$id/sas').get()).value;
    final sas = sasValue is Map
        ? Map<String, dynamic>.from(sasValue)
        : const <String, dynamic>{};

    final requests = <String, Map<String, dynamic>>{};
    for (final path in [collectionName, legacyCollectionName]) {
      final snapshot = await _root
          .child('$adminRootNode/$path')
          .orderByChild('uid')
          .equalTo(id)
          .get();
      final value = snapshot.value;
      if (value is! Map) continue;
      for (final entry in value.entries) {
        final request = entry.value;
        if (request is! Map || '${request['uid']}' != id) continue;
        requests['$adminRootNode/$path/${entry.key}'] =
            Map<String, dynamic>.from(request);
      }
    }

    final updates = deletionUpdates(
      uid: id,
      profile: profile,
      sas: sas,
      requests: requests,
      now: DateTime.now().toUtc(),
    );
    final receipts = [
      for (final request in requests.values)
        '${request['receiptImageUrl'] ?? ''}'.trim(),
    ].where((url) => url.isNotEmpty).toList();

    // تحديث واحد: إما يُحذف كل شيء أو لا يُحذف شيء.
    await _root.update(updates);

    var receiptsDeleted = 0;
    for (final url in receipts) {
      try {
        await FirebaseStorage.instance.refFromURL(url).delete();
        receiptsDeleted++;
      } catch (_) {
        // صورة محذوفة سابقاً أو قواعد التخزين تمنع: البيانات حُذفت على أي حال.
      }
    }
    return AgentDeletionResult(
      requests: requests.length,
      receipts: receipts.length,
      receiptsDeleted: receiptsDeleted,
    );
  }

  /// ما يكتبه حذف الوكيل: تُمحى بياناته، وتبقى طلباته مرفوضة بلا صور
  /// إيصالات ليراها المدير في «مرفوض». وكيل بلا طلبات تُنشأ له بطاقة.
  static Map<String, Object?> deletionUpdates({
    required String uid,
    required Map<String, dynamic> profile,
    required Map<String, dynamic> sas,
    required Map<String, Map<String, dynamic>> requests,
    required DateTime now,
  }) {
    final at = now.toIso8601String();
    final sasUser = '${sas['username'] ?? profile['sasUsername'] ?? ''}'.trim();
    final sasServer = '${sas['serverUrl'] ?? ''}'.trim();
    final sasLabel = sasUser.isEmpty
        ? ''
        : sasServer.isEmpty
        ? sasUser
        : '$sasUser @ ${TrialGuardService.normalizeSas(sasServer, sasUser).split('|').first}';

    final updates = <String, Object?>{'agents/$uid': null};
    final legacySas = '${profile['sasUsername'] ?? ''}'.trim();
    if (legacySas.isNotEmpty && !legacySas.contains('/')) {
      updates['agents/${uid}_$legacySas'] = null;
    }
    final marks = <String, Object?>{
      'status': rejectedStatus,
      'rejectionReason': deletedReason,
      'reviewerUid': trustedAdminUid,
      'reviewedAt': at,
      'deletedAt': at,
      'deletedSas': sasLabel,
      'receiptImageUrl': null,
      'receiptImage': null,
      'reviewDecision': null,
    };
    for (final path in requests.keys) {
      for (final mark in marks.entries) {
        updates['$path/${mark.key}'] = mark.value;
      }
    }
    if (requests.isEmpty) {
      String field(String key) => '${profile[key] ?? ''}'.trim();
      var first = field('firstName');
      var last = field('lastName');
      if (first.isEmpty && last.isEmpty) first = field('name');
      final created = _parseDateTime(profile['createdAt']);
      final requestId = 'deleted_$uid';
      updates['$adminRootNode/$collectionName/$requestId'] = {
        'requestId': requestId,
        'uid': uid,
        'email': field('email'),
        'firstName': first,
        'lastName': last,
        'phone': field('phone'),
        'selectedPlan': '',
        'amount': '',
        'paymentMethod': '',
        'transferNumber': '',
        'createdAt': (created ?? now).millisecondsSinceEpoch,
        for (final mark in marks.entries)
          if (mark.value != null) mark.key: mark.value,
      };
    }
    return updates;
  }

  /// وكلاء حُذفوا قبل حفظ طلباتهم: بقيت بصماتهم فقط (المعرف والتاريخ).
  /// كل معرف لا طلب له ولا حساب يصبح بطاقة مرفوضة.
  static List<SubscriptionRequestModel> deletedAgentCards({
    required Object? claims,
    required Set<String> knownUids,
    required Set<String> existingAgents,
  }) {
    if (claims is! Map) return const [];
    final kinds = <String, Set<String>>{};
    final firstAt = <String, int>{};
    for (final kindEntry in claims.entries) {
      final byHash = kindEntry.value;
      if (byHash is! Map) continue;
      for (final claim in byHash.values) {
        if (claim is! Map) continue;
        final uid = '${claim['uid'] ?? ''}'.trim();
        if (uid.isEmpty ||
            uid == trustedAdminUid ||
            knownUids.contains(uid) ||
            existingAgents.contains(uid)) {
          continue;
        }
        kinds.putIfAbsent(uid, () => {}).add('${kindEntry.key}');
        final at = claim['at'];
        if (at is num) {
          final ms = at.toInt();
          final previous = firstAt[uid];
          if (previous == null || ms < previous) firstAt[uid] = ms;
        }
      }
    }
    String kindName(String kind) => switch (kind) {
      TrialGuardService.phonesKind => 'رقم هاتف',
      TrialGuardService.sasKind => 'ساس',
      _ => 'ساس FTTH',
    };
    final cards = [
      for (final entry in kinds.entries)
        SubscriptionRequestModel(
          requestId: 'claims_${entry.key}',
          uid: entry.key,
          firstName: 'وكيل محذوف',
          lastName: '',
          phone: '',
          email: '',
          selectedPlan: '',
          amount: '',
          paymentMethod: '',
          status: rejectedStatus,
          createdAt: firstAt[entry.key] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(firstAt[entry.key]!),
          rejectionReason:
              'حُذف قبل حفظ بياناته؛ بقيت بصماته: '
              '${(entry.value.toList()..sort()).map(kindName).join('، ')}',
          collectionPath: deletedClaimsPath,
        ),
    ];
    cards.sort(
      (a, b) => (b.createdAt?.millisecondsSinceEpoch ?? 0).compareTo(
        a.createdAt?.millisecondsSinceEpoch ?? 0,
      ),
    );
    return cards;
  }

  /// للمدير: بطاقات الوكلاء المحذوفين سابقاً من بصماتهم.
  static Future<List<SubscriptionRequestModel>> loadDeletedAgentCards(
    Set<String> knownUids,
  ) async {
    _requireTrustedAdmin();
    final claims = (await _root.child(deletedClaimsPath).get()).value;
    final candidates = deletedAgentCards(
      claims: claims,
      knownUids: knownUids,
      existingAgents: const {},
    );
    final existing = <String>{};
    await Future.wait(
      candidates.map((card) async {
        final role = await _root.child('agents/${card.uid}/profile').get();
        if (role.exists) existing.add(card.uid);
      }),
    );
    return deletedAgentCards(
      claims: claims,
      knownUids: knownUids,
      existingAgents: existing,
    );
  }

  /// ملف الوكيل الشخصي مباشرة، ليظهر رقمه واسمه بعد تعديلهما.
  static Stream<AgentProfile?> watchAgentProfile(String uid) {
    _requireTrustedAdmin();
    return _root
        .child('agents/$uid/profile')
        .onValue
        .map((event) => AgentProfile.fromValue(event.snapshot.value));
  }

  /// ملفات عدة وكلاء مرة واحدة؛ من تعذرت قراءته يبقى بيانات طلبه.
  static Future<Map<String, AgentProfile>> loadAgentProfiles(
    Iterable<String> uids,
  ) async {
    _requireTrustedAdmin();
    final profiles = <String, AgentProfile>{};
    await Future.wait(
      uids.toSet().where((uid) => uid.isNotEmpty).map((uid) async {
        try {
          final value = (await _root.child('agents/$uid/profile').get()).value;
          final profile = AgentProfile.fromValue(value);
          if (profile != null) profiles[uid] = profile;
        } catch (_) {}
      }),
    );
    return profiles;
  }

  /// عدد مشتركي الوكيل المحفوظين في حسابه، ومنهم من جاء من مزامنة ساسه.
  /// يُقرأ مرة لكل بطاقة، للمدير فقط.
  static Future<AgentSubscriberCounts> fetchAgentSubscriberCounts(
    String uid,
  ) async {
    _requireTrustedAdmin();
    final snapshot = await _root.child('agents/$uid/subscribers').get();
    return AgentSubscriberCounts.fromValue(snapshot.value);
  }

  /// يُضاف الاشتراك بعد المدة المتبقية حتى لا تضيع بقبول طلب جديد.
  static DateTime subscriptionStartDate({
    required Object? existing,
    required DateTime now,
  }) {
    if (existing is! Map || existing['status'] != 'active') return now;
    final end = _parseDateTime(existing['endDate'])?.toUtc();
    return end != null && end.isAfter(now) ? end : now;
  }

  /// تصحيح باقة الاشتراك الحالي: تبقى بدايته، وتُحسب نهايته من الباقة الجديدة.
  static Map<String, dynamic> subscriptionWithPlan(
    Map<String, dynamic> existing, {
    required String plan,
    required DateTime now,
  }) {
    final start = _parseDateTime(existing['startDate'])?.toUtc() ?? now;
    final end = endDateForPlan(plan, from: start);
    return {
      ...existing,
      'plan': plan,
      'status': end.isAfter(now) ? 'active' : 'expired',
      'durationDays': end.difference(start).inDays,
      'startDate': start.toIso8601String(),
      'endDate': end.toIso8601String(),
      'updatedAt': now.toIso8601String(),
    };
  }

  /// تُضاف الأيام بعد المدة المتبقية، أو من اليوم إذا انتهى الاشتراك.
  static Map<String, dynamic> extendedSubscription(
    Map<String, dynamic> existing, {
    required int days,
    required DateTime now,
  }) {
    final from = subscriptionStartDate(existing: existing, now: now);
    final start = from == now
        ? now
        : _parseDateTime(existing['startDate'])?.toUtc() ?? now;
    final end = from.add(Duration(days: days));
    return {
      ...existing,
      'status': 'active',
      'durationDays': end.difference(start).inDays,
      'startDate': start.toIso8601String(),
      'endDate': end.toIso8601String(),
      'updatedAt': now.toIso8601String(),
    };
  }

  static DateTime _addCalendarMonths(DateTime date, int months) {
    final monthIndex = date.year * 12 + date.month - 1 + months;
    final year = monthIndex ~/ 12;
    final month = monthIndex % 12 + 1;
    final lastDay = DateTime(year, month + 1, 0).day;
    final day = date.day > lastDay ? lastDay : date.day;
    if (date.isUtc) {
      return DateTime.utc(
        year,
        month,
        day,
        date.hour,
        date.minute,
        date.second,
        date.millisecond,
        date.microsecond,
      );
    }
    return DateTime(
      year,
      month,
      day,
      date.hour,
      date.minute,
      date.second,
      date.millisecond,
      date.microsecond,
    );
  }

  static DateTime endDateForPlan(String plan, {DateTime? from}) {
    final start = from ?? DateTime.now();
    switch (plan.trim()) {
      case 'trial':
      case 'free_15_days':
        return start.add(const Duration(days: 15));
      case '3m':
      case 'three_months':
        return _addCalendarMonths(start, 3);
      case '6m':
      case 'six_months':
        return _addCalendarMonths(start, 6);
      case '1y':
      case 'one_year':
        return _addCalendarMonths(start, 12);
      default:
        return start.add(const Duration(days: 15));
    }
  }

  static Stream<List<SubscriptionRequestModel>> watchRequests({
    String? status,
  }) {
    _requireTrustedAdmin();
    final paths = [collectionName, legacyCollectionName];
    final snapshots = <String, Object?>{};
    final controller = StreamController<List<SubscriptionRequestModel>>();
    final subscriptions = <StreamSubscription<DatabaseEvent>>[];

    void emit() {
      if (snapshots.length != paths.length) return;
      final records = <SubscriptionRequestModel>[];
      for (final path in paths) {
        final value = snapshots[path];
        if (value is! Map) continue;
        for (final entry in value.entries) {
          if (entry.value is! Map) continue;
          final raw = Map<String, dynamic>.from(entry.value as Map)
            ..putIfAbsent('requestId', () => entry.key.toString())
            ..['collectionPath'] = path;
          final record = SubscriptionRequestModel.fromMap(raw);
          if (status == null || status.isEmpty || record.status == status) {
            records.add(record);
          }
        }
      }
      records.sort((a, b) {
        final aTs = a.createdAt?.millisecondsSinceEpoch ?? 0;
        final bTs = b.createdAt?.millisecondsSinceEpoch ?? 0;
        return bTs.compareTo(aTs);
      });
      controller.add(records);
    }

    for (final path in paths) {
      subscriptions.add(
        _root.child('$adminRootNode/$path').onValue.listen((event) {
          snapshots[path] = event.snapshot.value;
          emit();
        }, onError: controller.addError),
      );
    }
    controller.onCancel = () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    };
    return controller.stream;
  }

  static Future<String> createRequest({
    required String firstName,
    required String lastName,
    required String phone,
    required String email,
    required String selectedPlan,
    required String amount,
    required String paymentMethod,
    required String transferNumber,
    required String uid,
    String agentName = '',
    String governorate = '',
    String region = '',
    String address = '',
    String? receiptImageUrl,
    bool isRenewal = false,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || uid.trim().isEmpty || user.uid != uid.trim()) {
      throw StateError('سجّل الدخول بالحساب نفسه قبل إرسال الطلب');
    }
    if (isRenewal &&
        user.email?.trim().toLowerCase() != email.trim().toLowerCase()) {
      throw StateError('بريد طلب التجديد لا يطابق الحساب المسجل');
    }
    final nodeRef = _root.child(_adminCollectionPath).push();
    final requestId = nodeRef.key;
    if (requestId == null) {
      throw StateError('تعذر إنشاء الطلب، حاول مرة أخرى');
    }
    final names = agentName
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    final model = SubscriptionRequestModel(
      requestId: requestId,
      uid: user.uid,
      firstName: firstName.isNotEmpty
          ? firstName
          : (names.isEmpty ? '' : names.first),
      lastName: lastName.isNotEmpty
          ? lastName
          : (names.length < 2 ? '' : names.skip(1).join(' ')),
      phone: phone,
      email: user.email ?? email,
      selectedPlan: selectedPlan,
      amount: amount,
      paymentMethod: paymentMethod,
      transferNumber: transferNumber,
      receiptImageUrl: receiptImageUrl ?? '',
      isRenewal: isRenewal,
      source: isRenewal ? 'renewal' : 'registration',
      createdAt: DateTime.now(),
    );
    final payload = <String, dynamic>{
      ...model.toMap(),
      'agentName': agentName.trim().isNotEmpty
          ? agentName.trim()
          : names.join(' '),
      'governorate': governorate,
      'region': region,
      'address': address,
    };
    await nodeRef.set(payload);
    return requestId;
  }

  /// تفعيل ذاتي مرة واحدة لكل حساب. القواعد تمنعه لمن له صلاحية وكيل، وتفرض 15
  /// يوماً؛ لذلك يُحفظ التاريخان رقمين لأن القواعد لا تستطيع فحص النص.
  static Future<void> activateFreeTrial({
    required String agentName,
    required String phone,
    required String amount,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.email == null) {
      throw StateError('سجّل الدخول قبل تفعيل الباقة المجانية');
    }
    final uid = user.uid;
    final role = await _root.child('agents/$uid/profile/role').get();
    if (role.exists) {
      throw StateError('هذا الحساب مسجل مسبقاً ولا تتوفر له الباقة المجانية');
    }
    // القواعد لا تقبل الباقة المجانية إلا ببصمة هاتف مسجلة لهذا الحساب.
    final phoneHash = await TrialGuardService.claimTrialPhone(phone);
    final requestId = _root.child(_adminCollectionPath).push().key;
    if (requestId == null) {
      throw StateError('تعذر إنشاء الطلب، حاول مرة أخرى');
    }
    final names = agentName
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    final firstName = names.isEmpty ? '' : names.first;
    final lastName = names.skip(1).join(' ');
    final now = DateTime.now();
    final startDate = now.millisecondsSinceEpoch;
    final request = SubscriptionRequestModel(
      requestId: requestId,
      uid: uid,
      firstName: firstName,
      lastName: lastName,
      phone: phone,
      email: user.email!,
      selectedPlan: 'free_15_days',
      amount: amount,
      paymentMethod: 'free',
      status: approvedStatus,
      source: 'trial',
      createdAt: now,
    );
    final profilePath = 'agents/$uid/profile';
    try {
      await _root.update({
        '$_adminCollectionPath/$requestId': {
          ...request.toMap(),
          'agentName': names.join(' '),
        },
        '$profilePath/email': user.email,
        '$profilePath/name': names.join(' '),
        '$profilePath/firstName': firstName,
        '$profilePath/lastName': lastName,
        '$profilePath/phone': phone,
        '$profilePath/role': 'agent',
        '$profilePath/status': 'active',
        '$profilePath/approvedAt': startDate,
        '$profilePath/approvalRequestId': requestId,
        'agents/$uid/subscription': {
          'plan': 'free_15_days',
          'status': 'active',
          'durationDays': 15,
          'startDate': startDate,
          'endDate': startDate + const Duration(days: 15).inMilliseconds,
          'autoExpire': true,
          'trialPhoneHash': phoneHash,
          'lastPaymentId': requestId,
          'updatedAt': now.toUtc().toIso8601String(),
        },
      });
    } on FirebaseException catch (error) {
      if (error.code != 'permission-denied') rethrow;
      throw StateError(
        'تعذر تفعيل الباقة المجانية. تأكد من صحة تاريخ ووقت جهازك',
      );
    }
  }

  static Future<String?> uploadReceiptImage({
    required String requestId,
    required XFile file,
  }) async {
    final storageRef = FirebaseStorage.instance.ref(
      '$_adminCollectionPath/$requestId/${file.name}',
    );
    final bytes = await file.readAsBytes();
    final task = await storageRef.putData(
      bytes,
      SettableMetadata(contentType: 'image/jpeg'),
    );
    return task.ref.getDownloadURL();
  }

  static Future<void> rejectRequest({
    required String requestId,
    String? reason,
    String collectionPath = collectionName,
  }) async {
    _requireTrustedAdmin();
    final reviewedAt = DateTime.now().toUtc().toIso8601String();
    final result = await requestRef(requestId, collectionPath: collectionPath)
        .runTransaction((value) {
          if (value is! Map) return Transaction.abort();
          final current = Map<String, dynamic>.from(value);
          if (!isOpenForReview(current)) return Transaction.abort();
          current
            ..remove('reviewDecision')
            ..['status'] = rejectedStatus
            ..['rejectionReason'] = reason ?? ''
            ..['reviewerUid'] = trustedAdminUid
            ..['reviewedAt'] = reviewedAt;
          return Transaction.success(current);
        }, applyLocally: false);
    if (!result.committed) {
      throw StateError('لا يمكن رفض طلب تمت مراجعته');
    }
  }

  static Future<void> markRequestAsPendingReview({
    required String requestId,
    required Map<String, dynamic> patch,
  }) async {
    final imageUrl = (patch['receiptImageUrl'] ?? patch['receiptImage'] ?? '')
        .toString();
    await requestRef(requestId).child('receiptImageUrl').set(imageUrl);
  }

  static Future<void> deleteRequest({
    required String requestId,
    String collectionPath = collectionName,
  }) async {
    _requireTrustedAdmin();
    final id = requestId.trim();
    if (id.isEmpty) return;
    final ref = requestRef(id, collectionPath: collectionPath);
    final result = await ref.runTransaction((value) {
      if (value is! Map) return Transaction.abort();
      final current = Map<String, dynamic>.from(value);
      if (!canDelete(current)) return Transaction.abort();
      return Transaction.success(null);
    }, applyLocally: false);
    if (!result.committed) {
      throw StateError('لا يمكن حذف الطلب أثناء قبوله، حاول بعد قليل');
    }
  }

  static Future<Map<String, dynamic>> approveRequestById({
    required String requestId,
    required Map<String, dynamic> requestData,
    String collectionPath = collectionName,
  }) async {
    _requireTrustedAdmin();
    final fullName = (requestData['agentName'] ?? '').toString().trim();
    final nameParts = fullName
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    final request = SubscriptionRequestModel(
      requestId: requestId,
      uid: (requestData['uid'] ?? '').toString(),
      firstName:
          (requestData['firstName'] ??
                  (nameParts.isEmpty ? '' : nameParts.first))
              .toString(),
      lastName:
          (requestData['lastName'] ??
                  (nameParts.length < 2 ? '' : nameParts.skip(1).join(' ')))
              .toString(),
      phone: (requestData['phone'] ?? '').toString(),
      email: (requestData['email'] ?? '').toString(),
      selectedPlan: (requestData['selectedPlan'] ?? '').toString(),
      amount: (requestData['amount'] ?? '').toString(),
      paymentMethod: (requestData['paymentMethod'] ?? 'Qi Card').toString(),
      transferNumber: (requestData['transferNumber'] ?? '').toString(),
      receiptImageUrl: (requestData['receiptImageUrl'] ?? '').toString(),
      status: (requestData['status'] ?? pendingStatus).toString(),
      source: (requestData['source'] ?? '').toString(),
      createdAt: _parseDateTime(requestData['createdAt']),
      reviewedAt: _parseDateTime(requestData['reviewedAt']),
      isRenewal: requestData['isRenewal'] == true,
      collectionPath: collectionPath,
    );
    return approveRequest(request: request);
  }

  static Future<Map<String, dynamic>> approveRequest({
    required SubscriptionRequestModel request,
  }) async {
    _requireTrustedAdmin();
    final requestId = request.requestId.trim();
    final reqRef = requestRef(
      requestId,
      collectionPath: request.collectionPath,
    );
    final reviewedAtDate = DateTime.now().toUtc();
    final claimResult = await reqRef.runTransaction((value) {
      if (value is! Map) return Transaction.abort();
      final current = Map<String, dynamic>.from(value);
      if (!isOpenForReview(current) ||
          (current['uid'] ?? '').toString().trim().isEmpty) {
        return Transaction.abort();
      }
      current
        ..['status'] = reviewingStatus
        ..['reviewDecision'] = approvedStatus
        ..['reviewerUid'] = trustedAdminUid
        ..['reviewedAt'] = reviewedAtDate.toIso8601String();
      return Transaction.success(current);
    }, applyLocally: false);
    if (!claimResult.committed || claimResult.snapshot.value is! Map) {
      throw StateError('لا يمكن قبول طلب تمت مراجعته');
    }
    final current = Map<String, dynamic>.from(
      claimResult.snapshot.value as Map,
    );
    try {
      return await _completeApproval(
        request: request,
        reqRef: reqRef,
        current: current,
        reviewedAtDate: reviewedAtDate,
      );
    } catch (_) {
      await _releaseReviewClaim(reqRef);
      rethrow;
    }
  }

  static Future<Map<String, dynamic>> _completeApproval({
    required SubscriptionRequestModel request,
    required DatabaseReference reqRef,
    required Map<String, dynamic> current,
    required DateTime reviewedAtDate,
  }) async {
    final requestId = request.requestId.trim();
    final uid = (current['uid'] ?? '').toString().trim();
    final plan = current['selectedPlan']?.toString() ?? request.selectedPlan;
    final subscriptionSnapshot = await _root
        .child('agents/$uid/subscription')
        .get();
    final startDate = subscriptionStartDate(
      existing: subscriptionSnapshot.value,
      now: reviewedAtDate,
    );
    final endDate = endDateForPlan(plan, from: startDate);
    final reviewedAt = reviewedAtDate.toIso8601String();
    final profilePath = 'agents/$uid/profile';
    final profilePatch = <String, dynamic>{
      '$profilePath/email': (current['email'] ?? request.email).toString(),
      '$profilePath/name':
          (current['agentName'] ?? '${request.firstName} ${request.lastName}')
              .toString()
              .trim(),
      '$profilePath/firstName': request.firstName,
      '$profilePath/lastName': request.lastName,
      '$profilePath/phone': request.phone,
      '$profilePath/role': 'agent',
      '$profilePath/status': 'active',
      '$profilePath/approvedAt': reviewedAtDate.millisecondsSinceEpoch,
      '$profilePath/approvalRequestId': requestId,
    };
    final subscription = <String, dynamic>{
      'plan': plan,
      'status': 'active',
      'durationDays': endDate.difference(startDate).inDays,
      'startDate': startDate.toIso8601String(),
      'endDate': endDate.toIso8601String(),
      'autoExpire': true,
      'lastPaymentId': requestId,
      'updatedAt': reviewedAt,
    };
    await _root.update({
      '${reqRef.path}/status': approvedStatus,
      '${reqRef.path}/reviewDecision': null,
      '${reqRef.path}/reviewerUid': trustedAdminUid,
      '${reqRef.path}/reviewedAt': reviewedAt,
      ...profilePatch,
      'agents/$uid/subscription': subscription,
    });
    return {
      'uid': uid,
      'plan': plan,
      'planLabel': planLabel(plan),
      'startDate': startDate.toIso8601String(),
      'endDate': endDate.toIso8601String(),
    };
  }

  static Future<Map<String, dynamic>> _subscriptionOf(String uid) async {
    final snapshot = await _root.child('agents/$uid/subscription').get();
    if (snapshot.value is! Map) {
      throw StateError('لا يوجد اشتراك لهذا الوكيل');
    }
    return Map<String, dynamic>.from(snapshot.value as Map);
  }

  /// الطلب المقبول يغيّر اشتراك الوكيل معه، ما دام آخر طلب فُعّل له.
  static Future<void> changeRequestPlan({
    required String requestId,
    required String plan,
    required String amount,
    String collectionPath = collectionName,
  }) async {
    _requireTrustedAdmin();
    final reqRef = requestRef(requestId, collectionPath: collectionPath);
    final snapshot = await reqRef.get();
    if (snapshot.value is! Map) {
      throw StateError('الطلب غير موجود');
    }
    final current = Map<String, dynamic>.from(snapshot.value as Map);
    final patch = <String, dynamic>{
      '${reqRef.path}/selectedPlan': plan,
      '${reqRef.path}/amount': amount,
    };
    if (current['status'] == approvedStatus) {
      final uid = (current['uid'] ?? '').toString().trim();
      final existing = await _subscriptionOf(uid);
      if (existing['lastPaymentId'] != requestId) {
        throw StateError('هذا الطلب ليس آخر اشتراك مفعّل للوكيل');
      }
      patch['agents/$uid/subscription'] = subscriptionWithPlan(
        existing,
        plan: plan,
        now: DateTime.now().toUtc(),
      );
    } else if (!isOpenForReview(current)) {
      throw StateError('لا يمكن تغيير باقة طلب مرفوض');
    }
    await _root.update(patch);
  }

  static Future<DateTime> extendSubscription({
    required String uid,
    required int days,
  }) async {
    _requireTrustedAdmin();
    final extended = extendedSubscription(
      await _subscriptionOf(uid),
      days: days,
      now: DateTime.now().toUtc(),
    );
    await _root.child('agents/$uid/subscription').set(extended);
    return DateTime.parse(extended['endDate'] as String);
  }

  /// نهاية الاشتراك هي ما يفحصه التطبيق، فلا يكفي تغيير الحالة وحدها.
  static Future<void> endSubscription({required String uid}) async {
    _requireTrustedAdmin();
    await _subscriptionOf(uid);
    final now = DateTime.now().toUtc().toIso8601String();
    await _root.child('agents/$uid/subscription').update({
      'status': 'expired',
      'endDate': now,
      'updatedAt': now,
    });
  }

  static Future<void> sendPasswordReset({required String email}) async {
    _requireTrustedAdmin();
    await FirebaseAuth.instance.sendPasswordResetEmail(email: email.trim());
  }

  /// إن فشل هذا أيضاً تنتهي مهلة الحجز ويعود الطلب قابلاً للمراجعة.
  static Future<void> _releaseReviewClaim(DatabaseReference reqRef) async {
    try {
      await reqRef.update({
        'status': pendingStatus,
        'reviewDecision': null,
        'reviewerUid': null,
        'reviewedAt': null,
      });
    } catch (_) {}
  }
}

/// كم مشتركاً لدى الوكيل في التطبيق، وكم منهم جاء من مزامنة الساس.
class AgentSubscriberCounts {
  const AgentSubscriberCounts({
    required this.total,
    required this.sas,
    required this.ftth,
  });

  final int total;
  final int sas;
  final int ftth;

  /// القائمة تُحفظ في Firebase كقائمة أو كخريطة حسب ترتيب الأرقام.
  factory AgentSubscriberCounts.fromValue(Object? value) {
    final items = value is List
        ? value
        : value is Map
        ? value.values
        : const [];
    var total = 0;
    var sas = 0;
    var ftth = 0;
    for (final item in items) {
      if (item is! Map) continue;
      total++;
      final source = '${item['source'] ?? ''}';
      if (source == 'sas') sas++;
      if (source == 'ftth') ftth++;
    }
    return AgentSubscriberCounts(total: total, sas: sas, ftth: ftth);
  }
}

class AgentDeletionResult {
  const AgentDeletionResult({
    required this.requests,
    required this.receipts,
    required this.receiptsDeleted,
  });

  final int requests;
  final int receipts;
  final int receiptsDeleted;
}
