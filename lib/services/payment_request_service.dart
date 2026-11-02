import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
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

  static const List<String> paidPlans = <String>[
    threeMonths,
    sixMonths,
    oneYear,
  ];

  /// يحدده المدير، ويقرؤه التسجيل قبل تسجيل الدخول فهو عام القراءة.
  static const String pricesPath = 'publicConfig/planPrices';

  static const String paymentAccountPath = 'publicConfig/paymentAccount';

  static final Map<String, String> _prices = <String, String>{};
  static String accountNumber = '';
  static String cardNumber = '';

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

  /// فارغ إذا لم يحدد المدير سعر الباقة بعد.
  static String amount(String value) {
    final plan = normalize(value);
    return plan == free15Days ? 'مجاني' : _prices[plan] ?? '';
  }

  /// الصيغة المحفوظة: أرقام لاتينية دون فواصل، أو null إذا لم يكن سعراً صحيحاً.
  static String? normalizePrice(String raw) {
    var digits = raw.replaceAll(RegExp(r'[\s,٬]'), '');
    const arabicDigits = '٠١٢٣٤٥٦٧٨٩';
    for (var digit = 0; digit < arabicDigits.length; digit++) {
      digits = digits.replaceAll(arabicDigits[digit], '$digit');
    }
    return RegExp(r'^[1-9][0-9]*$').hasMatch(digits) ? digits : null;
  }

  static void applyPrices(dynamic raw) {
    _prices.clear();
    if (raw is! Map) return;
    for (final plan in paidPlans) {
      final price = normalizePrice((raw[plan] ?? '').toString());
      if (price != null) _prices[plan] = price;
    }
  }

  static void applyPaymentAccount(dynamic raw) {
    final account = raw is Map ? raw : const {};
    accountNumber = (account['accountNumber'] ?? '').toString().trim();
    cardNumber = (account['cardNumber'] ?? '').toString().trim();
  }

  static Future<void> loadPrices() async {
    final database = FirebaseDatabase.instance;
    final snapshots = await Future.wait([
      database.ref(pricesPath).get(),
      database.ref(paymentAccountPath).get(),
    ]);
    applyPrices(snapshots[0].value);
    applyPaymentAccount(snapshots[1].value);
  }

  static void _requireAdmin() {
    final user = FirebaseAuth.instance.currentUser;
    if (user?.uid != SubscriptionRequestService.trustedAdminUid) {
      throw StateError('هذه العملية للمدير فقط');
    }
  }

  static Future<void> savePrices(Map<String, String> prices) async {
    _requireAdmin();
    await FirebaseDatabase.instance.ref(pricesPath).update(prices);
    applyPrices(prices);
  }

  static Future<void> savePaymentAccount(Map<String, String> account) async {
    _requireAdmin();
    await FirebaseDatabase.instance.ref(paymentAccountPath).update(account);
    applyPaymentAccount(account);
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

  bool get isPending =>
      status == SubscriptionRequestService.pendingStatus ||
      status == SubscriptionRequestService.reviewingStatus;
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';

  int get sortTs => reviewedAt ?? createdAt;
}

class OpenRequest {
  const OpenRequest({required this.requestId, required this.hasReceipt});

  final String requestId;
  final bool hasReceipt;
}

class PaymentRequestService {
  /// الخطة المجانية في Firebase بلا مخزن ملفات، فرقم التحويل هو إثبات الدفع.
  /// فعّلها بعد تفعيل Storage وقواعده.
  static const bool receiptUploadsEnabled = false;

  static const String _requestsPath =
      'admin/${SubscriptionRequestService.collectionName}';

  static DatabaseReference get _root => FirebaseDatabase.instance.ref();

  /// الطلب الذي ما زال بانتظار الإدارة، ما دام الحساب لا يحتاج طلباً ثانياً.
  static Future<OpenRequest?> findOpenRequest(String uid) async {
    final snapshot = await _requestsForUid(uid).get();
    return openRequestIn(snapshot.value, uid);
  }

