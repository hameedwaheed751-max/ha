import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';
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
    this.password = '',
    this.rejectionReason = '',
    this.source = '',
    this.reviewedAt,
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
  final String password;
  final String rejectionReason;
  final String source;
  final DateTime? createdAt;
  final DateTime? reviewedAt;

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
        'password': password,
        'rejectionReason': rejectionReason,
        'source': source,
        'createdAt': createdAt?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch,
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
      receiptImageUrl: (data['receiptImageUrl'] ?? data['receiptImage'] ?? '').toString(),
      status: (data['status'] ?? 'pending').toString(),
      password: (data['password'] ?? '').toString(),
      rejectionReason: (data['rejectionReason'] ?? '').toString(),
      source: (data['source'] ?? '').toString(),
      createdAt: _parseDateTime(data['createdAt']),
      reviewedAt: _parseDateTime(data['reviewedAt']),
    );
  }
}

class SubscriptionRequestService {
  static const String adminRootNode = 'admin';
  static const String collectionName = 'subscription_requests';
  static const String collectionCompatName = 'subscriptionRequests';
  static const String pendingStatus = 'pending';
  static const String approvedStatus = 'approved';
  static const String rejectedStatus = 'rejected';

  static DatabaseReference get _root => FirebaseDatabase.instance.ref();
  static bool _legacyMigrationAttempted = false;

  static String get _adminCollectionPath => '$adminRootNode/$collectionName';
  static String get _adminCompatCollectionPath => '$adminRootNode/$collectionCompatName';

  static Map<String, dynamic> _mapOf(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }

  static Future<void> _migrateLegacyNodesIfNeeded() async {
    if (_legacyMigrationAttempted) return;
    _legacyMigrationAttempted = true;

    try {
      final rootSnap = await _root.get();
      final rootMap = _mapOf(rootSnap.value);
      final adminMap = _mapOf(rootMap[adminRootNode]);
      final updates = <String, dynamic>{};

      void migrateNode({required String legacyNode, required String adminPath, required String adminNodeName}) {
        final legacyData = _mapOf(rootMap[legacyNode]);
        if (legacyData.isEmpty) return;

        final adminData = _mapOf(adminMap[adminNodeName]);
        if (adminData.isEmpty) {
          updates[adminPath] = legacyData;
        } else {
          for (final entry in legacyData.entries) {
            if (!adminData.containsKey(entry.key)) {
              updates['$adminPath/${entry.key}'] = entry.value;
            }
          }
        }

        updates[legacyNode] = null;
      }

      migrateNode(
        legacyNode: collectionName,
        adminPath: _adminCollectionPath,
        adminNodeName: collectionName,
      );
      migrateNode(
        legacyNode: collectionCompatName,
        adminPath: _adminCompatCollectionPath,
        adminNodeName: collectionCompatName,
      );

      if (updates.isNotEmpty) {
        await _root.update(updates);
      }
    } catch (_) {
      // Keep app behavior stable if migration cannot run now.
    }
  }

  static Future<DatabaseReference> _resolveRequestRef(String requestId) async {
    final candidatePaths = <String>[
      '$_adminCollectionPath/$requestId',
      '$_adminCompatCollectionPath/$requestId',
      '$collectionName/$requestId',
      '$collectionCompatName/$requestId',
    ];
    for (final path in candidatePaths) {
      final snap = await _root.child(path).get();
      if (snap.exists) return _root.child(path);
    }
    return _root.child('$_adminCollectionPath/$requestId');
  }

  static DatabaseReference requestRef(String requestId) => _root.child('$_adminCollectionPath/$requestId');

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

  static bool isTrialPlan(String plan) => plan == 'trial' || plan == 'free_15_days';

  static DateTime startDateForPlan({DateTime? now}) => now ?? DateTime.now();

  static DateTime endDateForPlan(String plan, {DateTime? from}) {
    final start = from ?? DateTime.now();
    switch (plan.trim()) {
      case 'trial':
      case 'free_15_days':
        return start.add(const Duration(days: 15));
      case '3m':
      case 'three_months':
        return start.add(const Duration(days: 90));
      case '6m':
      case 'six_months':
        return start.add(const Duration(days: 183));
      case '1y':
      case 'one_year':
        return start.add(const Duration(days: 365));
      default:
        return start.add(const Duration(days: 15));
    }
  }

