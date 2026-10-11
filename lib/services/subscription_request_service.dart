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

class SubscriptionRequestService {
  static const String adminRootNode = 'admin';
  static const String collectionName = 'subscriptionRequests';
  static const String legacyCollectionName = 'subscription_requests';
  static const String pendingStatus = 'pending';
  static const String approvedStatus = 'approved';
  static const String rejectedStatus = 'rejected';
  static const String trustedAdminUid = 'wE10WciDVudIOJziBurjhBxpDfO2';

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

  static String planPrice(String value) {
    switch (value.trim()) {
      case 'trial':
      case 'free_15_days':
        return 'مجاني';
      case '3m':
      case 'three_months':
        return '40000';
      case '6m':
      case 'six_months':
        return '50000';
      case '1y':
      case 'one_year':
        return '70000';
      default:
        return 'مجاني';
    }
  }

  static String planLabelFor(String? value) => planLabel(value ?? 'trial');

  static bool isTrialPlan(String plan) =>
      plan == 'trial' || plan == 'free_15_days';

  static DateTime startDateForPlan({DateTime? now}) => now ?? DateTime.now();

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
          if (current['status'] != pendingStatus) return Transaction.abort();
          current
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
      if (current['status'] == 'reviewing') return Transaction.abort();
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
      if (current['status'] != pendingStatus ||
          (current['uid'] ?? '').toString().trim().isEmpty) {
        return Transaction.abort();
      }
      current
        ..['status'] = 'reviewing'
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
    final uid = (current['uid'] ?? '').toString().trim();
    if (uid.isEmpty) {
      throw StateError('The request has no linked Firebase Auth UID.');
    }
    final plan = current['selectedPlan']?.toString() ?? request.selectedPlan;
    var startDate = reviewedAtDate;
    if (current['isRenewal'] == true) {
      final subscriptionSnapshot = await _root
          .child('agents/$uid/subscription')
          .get();
      if (subscriptionSnapshot.value is Map) {
        final existing = Map<String, dynamic>.from(
          subscriptionSnapshot.value as Map,
        );
        final existingEnd = _parseDateTime(existing['endDate'])?.toUtc();
        if (existing['status'] == 'active' &&
            existingEnd != null &&
            existingEnd.isAfter(startDate)) {
          startDate = existingEnd;
        }
      }
    }
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
}