  static OpenRequest? openRequestIn(Object? value, String uid) {
    if (value is! Map) return null;
    for (final entry in value.entries) {
      if (entry.value is! Map) continue;
      final request = Map<String, dynamic>.from(entry.value as Map);
      final status = request['status'];
      if (request['uid'] != uid ||
          (status != SubscriptionRequestService.pendingStatus &&
              status != SubscriptionRequestService.reviewingStatus)) {
        continue;
      }
      return OpenRequest(
        requestId: entry.key.toString(),
        hasReceipt: (request['receiptImageUrl'] ?? '')
            .toString()
            .trim()
            .isNotEmpty,
      );
    }
    return null;
  }

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

  static int? _intValue(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static RenewalRequestState _renewalState(
    String requestId,
    Map<String, dynamic> request,
  ) {
    return RenewalRequestState(
      requestId: (request['requestId'] ?? requestId).toString(),
      status: (request['status'] ?? '').toString(),
      createdAt: _intValue(request['createdAt']) ?? 0,
      rejectionReason:
          (request['rejectionReason'] ?? request['rejectReason'] ?? '')
              .toString(),
      reviewedAt: _intValue(request['reviewedAt']),
      selectedPlan: (request['selectedPlan'] ?? '').toString(),
    );
  }

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
    if (user == null) throw StateError('سجّل الدخول قبل إرسال الطلب');
    if (user.uid == SubscriptionRequestService.trustedAdminUid) {
      throw StateError('لا يرسل حساب المدير طلب اشتراك');
    }
    if (uid.trim().isNotEmpty && uid.trim() != user.uid) {
      throw StateError('يمكن إرسال الطلب للحساب المسجل فقط');
    }
    if (isRenewal && renewalForUid.trim() != user.uid) {
      throw StateError('يمكن تجديد الحساب المسجل فقط');
    }

    final normalizedPlan = PaymentPlanCatalog.normalize(selectedPlan);
    if (!PaymentPlanCatalog.supportedPlans.contains(normalizedPlan)) {
      throw ArgumentError.value(
        selectedPlan,
        'selectedPlan',
        'Unsupported subscription plan.',
      );
    }
    // قد يغيّر المدير السعر بعد فتح شاشة الباقات.
    await PaymentPlanCatalog.loadPrices();
    final expectedAmount = PaymentPlanCatalog.amount(normalizedPlan);
    if (expectedAmount.isEmpty || amount.trim() != expectedAmount) {
      throw StateError('تغيّر سعر الباقة، ارجع واختر الباقة من جديد');
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

  static Future<void> activateFreeTrial({
    required String agentName,
    required String phone,
  }) => SubscriptionRequestService.activateFreeTrial(
    agentName: agentName,
    phone: phone,
    amount: PaymentPlanCatalog.amount(PaymentPlanCatalog.free15Days),
  );

  static Future<String?> uploadReceiptImage({
    required String requestId,
    required XFile file,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('سجّل الدخول قبل رفع الوصل');
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

  /// يعيد false إذا بقي الطلب بلا وصل، ليعرف الوكيل ذلك ويعيد المحاولة.
  static Future<bool> attachReceipt({
    required String requestId,
    required XFile file,
  }) async {
    try {
      final imageUrl = await uploadReceiptImage(
        requestId: requestId,
        file: file,
      ).timeout(const Duration(seconds: 30));
      if ((imageUrl ?? '').isEmpty) return false;
      await markRequestAsPendingReview(
        requestId: requestId,
        patch: {'receiptImageUrl': imageUrl},
      ).timeout(const Duration(seconds: 15));
      return true;
    } catch (e) {
      debugPrint('Receipt upload/update failed for request $requestId: $e');
      return false;
    }
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

  static Future<void> changeRequestPlan({
    required String requestId,
    required String plan,
    String collectionPath = SubscriptionRequestService.collectionName,
  }) async {
    await PaymentPlanCatalog.loadPrices();
    final amount = PaymentPlanCatalog.amount(plan);
    if (amount.isEmpty) {
      throw StateError('حدد سعر هذه الباقة أولاً من "الأسعار وبيانات الدفع"');
    }
    await SubscriptionRequestService.changeRequestPlan(
      requestId: requestId,
      plan: plan,
      amount: amount,
      collectionPath: collectionPath,
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
