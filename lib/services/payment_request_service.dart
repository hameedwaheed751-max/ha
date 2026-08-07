import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

import '../firebase_options.dart';
import '../models.dart';

class PaymentPlanCatalog {
  static const String free15Days = 'free_15_days';
  static const String threeMonths = 'three_months';
  static const String sixMonths = 'six_months';
  static const String oneYear = 'one_year';

  static const List<String> supportedPlans = <String>[
    free15Days,
    threeMonths,
    sixMonths,
    oneYear,
  ];

  static String normalize(String value) {
    switch (value.trim()) {
      case 'trial':
        return free15Days;
      case '3m':
        return threeMonths;
      case '6m':
        return sixMonths;
      case '1y':
        return oneYear;
      default:
        return value.trim().isEmpty ? free15Days : value.trim();
    }
  }

  static String label(String value) => AppStore.subscriptionPlanLabelFor(normalize(value));

  static int durationDays(String value) => AppStore.subscriptionDurationDaysFor(normalize(value));

  static String amount(String value) {
    switch (normalize(value)) {
      case free15Days:
        return 'مجاني';
      case threeMonths:
        return '40000';
      case sixMonths:
        return '50000';
      case oneYear:
        return '70000';
      default:
        return '0';
    }
  }
}

class PaymentRequestRecord {
  PaymentRequestRecord({
    required this.requestId,
    required this.uid,
    required this.email,
    required this.agentName,
    required this.phone,
    required this.selectedPlan,
    required this.amount,
    required this.paymentMethod,
    required this.transferNumber,
    required this.receiptImage,
    required this.status,
    required this.createdAt,
    this.userType = 'agent',
    this.governorate = '',
    this.region = '',
    this.address = '',
    this.password = '',
    this.approvedBy = '',
    this.approvedAt,
    this.rejectedBy = '',
    this.rejectedAt,
    this.rejectReason = '',
    this.isRenewal = false,
    this.renewalForUid = '',
  });

  final String requestId;
  final String uid;
  final String email;
  final String agentName;
  final String phone;
  final String selectedPlan;
  final String amount;
  final String paymentMethod;
  final String transferNumber;
  final String receiptImage;
  final String status;
  final int createdAt;
  final String userType;
  final String governorate;
  final String region;
  final String address;
  final String password;
  final String approvedBy;
  final int? approvedAt;
  final String rejectedBy;
  final int? rejectedAt;
  final String rejectReason;
  final bool isRenewal;
  final String renewalForUid;

  String get planLabel => PaymentPlanCatalog.label(selectedPlan);

  Map<String, dynamic> toMap() => {
        'requestId': requestId,
        'uid': uid,
        'email': email,
        'agentName': agentName,
        'phone': phone,
        'selectedPlan': selectedPlan,
        'amount': amount,
        'paymentMethod': paymentMethod,
        'transferNumber': transferNumber,
        'receiptImage': receiptImage,
        'status': status,
        'createdAt': createdAt,
        'userType': userType,
        'governorate': governorate,
        'region': region,
        'address': address,
        'password': password,
        'approvedBy': approvedBy,
        'approvedAt': approvedAt,
        'rejectedBy': rejectedBy,
        'rejectedAt': rejectedAt,
        'rejectReason': rejectReason,
        'isRenewal': isRenewal,
        'renewalForUid': renewalForUid,
      };

