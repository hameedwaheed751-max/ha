import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:image_picker/image_picker.dart';

DateTime? _parseDateTime(dynamic value) {
  if (value is Timestamp) return value.toDate();
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(value);
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
  final DateTime? createdAt;
  final DateTime? reviewedAt;

  Map<String, dynamic> toFirestore() => {
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
        'createdAt': createdAt?.toUtc().toIso8601String() ?? DateTime.now().toUtc().toIso8601String(),
        'reviewedAt': reviewedAt?.toUtc().toIso8601String(),
      };

  factory SubscriptionRequestModel.fromFirestore(DocumentSnapshot<Map<String, dynamic>> snap) {
    final data = snap.data() ?? <String, dynamic>{};
    return SubscriptionRequestModel(
      requestId: (data['requestId'] ?? snap.id).toString(),
      uid: (data['uid'] ?? '').toString(),
      firstName: (data['firstName'] ?? '').toString(),
      lastName: (data['lastName'] ?? '').toString(),
      phone: (data['phone'] ?? '').toString(),
      email: (data['email'] ?? '').toString(),
      selectedPlan: (data['selectedPlan'] ?? '').toString(),
      amount: (data['amount'] ?? '').toString(),
      paymentMethod: (data['paymentMethod'] ?? 'Qi Card').toString(),
      transferNumber: (data['transferNumber'] ?? '').toString(),
      receiptImageUrl: (data['receiptImageUrl'] ?? '').toString(),
      status: (data['status'] ?? 'pending').toString(),
      password: (data['password'] ?? '').toString(),
      rejectionReason: (data['rejectionReason'] ?? '').toString(),
      createdAt: _parseDateTime(data['createdAt']),
      reviewedAt: _parseDateTime(data['reviewedAt']),
    );
  }
}

class SubscriptionRequestService {
  static const String collectionName = 'subscription_requests';
  static const String pendingStatus = 'pending';
  static const String approvedStatus = 'approved';
  static const String rejectedStatus = 'rejected';

  static String planLabel(String value) {
    switch (value) {
      case 'trial':
        return 'تجريبي 15 يوم';
      case '3m':
        return '3 أشهر';
      case '6m':
        return '6 أشهر';
      case '1y':
        return 'سنة';
      default:
        return 'تجريبي 15 يوم';
    }
  }

  static String planPrice(String value) {
    switch (value) {
      case 'trial':
        return 'مجاني';
      case '3m':
        return '40000';
      case '6m':
        return '50000';
      case '1y':
        return '70000';
      default:
        return 'مجاني';
    }
  }

  static String planLabelFor(String? value) => planLabel(value ?? 'trial');

  static bool isTrialPlan(String plan) => plan == 'trial';

  static DateTime startDateForPlan({DateTime? now}) => now ?? DateTime.now();

  static DateTime endDateForPlan(String plan, {DateTime? from}) {
    final start = from ?? DateTime.now();
    switch (plan) {
      case 'trial':
        return start.add(const Duration(days: 15));
      case '3m':
        return start.add(const Duration(days: 90));
      case '6m':
        return start.add(const Duration(days: 183));
      case '1y':
        return start.add(const Duration(days: 365));
      default:
        return start.add(const Duration(days: 15));
    }
  }

  static Stream<List<SubscriptionRequestModel>> watchRequests({String? status}) {
    Query<Map<String, dynamic>> query = FirebaseFirestore.instance
        .collection(collectionName)
        .orderBy('createdAt', descending: true);

    if (status != null && status.isNotEmpty) {
      query = query.where('status', isEqualTo: status);
    }

    return query.snapshots().map((snapshot) => snapshot.docs
        .map((doc) => SubscriptionRequestModel.fromFirestore(doc as DocumentSnapshot<Map<String, dynamic>>))
        .toList());
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
    final docRef = FirebaseFirestore.instance.collection(collectionName).doc();
    final model = SubscriptionRequestModel(
      requestId: docRef.id,
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

    await docRef.set(model.toFirestore());
    return docRef.id;
  }

  static Future<String?> uploadReceiptImage({required String requestId, required XFile file}) async {
    final storageRef = FirebaseStorage.instance.ref('subscription_requests/$requestId/${file.name}');
    final bytes = await file.readAsBytes();
    final task = await storageRef.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
    return task.ref.getDownloadURL();
  }

  static Future<void> rejectRequest({required String requestId, String? reason}) async {
    await FirebaseFirestore.instance.collection(collectionName).doc(requestId).update({
      'status': rejectedStatus,
      'rejectionReason': reason ?? '',
      'reviewedAt': DateTime.now().toUtc().toIso8601String(),
    });
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
      createdAt: _parseDateTime(requestData['createdAt']),
      reviewedAt: _parseDateTime(requestData['reviewedAt']),
    );
    await approveRequest(request: request);
  }

  static Future<void> approveRequest({required SubscriptionRequestModel request}) async {
    final firestore = FirebaseFirestore.instance;
    final requestRef = firestore.collection(collectionName).doc(request.requestId);

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
      await requestRef.update({
        'uid': uid,
        'status': approvedStatus,
        'reviewedAt': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      await requestRef.update({
        'status': rejectedStatus,
        'rejectionReason': 'فشل في إنشاء الحساب: $e',
        'reviewedAt': DateTime.now().toUtc().toIso8601String(),
      });
      rethrow;
    }
  }
}
