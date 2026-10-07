import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
        if (approvedAt != null) 'approvedAt': approvedAt,
        if (rejectedAt != null) 'rejectedAt': rejectedAt,
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

  static FirebaseFunctions get _functions =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  static String _requestTokenKey(String purpose, String uid) =>
      'payment_request_${purpose}_$uid';

  static int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static Future<void> _saveRequestCapabilities({
    required String ownerKey,
    required String requestId,
    required String receiptToken,
    required String statusToken,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_requestTokenKey('id', ownerKey), requestId);
    await preferences.setString(_requestTokenKey('status', ownerKey), statusToken);
    await preferences.setString(_requestTokenKey('receipt', requestId), receiptToken);
  }

  static Future<RenewalRequestState?> _getRenewalRequestStatus(String uid) async {
    final preferences = await SharedPreferences.getInstance();
    final requestId = preferences.getString(_requestTokenKey('id', uid)) ?? '';
    final statusToken = preferences.getString(_requestTokenKey('status', uid)) ?? '';
    if (requestId.isEmpty || statusToken.isEmpty) return null;
    final result = await _functions.httpsCallable('getPaymentRequestStatus').call<Map<String, dynamic>>({
      'requestId': requestId,
      'statusToken': statusToken,
    });
    final raw = result.data['request'];
    if (raw is! Map) return null;
    final request = Map<String, dynamic>.from(raw);
    return RenewalRequestState(
      requestId: (request['requestId'] ?? requestId).toString(),
      status: (request['status'] ?? '').toString(),
      createdAt: _toInt(request['createdAt']) ?? 0,
      rejectionReason: (request['rejectionReason'] ?? '').toString(),
      selectedPlan: (request['selectedPlan'] ?? '').toString(),
    );
  }

  static Future<RenewalRequestState?> findLatestRenewalRequestForAccount({
    required String uid,
    required String email,
  }) => _getRenewalRequestStatus(uid.trim());

  static Stream<RenewalRequestState?> watchLatestRenewalRequestForAccount({
    required String uid,
    required String email,
  }) async* {
    while (true) {
      yield await _getRenewalRequestStatus(uid.trim());
      await Future<void>.delayed(const Duration(seconds: 5));
    }
  }

  static Stream<List<PaymentRequestRecord>> watchRequests({String? status}) async* {
    while (true) {
      final result = await _functions.httpsCallable('listPaymentRequests').call<Map<String, dynamic>>({
        'status': status ?? 'pending',
      });
      final rawRequests = result.data['requests'];
      final records = rawRequests is List
          ? rawRequests.whereType<Map>().map((raw) => PaymentRequestRecord.fromMap(
                Map<String, dynamic>.from(raw),
              )).toList()
          : <PaymentRequestRecord>[];
      yield records;
      await Future<void>.delayed(const Duration(seconds: 5));
    }
  }

  static Stream<List<PaymentRequestRecord>> watchPendingRequests() =>
      watchRequests(status: 'pending');

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
    final result = await _functions.httpsCallable('createPaymentRequest').call<Map<String, dynamic>>({
      'uid': uid,
      'email': email.trim().toLowerCase(),
      'agentName': agentName,
      'phone': phone,
      'governorate': governorate,
      'region': region,
      'address': address,
      'selectedPlan': PaymentPlanCatalog.normalize(selectedPlan),
      'amount': amount,
      'paymentMethod': paymentMethod,
      'transferNumber': transferNumber,
      'password': password,
      'isRenewal': isRenewal,
      'renewalForUid': renewalForUid,
    });
    final requestId = (result.data['requestId'] ?? '').toString();
    if (requestId.isEmpty) throw StateError('Backend did not return requestId');
    final receiptToken = (result.data['receiptToken'] ?? '').toString();
    final statusToken = (result.data['statusToken'] ?? '').toString();
    if (receiptToken.isNotEmpty && statusToken.isNotEmpty) {
      await _saveRequestCapabilities(
        ownerKey: uid.trim().isNotEmpty ? uid.trim() : email.trim().toLowerCase(),
        requestId: requestId,
        receiptToken: receiptToken,
        statusToken: statusToken,
      );
    }
    return requestId;
  }

  static Future<String?> uploadReceiptImage({required String requestId, required XFile file}) async {
    final bytes = await file.readAsBytes();
    final preferences = await SharedPreferences.getInstance();
    final token = preferences.getString(_requestTokenKey('receipt', requestId)) ?? '';
    if (token.isEmpty) throw StateError('Receipt upload capability is missing or expired');
    final extension = file.name.split('.').last.toLowerCase();
    final contentType = switch (extension) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'pdf' => 'application/pdf',
      _ => 'image/jpeg',
    };
    final result = await _functions.httpsCallable('uploadPaymentReceipt').call<Map<String, dynamic>>({
      'requestId': requestId,
      'receiptToken': token,
      'contentType': contentType,
      'base64': base64Encode(bytes),
    });
    return result.data['receiptImage']?.toString();
  }

  static Future<void> markRequestAsPendingReview({
    required String requestId,
    required Map<String, dynamic> patch,
  }) async {
    final result = await _functions.httpsCallable('getPaymentRequestStatus').call<Map<String, dynamic>>({
      'requestId': requestId,
      'statusToken': patch['statusToken'] ?? '',
    });
    if (result.data['request'] is Map) {
      return;
    }
  }

  static Future<void> addHistoryEntry(String requestId, Map<String, dynamic> history) async {
    return;
  }

  static Future<Map<String, dynamic>> approveRequest({
    required PaymentRequestRecord request,
    required String approvedBy,
  }) async {
    final result = await _functions.httpsCallable('approvePaymentRequest').call<Map<String, dynamic>>({
      'requestId': request.requestId,
      'approvedBy': approvedBy,
    });
    final data = result.data;
    return Map<String, dynamic>.from(data);
  }

  static Future<void> rejectRequest({
    required PaymentRequestRecord request,
    required String rejectedBy,
    required String rejectReason,
  }) async {
    await _functions.httpsCallable('rejectPaymentRequest').call<Map<String, dynamic>>({
      'requestId': request.requestId,
      'rejectedBy': rejectedBy,
      'rejectReason': rejectReason,
    });
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
