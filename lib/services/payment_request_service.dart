import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

import '../models.dart';
import 'subscription_request_service.dart';

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

  static String label(String value) =>
      AppStore.subscriptionPlanLabelFor(normalize(value));

  static int durationDays(String value) =>
      AppStore.subscriptionDurationDaysFor(normalize(value));

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
    this.approvedBy = '',
    this.approvedAt,
    this.rejectedBy = '',
    this.rejectedAt,
    this.rejectReason = '',
    this.isRenewal = false,
    this.renewalForUid = '',
    this.collectionPath = SubscriptionRequestService.collectionName,
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
  final String approvedBy;
  final int? approvedAt;
  final String rejectedBy;
  final int? rejectedAt;
  final String rejectReason;
  final bool isRenewal;
  final String renewalForUid;
  final String collectionPath;

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
    'receiptImageUrl': receiptImage,
    'status': status,
    'createdAt': createdAt,
    'userType': userType,
    'governorate': governorate,
    'region': region,
    'address': address,
    'isRenewal': isRenewal,
    'renewalForUid': renewalForUid,
  };

  factory PaymentRequestRecord.fromMap(Map<String, dynamic> raw) {
    final firstName = (raw['firstName'] ?? '').toString().trim();
    final lastName = (raw['lastName'] ?? '').toString().trim();
    final fullName = '$firstName $lastName'.trim();
    return PaymentRequestRecord(
      requestId: (raw['requestId'] ?? raw['id'] ?? '').toString(),
      uid: (raw['uid'] ?? '').toString(),
      email: (raw['email'] ?? '').toString(),
      agentName: (raw['agentName'] ?? fullName).toString(),
      phone: (raw['phone'] ?? '').toString(),
      selectedPlan: PaymentPlanCatalog.normalize(
        (raw['selectedPlan'] ?? '').toString(),
      ),
      amount: (raw['amount'] ?? '').toString(),
      paymentMethod: (raw['paymentMethod'] ?? 'Qi Card').toString(),
      transferNumber: (raw['transferNumber'] ?? '').toString(),
      receiptImage: (raw['receiptImageUrl'] ?? raw['receiptImage'] ?? '')
          .toString(),
      status: (raw['status'] ?? 'pending').toString(),
      createdAt:
          _intValue(raw['createdAt']) ?? DateTime.now().millisecondsSinceEpoch,
      userType: (raw['userType'] ?? 'agent').toString(),
      governorate: (raw['governorate'] ?? '').toString(),
      region: (raw['region'] ?? '').toString(),
      address: (raw['address'] ?? '').toString(),
      approvedBy: (raw['approvedBy'] ?? '').toString(),
      approvedAt: _intValue(raw['approvedAt']),
      rejectedBy: (raw['rejectedBy'] ?? '').toString(),
      rejectedAt: _intValue(raw['rejectedAt']),
      rejectReason: (raw['rejectionReason'] ?? raw['rejectReason'] ?? '')
          .toString(),
      isRenewal: raw['isRenewal'] == true,
      renewalForUid: (raw['renewalForUid'] ?? '').toString(),
      collectionPath:
          (raw['collectionPath'] ?? SubscriptionRequestService.collectionName)
              .toString(),
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
  static const String _requestsPath =
      'admin/${SubscriptionRequestService.collectionName}';

  static DatabaseReference get _root => FirebaseDatabase.instance.ref();

  static Future<RenewalRequestState?> findLatestRenewalRequestForAccount({
    required String uid,
    required String email,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || !_matchesAccount(user, uid, email)) return null;
    final snapshot = await _requestsForUid(user.uid).get();
    return _latestRenewalRequest(snapshot.value, user.uid);
  }

  static Stream<RenewalRequestState?> watchLatestRenewalRequestForAccount({
    required String uid,
    required String email,
  }) async* {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || !_matchesAccount(user, uid, email)) {
      yield null;
      return;
    }
    yield* _requestsForUid(user.uid).onValue.map(
      (event) => _latestRenewalRequest(event.snapshot.value, user.uid),
    );
  }

  static bool _matchesAccount(User user, String uid, String email) =>
      user.uid == uid.trim() &&
      user.email?.trim().toLowerCase() == email.trim().toLowerCase();

  static Query _requestsForUid(String uid) =>
      _root.child(_requestsPath).orderByChild('uid').equalTo(uid);

  static RenewalRequestState? _latestRenewalRequest(Object? value, String uid) {
    if (value is! Map) return null;
    RenewalRequestState? latest;
    for (final entry in value.entries) {
      if (entry.value is! Map) continue;
      final request = Map<String, dynamic>.from(entry.value as Map);
      if (request['uid'] != uid || request['isRenewal'] != true) continue;
      final requestId = entry.key.toString();
      final candidate = _renewalState(requestId, request);
      if (latest == null || candidate.createdAt > latest.createdAt) {
        latest = candidate;
      }
    }
    return latest;
  }

  static RenewalRequestState _renewalState(
    String requestId,
    Map<String, dynamic> request,
  ) {
    return RenewalRequestState(
      requestId: (request['requestId'] ?? requestId).toString(),
      status: (request['status'] ?? '').toString(),
      createdAt: PaymentRequestRecord._intValue(request['createdAt']) ?? 0,
      rejectionReason:
          (request['rejectionReason'] ?? request['rejectReason'] ?? '')
              .toString(),
      reviewedAt: PaymentRequestRecord._intValue(request['reviewedAt']),
      selectedPlan: (request['selectedPlan'] ?? '').toString(),
    );
  }

  static Stream<List<PaymentRequestRecord>> watchRequests({String? status}) {
    return SubscriptionRequestService.watchRequests(status: status).map(
      (requests) => requests
          .map(
            (request) => PaymentRequestRecord.fromMap({
              ...request.toMap(),
              'collectionPath': request.collectionPath,
            }),
          )
          .toList(),
    );
  }

  static Stream<List<PaymentRequestRecord>> watchPendingRequests() =>
      watchRequests(status: SubscriptionRequestService.pendingStatus);

  static Future<String> createRequest({
    String uid = '',
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
    bool isRenewal = false,
    String renewalForUid = '',
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Sign in before creating a request.');
    if (user.uid == SubscriptionRequestService.trustedAdminUid) {
      throw StateError(
        'The administrator account cannot submit an agent subscription request.',
      );
    }
    if (uid.trim().isNotEmpty && uid.trim() != user.uid) {
      throw StateError(
        'A request can only be created for the signed-in account.',
      );
    }
    if (isRenewal && renewalForUid.trim() != user.uid) {
      throw StateError(
        'A renewal request can only target the signed-in account.',
      );
    }

    final normalizedPlan = PaymentPlanCatalog.normalize(selectedPlan);
    if (!PaymentPlanCatalog.supportedPlans.contains(normalizedPlan)) {
      throw ArgumentError.value(
        selectedPlan,
        'selectedPlan',
        'Unsupported subscription plan.',
      );
    }
    final expectedAmount = PaymentPlanCatalog.amount(normalizedPlan);
    if (amount.trim() != expectedAmount) {
      throw ArgumentError.value(
        amount,
        'amount',
        'Amount does not match the selected plan.',
      );
    }
    final nameParts = agentName.trim().split(RegExp(r'\s+'));
    final requestId = await SubscriptionRequestService.createRequest(
      uid: user.uid,
      firstName: nameParts.isEmpty ? '' : nameParts.first,
      lastName: nameParts.length < 2 ? '' : nameParts.skip(1).join(' '),
      agentName: agentName,
      phone: phone,
      email: user.email ?? email.trim().toLowerCase(),
      governorate: governorate,
      region: region,
      address: address,
      selectedPlan: normalizedPlan,
      amount: PaymentPlanCatalog.amount(normalizedPlan),
      paymentMethod: paymentMethod,
      transferNumber: transferNumber,
      receiptImageUrl: receiptImage,
      isRenewal: isRenewal,
    );
    return requestId;
  }

  static Future<String?> uploadReceiptImage({
    required String requestId,
    required XFile file,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Sign in before uploading a receipt.');
    final extension = file.name.split('.').last.toLowerCase();
    final contentType = switch (extension) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'pdf' => 'application/pdf',
      _ => 'image/jpeg',
    };
    final storageRef = FirebaseStorage.instance.ref(
      'admin/subscriptionRequests/$requestId/${file.name}',
    );
    final task = await storageRef.putData(
      await file.readAsBytes(),
      SettableMetadata(contentType: contentType),
    );
    return task.ref.getDownloadURL();
  }

  static Future<void> markRequestAsPendingReview({
    required String requestId,
    required Map<String, dynamic> patch,
  }) {
    return SubscriptionRequestService.markRequestAsPendingReview(
      requestId: requestId,
      patch: patch,
    );
  }

  static Future<Map<String, dynamic>> approveRequest({
    required PaymentRequestRecord request,
  }) async {
    final result = await SubscriptionRequestService.approveRequestById(
      requestId: request.requestId,
      requestData: request.toMap(),
      collectionPath: request.collectionPath,
    );
    return result;
  }

  static Future<void> rejectRequest({
    required PaymentRequestRecord request,
    required String rejectReason,
  }) {
    return SubscriptionRequestService.rejectRequest(
      requestId: request.requestId,
      reason: rejectReason,
      collectionPath: request.collectionPath,
    );
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