  static Stream<List<SubscriptionRequestModel>> watchRequests({String? status}) {
    return _root.onValue.asyncMap((event) async {
      await _migrateLegacyNodesIfNeeded();
      final rootValue = event.snapshot.value;
      if (rootValue is! Map) return const <SubscriptionRequestModel>[];

      final rootMap = _mapOf(rootValue);
      final adminMap = _mapOf(rootMap[adminRootNode]);
      final adminSnake = _mapOf(adminMap[collectionName]);
      final adminCamel = _mapOf(adminMap[collectionCompatName]);
      final legacySnake = _mapOf(rootMap[collectionName]);
      final legacyCamel = _mapOf(rootMap[collectionCompatName]);
      final merged = <String, dynamic>{
        ...legacySnake,
        ...legacyCamel,
        ...adminCamel,
        ...adminSnake,
      };

      final records = <SubscriptionRequestModel>[];
      for (final entry in merged.entries) {
        if (entry.value is! Map) continue;
        final raw = Map<String, dynamic>.from(entry.value as Map);
        raw.putIfAbsent('requestId', () => entry.key.toString());
        final record = SubscriptionRequestModel.fromMap(raw);
        if (status == null || status.isEmpty || record.status == status) {
          records.add(record);
        }
      }

      records.sort((a, b) {
        final aTs = a.createdAt?.millisecondsSinceEpoch ?? 0;
        final bTs = b.createdAt?.millisecondsSinceEpoch ?? 0;
        return bTs.compareTo(aTs);
      });

      return records;
    });
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
    String? receiptImageUrl,
    required String password,
  }) async {
    final nodeRef = _root.child(_adminCollectionPath).push();
    final requestId = nodeRef.key ?? DateTime.now().millisecondsSinceEpoch.toString();
    final model = SubscriptionRequestModel(
      requestId: requestId,
      firstName: firstName,
      lastName: lastName,
      phone: phone,
      email: email,
      selectedPlan: selectedPlan,
      amount: amount,
      paymentMethod: paymentMethod,
      transferNumber: transferNumber,
      receiptImageUrl: receiptImageUrl ?? '',
      password: password,
      createdAt: DateTime.now(),
    );

    await requestRef(requestId).set(model.toMap());
    return requestId;
  }

  static Future<String?> uploadReceiptImage({required String requestId, required XFile file}) async {
    final storageRef = FirebaseStorage.instance.ref('admin/subscription_requests/$requestId/${file.name}');
    final bytes = await file.readAsBytes();
    final task = await storageRef.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    return task.ref.getDownloadURL();
  }

  static Future<void> rejectRequest({required String requestId, String? reason}) async {
    final ref = await _resolveRequestRef(requestId);
    await ref.update({
      'status': rejectedStatus,
      'rejectionReason': reason ?? '',
      'reviewedAt': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static Future<void> markRequestAsPendingReview({required String requestId, required Map<String, dynamic> patch}) async {
    final ref = await _resolveRequestRef(requestId);
    await ref.update(patch);
  }

  static Future<void> deleteRequest({required String requestId}) async {
    final id = requestId.trim();
    if (id.isEmpty) return;

    await _migrateLegacyNodesIfNeeded();
    final updates = <String, dynamic>{
      '$_adminCollectionPath/$id': null,
      '$_adminCompatCollectionPath/$id': null,
      '$collectionName/$id': null,
      '$collectionCompatName/$id': null,
    };
    await _root.update(updates);
  }

  static Future<void> approveRequestById({required String requestId, required Map<String, dynamic> requestData}) async {
    final request = SubscriptionRequestModel(
      requestId: requestId,
      firstName: (requestData['firstName'] ?? '').toString(),
      lastName: (requestData['lastName'] ?? '').toString(),
      phone: (requestData['phone'] ?? '').toString(),
      email: (requestData['email'] ?? '').toString(),
      selectedPlan: (requestData['selectedPlan'] ?? '').toString(),
      amount: (requestData['amount'] ?? '').toString(),
      paymentMethod: (requestData['paymentMethod'] ?? 'Qi Card').toString(),
      transferNumber: (requestData['transferNumber'] ?? '').toString(),
      receiptImageUrl: (requestData['receiptImageUrl'] ?? '').toString(),
      password: (requestData['password'] ?? '').toString(),
      status: (requestData['status'] ?? pendingStatus).toString(),
      source: (requestData['source'] ?? '').toString(),
      createdAt: _parseDateTime(requestData['createdAt']),
      reviewedAt: _parseDateTime(requestData['reviewedAt']),
    );
    await approveRequest(request: request);
  }

  static Future<void> approveRequest({required SubscriptionRequestModel request}) async {
    final reqRef = await _resolveRequestRef(request.requestId);

    final email = request.email.trim().toLowerCase();
    final password = request.password.trim();

    if (email.isEmpty || password.isEmpty) {
      throw Exception('Missing credentials for subscription request approval');
    }

    try {
      final callable = FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable('approveSubscriptionRequest');
      final result = await callable.call<Map<String, dynamic>>({
        'requestId': request.requestId,
        'email': email,
        'password': password,
        'firstName': request.firstName,
        'lastName': request.lastName,
        'phone': request.phone,
        'selectedPlan': request.selectedPlan,
        'planLabel': planLabel(request.selectedPlan),
        'amount': request.amount,
        'paymentMethod': request.paymentMethod,
      });

      final uid = (result.data['uid'] ?? '').toString();
      await reqRef.update({
        'uid': uid,
        'status': approvedStatus,
        'reviewedAt': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      await reqRef.update({
        'status': rejectedStatus,
        'rejectionReason': 'فشل في إنشاء الحساب: $e',
        'reviewedAt': DateTime.now().toUtc().toIso8601String(),
      });
      rethrow;
    }
  }
}
