import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';

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
  });

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
    );
  }
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
      throw StateError(
        'Only the trusted administrator may review subscription requests.',
      );
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
      throw StateError(
        'A signed-in account matching the request UID is required.',
      );
    }
    if (isRenewal &&
        user.email?.trim().toLowerCase() != email.trim().toLowerCase()) {
      throw StateError(
        'The renewal request email must match the signed-in account.',
      );
    }
    final nodeRef = _root.child(_adminCollectionPath).push();
    final requestId = nodeRef.key;
    if (requestId == null) {
      throw StateError('Could not allocate a subscription request ID.');
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
    final requestId = _root.child(_adminCollectionPath).push().key;
    if (requestId == null) {
      throw StateError('Could not allocate a subscription request ID.');
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
      throw StateError('Only pending subscription requests can be rejected.');
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
      throw StateError(
        'The request could not be deleted in its current state.',
      );
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
      throw StateError('Only pending subscription requests can be approved.');
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