  factory PaymentRequestRecord.fromMap(Map<String, dynamic> raw) {
    return PaymentRequestRecord(
      requestId: (raw['requestId'] ?? raw['id'] ?? '').toString(),
      uid: (raw['uid'] ?? '').toString(),
      email: (raw['email'] ?? '').toString(),
      agentName: (raw['agentName'] ?? '').toString(),
      phone: (raw['phone'] ?? '').toString(),
      selectedPlan: PaymentPlanCatalog.normalize((raw['selectedPlan'] ?? '').toString()),
      amount: (raw['amount'] ?? '').toString(),
      paymentMethod: (raw['paymentMethod'] ?? 'Qi Card').toString(),
      transferNumber: (raw['transferNumber'] ?? '').toString(),
      receiptImage: (raw['receiptImage'] ?? raw['receiptImageUrl'] ?? '').toString(),
      status: (raw['status'] ?? 'pending').toString(),
      createdAt: _intValue(raw['createdAt']) ?? DateTime.now().millisecondsSinceEpoch,
      userType: (raw['userType'] ?? 'agent').toString(),
      governorate: (raw['governorate'] ?? '').toString(),
      region: (raw['region'] ?? '').toString(),
      address: (raw['address'] ?? '').toString(),
      password: (raw['password'] ?? '').toString(),
      approvedBy: (raw['approvedBy'] ?? '').toString(),
      approvedAt: _intValue(raw['approvedAt']),
      rejectedBy: (raw['rejectedBy'] ?? '').toString(),
      rejectedAt: _intValue(raw['rejectedAt']),
      rejectReason: (raw['rejectReason'] ?? raw['rejectionReason'] ?? '').toString(),
      isRenewal: raw['isRenewal'] == true || raw['isRenewal'].toString().toLowerCase() == 'true',
      renewalForUid: (raw['renewalForUid'] ?? '').toString(),
    );
  }

  static int? _intValue(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String && value.trim().isNotEmpty) {
      return int.tryParse(value.trim());
    }
    return null;
  }
}

class RenewalRequestState {
  RenewalRequestState({
    required this.requestId,
    required this.status,
    required this.createdAt,
    this.rejectionReason = '',
    this.reviewedAt,
    this.selectedPlan = '',
  });

  final String requestId;
  final String status;
  final int createdAt;
  final String rejectionReason;
  final int? reviewedAt;
  final String selectedPlan;

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';

  int get sortTs => reviewedAt ?? createdAt;
}

class PaymentRequestService {
  static const String adminRootNode = 'admin';
  static const String paymentRequestsNode = 'paymentRequests';
  static const String paymentHistoryNode = 'paymentHistory';
  static const String subscriptionRequestsSnakeNode = 'subscription_requests';
  static const String subscriptionRequestsCamelNode = 'subscriptionRequests';
  static const String subscriptionNode = 'subscription';

  static DatabaseReference get _root => FirebaseDatabase.instance.ref();
  static bool _legacyMigrationAttempted = false;

  static String get _adminPaymentRequestsPath => '$adminRootNode/$paymentRequestsNode';
  static String get _adminPaymentHistoryPath => '$adminRootNode/$paymentHistoryNode';
  static String get _adminSubscriptionRequestsSnakePath => '$adminRootNode/$subscriptionRequestsSnakeNode';
  static String get _adminSubscriptionRequestsCamelPath => '$adminRootNode/$subscriptionRequestsCamelNode';

  static Map<String, dynamic> _mapOf(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }

  static int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String && value.trim().isNotEmpty) {
      return int.tryParse(value.trim());
    }
    return null;
  }

  static bool _isRenewalRecord(Map<String, dynamic> raw) {
    final isRenewalFlag = raw['isRenewal'] == true || raw['isRenewal'].toString().toLowerCase() == 'true';
    final renewalForUid = (raw['renewalForUid'] ?? '').toString().trim();
    final requestType = (raw['requestType'] ?? '').toString().trim().toLowerCase();
    return isRenewalFlag || renewalForUid.isNotEmpty || requestType == 'renewal';
  }

  static bool _matchesAccount(Map<String, dynamic> raw, {required String uid, required String email}) {
    final normalizedEmail = email.trim().toLowerCase();
    final rawUidA = (raw['renewalForUid'] ?? '').toString().trim();
    final rawUidB = (raw['uid'] ?? '').toString().trim();
    final rawEmail = (raw['email'] ?? '').toString().trim().toLowerCase();

    if (uid.trim().isNotEmpty && (rawUidA == uid.trim() || rawUidB == uid.trim())) {
      return true;
    }
    if (normalizedEmail.isNotEmpty && rawEmail == normalizedEmail) {
      return true;
    }
    return false;
  }

  static int? _eventTs(Map<String, dynamic> raw) {
    return _toInt(raw['reviewedAt']) ??
      _toInt(raw['approvedAt']) ??
      _toInt(raw['rejectedAt']) ??
      _toInt(raw['createdAt']);
  }

  static RenewalRequestState? _latestRenewalFromRootMap(
    Map<String, dynamic> rootMap, {
    required String uid,
    required String email,
  }) {
    final adminMap = _mapOf(rootMap[adminRootNode]);
    final adminRequests = _mapOf(adminMap[paymentRequestsNode]);
    final legacyRequests = _mapOf(rootMap[paymentRequestsNode]);
    final allRequests = <String, dynamic>{
      ...legacyRequests,
      ...adminRequests,
    };

    final adminHistory = _mapOf(adminMap[paymentHistoryNode]);
    final legacyHistory = _mapOf(rootMap[paymentHistoryNode]);
    final allHistory = <String, dynamic>{
      ...legacyHistory,
      ...adminHistory,
    };

    RenewalRequestState? latestPending;
    RenewalRequestState? latestResolved;

    for (final entry in allRequests.entries) {
      if (entry.value is! Map) continue;
      final raw = Map<String, dynamic>.from(entry.value as Map);
      if (!_isRenewalRecord(raw) || !_matchesAccount(raw, uid: uid, email: email)) continue;

      final status = (raw['status'] ?? 'pending').toString().trim().toLowerCase();
      if (status != 'pending') continue;

      final createdAt = _toInt(raw['createdAt']) ?? DateTime.now().millisecondsSinceEpoch;
      final state = RenewalRequestState(
        requestId: (raw['requestId'] ?? entry.key).toString(),
        status: 'pending',
        createdAt: createdAt,
        rejectionReason: (raw['rejectReason'] ?? raw['rejectionReason'] ?? '').toString(),
        reviewedAt: _eventTs(raw),
        selectedPlan: (raw['selectedPlan'] ?? '').toString(),
      );
      if (latestPending == null || state.sortTs > latestPending.sortTs) {
        latestPending = state;
      }
    }

    for (final entry in allHistory.entries) {
      if (entry.value is! Map) continue;
      final raw = Map<String, dynamic>.from(entry.value as Map);
      if (!_isRenewalRecord(raw) || !_matchesAccount(raw, uid: uid, email: email)) continue;

      final status = (raw['status'] ?? '').toString().trim().toLowerCase();
      if (status != 'approved' && status != 'rejected') continue;

      final createdAt = _toInt(raw['createdAt']) ?? DateTime.now().millisecondsSinceEpoch;
      final state = RenewalRequestState(
        requestId: (raw['requestId'] ?? entry.key).toString(),
        status: status,
        createdAt: createdAt,
        rejectionReason: (raw['rejectReason'] ?? raw['rejectionReason'] ?? '').toString(),
        reviewedAt: _eventTs(raw),
        selectedPlan: (raw['selectedPlan'] ?? '').toString(),
      );
      if (latestResolved == null || state.sortTs > latestResolved.sortTs) {
        latestResolved = state;
      }
    }

    return latestPending ?? latestResolved;
  }

  static Future<RenewalRequestState?> findLatestRenewalRequestForAccount({
    required String uid,
    required String email,
  }) async {
    await _migrateLegacyAdminNodesIfNeeded();
    final snap = await _root.get();
    final rootMap = _mapOf(snap.value);
    return _latestRenewalFromRootMap(rootMap, uid: uid.trim(), email: email.trim().toLowerCase());
  }

  static Stream<RenewalRequestState?> watchLatestRenewalRequestForAccount({
    required String uid,
    required String email,
  }) {
    return _root.onValue.asyncMap((event) async {
      await _migrateLegacyAdminNodesIfNeeded();
      final rootValue = event.snapshot.value;
      if (rootValue is! Map) return null;
      final rootMap = _mapOf(rootValue);
      return _latestRenewalFromRootMap(rootMap, uid: uid.trim(), email: email.trim().toLowerCase());
    });
  }

  static Future<void> _migrateLegacyAdminNodesIfNeeded() async {
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
        legacyNode: paymentRequestsNode,
        adminPath: _adminPaymentRequestsPath,
        adminNodeName: paymentRequestsNode,
      );
      migrateNode(
        legacyNode: paymentHistoryNode,
        adminPath: _adminPaymentHistoryPath,
        adminNodeName: paymentHistoryNode,
      );
      migrateNode(
        legacyNode: subscriptionRequestsSnakeNode,
        adminPath: _adminSubscriptionRequestsSnakePath,
        adminNodeName: subscriptionRequestsSnakeNode,
      );
      migrateNode(
        legacyNode: subscriptionRequestsCamelNode,
        adminPath: _adminSubscriptionRequestsCamelPath,
        adminNodeName: subscriptionRequestsCamelNode,
      );

      if (updates.isNotEmpty) {
        await _root.update(updates);
      }
    } catch (_) {
      // Keep app behavior stable if migration cannot run now.
    }
  }

  static Future<String> _resolveRequestPath(String requestId) async {
    final adminPath = '$_adminPaymentRequestsPath/$requestId';
    final adminSnap = await _root.child(adminPath).get();
    if (adminSnap.exists) return adminPath;

    final legacyPath = '$paymentRequestsNode/$requestId';
    final legacySnap = await _root.child(legacyPath).get();
    if (legacySnap.exists) return legacyPath;

    return adminPath;
  }

  static DatabaseReference requestRef(String requestId) => _root.child('$_adminPaymentRequestsPath/$requestId');
  static DatabaseReference historyRef(String requestId) => _root.child('$_adminPaymentHistoryPath/$requestId');
  static DatabaseReference subscriptionRef(String uid) => _root.child('agents/$uid/$subscriptionNode');

  static Stream<List<PaymentRequestRecord>> watchRequests({String? status}) {
    return _root.onValue.asyncMap((event) async {
      await _migrateLegacyAdminNodesIfNeeded();
      final rootValue = event.snapshot.value;
      if (rootValue is! Map) return const <PaymentRequestRecord>[];

      final rootMap = _mapOf(rootValue);
      final adminMap = _mapOf(rootMap[adminRootNode]);
      final adminRequests = _mapOf(adminMap[paymentRequestsNode]);
      final legacyRequests = _mapOf(rootMap[paymentRequestsNode]);
      final mergedRequests = <String, dynamic>{
        ...legacyRequests,
        ...adminRequests,
      };

      final records = <PaymentRequestRecord>[];
      for (final entry in mergedRequests.entries) {
        if (entry.value is Map) {
          final raw = Map<String, dynamic>.from(entry.value as Map);
          final existingId = (raw['requestId'] ?? '').toString().trim();
          if (existingId.isEmpty) {
            raw['requestId'] = entry.key.toString();
          }
          final record = PaymentRequestRecord.fromMap(raw);
          if (status == null || status.isEmpty || record.status == status) {
            records.add(record);
          }
        }
      }
      records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return records;
    });
  }

  static Stream<List<PaymentRequestRecord>> watchPendingRequests() => watchRequests(status: 'pending');

  static Future<String> createRequest({
    String uid = '',
    String userType = 'agent',
    required String email,
    required String agentName,
    required String phone,
    String governorate = '',
    String region = '',
    String address = '',
    required String selectedPlan,
    required String amount,
    required String paymentMethod,
    required String transferNumber,
    String receiptImage = '',
    String password = '',
    bool isRenewal = false,
    String renewalForUid = '',
  }) async {
    final normalizedPlan = PaymentPlanCatalog.normalize(selectedPlan);
    final docRef = _root.child(_adminPaymentRequestsPath).push();
    final requestId = docRef.key ?? DateTime.now().millisecondsSinceEpoch.toString();
    final now = DateTime.now().millisecondsSinceEpoch;
    final payload = PaymentRequestRecord(
      requestId: requestId,
      uid: uid,
      email: email,
      agentName: agentName,
      phone: phone,
      selectedPlan: normalizedPlan,
      amount: amount,
      paymentMethod: paymentMethod,
      transferNumber: transferNumber,
      receiptImage: receiptImage,
      status: 'pending',
      createdAt: now,
      userType: userType,
      governorate: governorate,
      region: region,
      address: address,
      password: password,
      isRenewal: isRenewal,
      renewalForUid: renewalForUid,
    );

    await requestRef(requestId).set(payload.toMap());
    return requestId;
  }

  static Future<String?> uploadReceiptImage({required String requestId, required XFile file}) async {
    final storageRef = FirebaseStorage.instance.ref('admin/paymentRequests/$requestId/${file.name}');
    final bytes = await file.readAsBytes();
    final task = await storageRef.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    return task.ref.getDownloadURL();
  }

  static Future<void> markRequestAsPendingReview({required String requestId, required Map<String, dynamic> patch}) async {
    final path = await _resolveRequestPath(requestId);
    await _root.child(path).update(patch);
  }

  static Future<void> addHistoryEntry(String requestId, Map<String, dynamic> history) async {
    await historyRef(requestId).set(history);
  }

  static String _isoDate(DateTime value) => value.toUtc().toIso8601String();

  static DateTime? _parseDate(dynamic value) {
    if (value is String && value.trim().isNotEmpty) {
      return DateTime.tryParse(value.trim())?.toUtc();
    }
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
    }
    return null;
  }

  static (String firstName, String lastName) _splitName(String fullName) {
    final parts = fullName
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return ('', '');
    if (parts.length == 1) return (parts.first, '');
    return (parts.first, parts.sublist(1).join(' '));
  }

  static Future<String> _ensureAgentUid(PaymentRequestRecord request) async {
    final existingUid = request.uid.trim();
    if (existingUid.isNotEmpty) return existingUid;

    final email = request.email.trim().toLowerCase();
    final password = request.password;
    if (email.isEmpty || password.isEmpty) {
      throw Exception('الطلب لا يحتوي بيانات حساب كافية (email/password)');
    }

    final appName = 'agent-create-${DateTime.now().microsecondsSinceEpoch}';
    FirebaseApp? tempApp;
    try {
      tempApp = await Firebase.initializeApp(
        name: appName,
        options: DefaultFirebaseOptions.currentPlatform,
      );
      final tempAuth = FirebaseAuth.instanceFor(app: tempApp);
      try {
        final cred = await tempAuth.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
        return cred.user!.uid;
      } on FirebaseAuthException catch (e) {
        if (e.code == 'email-already-in-use') {
          final cred = await tempAuth.signInWithEmailAndPassword(
            email: email,
            password: password,
          );
          return cred.user!.uid;
        }
        rethrow;
      } finally {
        await tempAuth.signOut();
      }
    } on FirebaseAuthException catch (e) {
      throw Exception('تعذر إنشاء حساب الوكيل: ${e.message ?? e.code}');
    } finally {
      if (tempApp != null) {
        await tempApp.delete();
      }
    }
  }

  static Future<String?> _findAgentUidByEmail(String email) async {
    final normalized = email.trim().toLowerCase();
    if (normalized.isEmpty) return null;

    final snapshot = await _root.child('agents').get();
    final value = snapshot.value;
    if (value is! Map) return null;

    for (final entry in value.entries) {
      if (entry.value is! Map) continue;
      final node = Map<String, dynamic>.from(entry.value as Map);
      final profile = node['profile'] is Map
          ? Map<String, dynamic>.from(node['profile'] as Map)
          : <String, dynamic>{};
      final candidateEmail = (profile['email'] ?? '').toString().trim().toLowerCase();
      if (candidateEmail == normalized) {
        return entry.key.toString();
      }
    }
    return null;
  }

  static Future<String> _resolveRenewalUid(PaymentRequestRecord request) async {
    final directUid = request.renewalForUid.trim().isNotEmpty
        ? request.renewalForUid.trim()
        : request.uid.trim();
    if (directUid.isNotEmpty) return directUid;

    final byEmail = await _findAgentUidByEmail(request.email);
    if (byEmail != null && byEmail.isNotEmpty) return byEmail;

    throw Exception('تعذر تحديد الحساب الحالي للتجديد.');
  }

  static Future<Map<String, dynamic>> approveRequest({
    required PaymentRequestRecord request,
    required String approvedBy,
  }) async {
    final isRenewal = request.isRenewal || request.renewalForUid.trim().isNotEmpty;
    final uid = isRenewal
        ? await _resolveRenewalUid(request)
        : await _ensureAgentUid(request);

    final now = DateTime.now().toUtc();
    final normalizedPlan = PaymentPlanCatalog.normalize(request.selectedPlan);
    final durationDays = PaymentPlanCatalog.durationDays(normalizedPlan);

    final profileName = request.agentName.trim();
    final nameParts = _splitName(profileName);

    final agentRef = _root.child('agents/$uid');
    final agentSnap = await agentRef.get();
    if (!agentSnap.exists) {
      await agentRef.set(AppStore.buildEmptyAgentNodePayload(uid: uid));
    }

    final resolvedRole = request.userType.trim().toLowerCase() == 'admin' ? 'admin' : 'agent';
    final profilePayload = <String, dynamic>{
      'email': request.email.trim().toLowerCase(),
      'name': profileName,
      'firstName': nameParts.$1,
      'lastName': nameParts.$2,
      'phone': request.phone.trim(),
      'governorate': request.governorate.trim(),
      'region': request.region.trim(),
      'address': request.address.trim(),
      'emailKey': request.email.trim().toLowerCase(),
      'agentKey': request.email.trim().toLowerCase(),
      'currentAgentId': uid,
      'role': resolvedRole,
      'status': 'active',
      'approvedAt': now.millisecondsSinceEpoch,
    };

    await agentRef.child('profile').update(profilePayload);
    await agentRef.child('settings').update({
      'officeAddress': request.address.trim(),
    });

    final existingSubSnap = await subscriptionRef(uid).get();
    final existingSub = existingSubSnap.value is Map
        ? Map<String, dynamic>.from(existingSubSnap.value as Map)
        : <String, dynamic>{};

    final existingStatus = (existingSub['status'] ?? '').toString();
    final existingEnd = _parseDate(existingSub['endDate']);
    final startDate = isRenewal
      ? now
      : (existingStatus == 'active' &&
          existingEnd != null &&
          existingEnd.isAfter(now))
        ? existingEnd
        : now;
    final endDate = startDate.add(Duration(days: durationDays));

    final subscriptionPayload = <String, dynamic>{
      'plan': normalizedPlan,
      'status': 'active',
      'durationDays': durationDays,
      'startDate': _isoDate(startDate),
      'endDate': _isoDate(endDate),
      'autoExpire': true,
      'lastPaymentId': request.requestId,
    };

    final historyPayload = <String, dynamic>{
      ...request.toMap(),
      'uid': uid,
      'status': 'approved',
      'approvedBy': approvedBy,
      'approvedAt': now.millisecondsSinceEpoch,
      'subscription': subscriptionPayload,
    };

    final subscriptionRequestPayload = <String, dynamic>{
      'requestId': request.requestId,
      'uid': uid,
      'firstName': nameParts.$1,
      'lastName': nameParts.$2,
      'phone': request.phone,
      'email': request.email,
      'selectedPlan': normalizedPlan,
      'amount': request.amount,
      'paymentMethod': request.paymentMethod,
      'transferNumber': request.transferNumber,
      'receiptImageUrl': request.receiptImage,
      'status': 'approved',
      'password': request.password,
      'rejectionReason': '',
      'createdAt': request.createdAt,
      'reviewedAt': now.millisecondsSinceEpoch,
      'approvedBy': approvedBy,
      'approvedAt': now.millisecondsSinceEpoch,
      'source': 'paymentRequests',
      'isRenewal': isRenewal,
      'renewalForUid': uid,
      'requestType': isRenewal ? 'renewal' : 'new',
    };

    final updates = <String, dynamic>{
      'agents/$uid/$subscriptionNode': subscriptionPayload,
      '$_adminPaymentHistoryPath/${request.requestId}': historyPayload,
      '$_adminSubscriptionRequestsSnakePath/${request.requestId}': subscriptionRequestPayload,
      '$_adminSubscriptionRequestsCamelPath/${request.requestId}': subscriptionRequestPayload,
      '$paymentHistoryNode/${request.requestId}': null,
      '$subscriptionRequestsSnakeNode/${request.requestId}': null,
      '$subscriptionRequestsCamelNode/${request.requestId}': null,
      '$_adminPaymentRequestsPath/${request.requestId}': null,
      '$paymentRequestsNode/${request.requestId}': null,
    };
    await _root.update(updates);

    return <String, dynamic>{
      'startDate': _isoDate(startDate),
      'endDate': _isoDate(endDate),
      'durationDays': durationDays,
      'plan': normalizedPlan,
      'planLabel': PaymentPlanCatalog.label(normalizedPlan),
      'uid': uid,
    };
  }

  static Future<void> rejectRequest({
    required PaymentRequestRecord request,
    required String rejectedBy,
    required String rejectReason,
  }) async {
    final now = DateTime.now().toUtc();

    final historyPayload = <String, dynamic>{
      ...request.toMap(),
      'status': 'rejected',
      'rejectedBy': rejectedBy,
      'rejectedAt': now.millisecondsSinceEpoch,
      'rejectReason': rejectReason,
    };

    final nameParts = _splitName(request.agentName);
    final subscriptionRequestPayload = <String, dynamic>{
      'requestId': request.requestId,
      'uid': request.uid,
      'firstName': nameParts.$1,
      'lastName': nameParts.$2,
      'phone': request.phone,
      'email': request.email,
      'selectedPlan': request.selectedPlan,
      'amount': request.amount,
      'paymentMethod': request.paymentMethod,
      'transferNumber': request.transferNumber,
      'receiptImageUrl': request.receiptImage,
      'status': 'rejected',
      'password': request.password,
      'rejectionReason': rejectReason,
      'createdAt': request.createdAt,
      'reviewedAt': now.millisecondsSinceEpoch,
      'rejectedBy': rejectedBy,
      'rejectedAt': now.millisecondsSinceEpoch,
      'source': 'paymentRequests',
      'isRenewal': request.isRenewal,
      'renewalForUid': request.renewalForUid,
      'requestType': request.isRenewal ? 'renewal' : 'new',
    };

    final updates = <String, dynamic>{
      '$_adminPaymentHistoryPath/${request.requestId}': historyPayload,
      '$_adminSubscriptionRequestsSnakePath/${request.requestId}': subscriptionRequestPayload,
      '$_adminSubscriptionRequestsCamelPath/${request.requestId}': subscriptionRequestPayload,
      '$paymentHistoryNode/${request.requestId}': null,
      '$subscriptionRequestsSnakeNode/${request.requestId}': null,
      '$subscriptionRequestsCamelNode/${request.requestId}': null,
      '$_adminPaymentRequestsPath/${request.requestId}': null,
      '$paymentRequestsNode/${request.requestId}': null,
    };
    await _root.update(updates);
  }

  static String subscriptionStatusText(String status) {
    switch (status) {
      case 'active':
        return 'نشط';
      case 'expired':
        return 'منتهي';
      case 'inactive':
        return 'غير نشط';
      default:
        return status;
    }
  }
}
