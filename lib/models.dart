import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';

class PaymentRecord {
  PaymentRecord({required this.amount, required this.at, this.note = ''});
  double amount;
  DateTime at;
  String note;

  Map<String, dynamic> toJson() => {
    'amount': amount,
    'at': at.toIso8601String(),
    'note': note,
  };

  factory PaymentRecord.fromJson(Map<String, dynamic> j) => PaymentRecord(
    amount: (j['amount'] ?? 0).toDouble(),
    at: DateTime.tryParse((j['at'] ?? '').toString()) ?? DateTime.now(),
    note: (j['note'] ?? '').toString(),
  );
}

class InvoiceRecord {
  InvoiceRecord({
    required this.receiptNumber,
    required this.amount,
    required this.at,
    required this.monthKey,
    this.note = '',
  });

  int receiptNumber;
  double amount;
  DateTime at;
  String monthKey;
  String note;

  Map<String, dynamic> toJson() => {
        'receiptNumber': receiptNumber,
        'amount': amount,
        'at': at.toIso8601String(),
        'monthKey': monthKey,
        'note': note,
      };

  factory InvoiceRecord.fromJson(Map<String, dynamic> j) => InvoiceRecord(
        receiptNumber: int.tryParse((j['receiptNumber'] ?? '').toString()) ?? 0,
        amount: (j['amount'] ?? 0).toDouble(),
        at: DateTime.tryParse((j['at'] ?? '').toString()) ?? DateTime.now(),
        monthKey: (j['monthKey'] ?? '').toString().trim(),
        note: (j['note'] ?? '').toString(),
      );
}

class DailyTaskEvent {
  DailyTaskEvent({
    required this.type,
    required this.subscriberUser,
    required this.subscriberName,
    required this.at,
    this.amount = 0,
    this.remainingAfter = 0,
    this.note = '',
  });

  String type;
  String subscriberUser;
  String subscriberName;
  DateTime at;
  double amount;
  double remainingAfter;
  String note;

  Map<String, dynamic> toJson() => {
        'type': type,
        'subscriberUser': subscriberUser,
        'subscriberName': subscriberName,
        'at': at.toIso8601String(),
        'amount': amount,
        'remainingAfter': remainingAfter,
        'note': note,
      };

  factory DailyTaskEvent.fromJson(Map<String, dynamic> j) => DailyTaskEvent(
        type: (j['type'] ?? '').toString(),
        subscriberUser: (j['subscriberUser'] ?? '').toString(),
        subscriberName: (j['subscriberName'] ?? '').toString(),
        at: DateTime.tryParse((j['at'] ?? '').toString()) ?? DateTime.now(),
        amount: (j['amount'] ?? 0).toDouble(),
        remainingAfter: (j['remainingAfter'] ?? 0).toDouble(),
        note: (j['note'] ?? '').toString(),
      );
}

class Subscriber {
  Subscriber({
    required this.user,
    required this.name,
    required this.phone,
    required this.address,
    required this.ip,
    required this.type,
    required this.price,
    required this.startDate,
    required this.endDate,
    this.notes = '',
    this.active = true,
    this.disabled = false,
    this.paid = 0,
    this.paymentDate = '',
    this.points = 0,
    this.source = 'local',
    this.sasId = '',
    this.sasOnline = false,
    Map<String, dynamic>? sasData,
    List<PaymentRecord>? payments,
     List<InvoiceRecord>? invoices,
  }) : payments = payments ?? <PaymentRecord>[],
       invoices = invoices ?? <InvoiceRecord>[],
       sasData = sasData ?? <String, dynamic>{};

  String user;
  String name;
  String phone;
  String address;
  String ip;
  String type;
  String notes;
  String paymentDate;
  double price;
  double paid;
  DateTime startDate;
  DateTime endDate;
  bool active;
  bool disabled;
  int points;
  String source;
  String sasId;
  bool sasOnline;
  Map<String, dynamic> sasData;
  List<PaymentRecord> payments;
  List<InvoiceRecord> invoices;

    double get paymentsTotal =>
      payments.fold<double>(0, (sum, p) => sum + p.amount);

    double get invoicesTotal =>
      invoices.fold<double>(0, (sum, inv) => sum + inv.amount);

  double get remaining => (price - paid).clamp(0, double.infinity).toDouble();
  bool get expired => endDate.isBefore(DateTime.now());
  bool get isActive => active && !disabled && !expired;
  bool get isOnline => sasOnline || _detectOnline(sasData);

  void markActivationDate({DateTime? at}) {
    final activationDay = DateTime(at?.year ?? DateTime.now().year, at?.month ?? DateTime.now().month, at?.day ?? DateTime.now().day);
    startDate = activationDay;
    final marker = activationDay.toIso8601String();
    sasData['local_activation_date'] = marker;
    sasData['activation_date'] = marker;
  }

  void normalizeDebtFields() {
    if (!price.isFinite || price < 0) {
      price = 0;
    }
    if (!paid.isFinite || paid < 0) {
      paid = 0;
    }
    if (paid > price) {
      paid = price;
    }
    if (paid <= 0) {
      paymentDate = '';
    }
  }

  static double resolveDebtTargetPaid({
    required double price,
    required double currentPaid,
    required double partialAmount,
    double? directTargetPaid,
  }) {
    final safePrice = price.isFinite ? price : 0;
    final safeCurrentPaid = currentPaid.isFinite ? currentPaid : 0;
    final safePartialAmount = partialAmount.isFinite ? partialAmount : 0;

    if (directTargetPaid != null && directTargetPaid.isFinite) {
      return directTargetPaid.clamp(0, safePrice).toDouble();
    }

    if (safePartialAmount <= 0) {
      return safeCurrentPaid.clamp(0, safePrice).toDouble();
    }

    final tentative = safeCurrentPaid - safePartialAmount;
    return tentative.clamp(0, safePrice).toDouble();
  }

  void setDebtAmounts({
    required double subscriptionAmount,
    required double paidAmount,
  }) {
    price = subscriptionAmount;
    paid = paidAmount;
    normalizeDebtFields();
  }

  void _backfillLegacyPaidToPayments({DateTime? at}) {
    // Legacy subscribers may have `paid` without payment rows.
    if (payments.isEmpty && paid > 0.0001) {
      payments.add(
        PaymentRecord(
          amount: paid,
          at: at ?? DateTime.now(),
          note: 'رصيد واصل سابق',
        ),
      );
    }
  }

  void reconcilePaidFromPayments() {
    if (payments.isEmpty) {
      normalizeDebtFields();
      return;
    }

    final total = paymentsTotal;
    paid = total;
    normalizeDebtFields();
  }

  double adjustPaidToTarget(
    double targetPaid, {
    DateTime? at,
    String? increaseNote,
    String? decreaseNote,
  }) {
    normalizeDebtFields();
    _backfillLegacyPaidToPayments(at: at);
    // Always derive from ledger truth before applying any delta.
    reconcilePaidFromPayments();
    if (!targetPaid.isFinite) return 0;

    final boundedTarget = targetPaid.clamp(0, price).toDouble();
    final delta = boundedTarget - paid;
    if (delta.abs() <= 0.0001) return 0;

    final stamp = at ?? DateTime.now();
    paid = boundedTarget;

    payments.add(
      PaymentRecord(
        amount: delta,
        at: stamp,
        note: delta >= 0
            ? (increaseNote ?? 'تعديل الواصل من شاشة الديون')
            : (decreaseNote ?? 'تصحيح تخفيض الواصل من شاشة الديون'),
      ),
    );

    normalizeDebtFields();
    return delta;
  }

  double applyPartialPayment(double amount, {DateTime? at, String? note}) {
    normalizeDebtFields();
    _backfillLegacyPaidToPayments(at: at);
    // Keep `paid` aligned with payment ledger before adding a new payment.
    reconcilePaidFromPayments();
    if (!amount.isFinite || amount <= 0) return 0;

    final applied = amount > remaining ? remaining : amount;
    if (applied <= 0) return 0;

    paid += applied;
    final stamp = at ?? DateTime.now();
    payments.add(PaymentRecord(
      amount: applied,
      at: stamp,
      note: note ?? (remaining <= 0.0001 ? 'تسديد كامل' : 'تسديد جزئي'),
    ));
    return applied;
  }

  static String monthKeyOf(DateTime date) {
    final m = date.month.toString().padLeft(2, '0');
    return '${date.year}-$m';
  }

  InvoiceRecord? registerInvoiceFromPayment({
    required int receiptNumber,
    required double amount,
    DateTime? at,
    String note = '',
  }) {
    if (receiptNumber <= 0 || amount <= 0 || !amount.isFinite) return null;
    final stamp = at ?? DateTime.now();
    final invoice = InvoiceRecord(
      receiptNumber: receiptNumber,
      amount: amount,
      at: stamp,
      monthKey: monthKeyOf(stamp),
      note: note,
    );
    invoices.add(invoice);
    return invoice;
  }

  Map<String, double> get monthlyPaidTotals {
    final out = <String, double>{};
    for (final p in payments) {
      final key = monthKeyOf(p.at);
      out[key] = (out[key] ?? 0) + p.amount;
    }
    return out;
  }

  Map<String, double> get monthlyInvoiceTotals {
    final out = <String, double>{};
    for (final inv in invoices) {
      final key = inv.monthKey.isNotEmpty ? inv.monthKey : monthKeyOf(inv.at);
      out[key] = (out[key] ?? 0) + inv.amount;
    }
    return out;
  }

  String get packageDisplay {
    dynamic findInTree(dynamic node) {
      if (node is Map) {
        for (final key in const ['profile_name', 'profile', 'package_name', 'package', 'plan_name', 'service_name']) {
          final value = node[key];
          if (value is String || value is num || value is bool) {
            final text = value.toString().trim();
            if (text.isNotEmpty) return text;
          } else if (value is Map || value is List) {
            final nested = findInTree(value);
            if (nested is String && nested.trim().isNotEmpty) return nested;
          }
        }
        for (final value in node.values) {
          final found = findInTree(value);
          if (found is String && found.trim().isNotEmpty) return found;
        }
      } else if (node is List) {
        for (final item in node) {
          final found = findInTree(item);
          if (found is String && found.trim().isNotEmpty) return found;
        }
      }
      return null;
    }

    final found = findInTree(sasData);
    if (found is String && found.trim().isNotEmpty) return found.trim();
    return type.trim().isEmpty ? '—' : type.trim();
  }

  void setPackageValue(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return;

    type = normalized;
    sasData['profile_name'] = normalized;
    sasData['package_name'] = normalized;
    sasData['package'] = normalized;
    sasData['profile'] = normalized;
  }

  void refreshOnlineState() {
    sasOnline = _detectOnline(sasData);
  }

  static bool _detectOnline(dynamic node) {
    bool truthy(dynamic v) {
      if (v == true || v == 1) return true;
      final z = (v ?? '').toString().toLowerCase().trim();
      return const ['1', 'true', 'yes', 'online', 'connected', 'active', 'up', 'on', 'متصل']
          .contains(z);
    }

    bool check(dynamic value) {
      if (value is Map) {
        for (final key in const [
          'online', 'is_online', 'isOnline', 'connected', 'is_connected', 'isConnected',
          'user_online', 'status_online', 'online_status', 'connection_status', 'acct_status_type',
          'session_status', 'logged_in', 'loggedIn'
        ]) {
          if (value.containsKey(key) && truthy(value[key])) return true;
        }
        for (final v in value.values) {
          if (check(v)) return true;
        }
      } else if (value is List) {
        for (final item in value) {
          if (check(item)) return true;
        }
      }
      return false;
    }

    try {
      return check(node);
    } catch (_) {
      return false;
    }
  }

  static bool detectOnline(dynamic node) => _detectOnline(node);

  Map<String, dynamic> toJson() => {
        'user': user,
        'name': name,
        'phone': phone,
        'address': address,
        'ip': ip,
        'type': type,
        'price': price,
        'startDate': startDate.toIso8601String(),
        'endDate': endDate.toIso8601String(),
        'notes': notes,
        'active': active,
        'disabled': disabled,
        'paid': paid,
        'paymentDate': paymentDate,
        'points': points,
        'source': source,
        'sasId': sasId,
        'sasOnline': sasOnline,
        'sasData': sasData,
        'payments': payments.map((e) => e.toJson()).toList(),
        'invoices': invoices.map((e) => e.toJson()).toList(),
      };

  factory Subscriber.fromJson(Map<String, dynamic> j) {
    final sasData = j['sasData'] is Map ? Map<String, dynamic>.from(j['sasData']) : <String, dynamic>{};
    final fallbackType = (j['type'] ?? '').toString().trim();
    final packageFromSas = _extractPackageValue(sasData, fallbackType);
    debugPrint('Subscriber.fromJson profile_name=${sasData['profile_name'] ?? ''}, type=$packageFromSas');

    final subscriber = Subscriber(
        user: j['user'] ?? '',
        name: j['name'] ?? '',
        phone: j['phone'] ?? '',
        address: j['address'] ?? '',
        ip: j['ip'] ?? '',
        type: packageFromSas,
        price: (j['price'] ?? 0).toDouble(),
        startDate: DateTime.tryParse(j['startDate'] ?? '') ?? DateTime.now(),
        endDate: DateTime.tryParse(j['endDate'] ?? '') ?? DateTime.now(),
        notes: j['notes'] ?? '',
        active: j['active'] ?? true,
        disabled: j['disabled'] ?? false,
        paid: (j['paid'] ?? 0).toDouble(),
        paymentDate: j['paymentDate'] ?? '',
        points: j['points'] ?? 0,
        source: j['source'] ?? 'local',
        sasId: (j['sasId'] ?? '').toString(),
        sasOnline: j['sasOnline'] == true || _detectOnline(sasData),
        sasData: sasData,
        payments: j['payments'] is List ? (j['payments'] as List).map((e) => PaymentRecord.fromJson(Map<String, dynamic>.from(e))).toList() : <PaymentRecord>[],
        invoices: j['invoices'] is List ? (j['invoices'] as List).map((e) => InvoiceRecord.fromJson(Map<String, dynamic>.from(e))).toList() : <InvoiceRecord>[],
      );
        subscriber.reconcilePaidFromPayments();
      return subscriber;
  }

  static String _extractPackageValue(Map<String, dynamic> sasData, String fallback) {
    dynamic findInTree(dynamic node) {
      if (node is Map) {
        for (final key in const ['profile_name', 'profile', 'package_name', 'package', 'plan_name', 'service_name']) {
          final value = node[key];
          if (value is String || value is num || value is bool) {
            final text = value.toString().trim();
            if (text.isNotEmpty) return text;
          } else if (value is Map || value is List) {
            final nested = findInTree(value);
            if (nested is String && nested.trim().isNotEmpty) return nested;
          }
        }
        for (final value in node.values) {
          final found = findInTree(value);
          if (found is String && found.trim().isNotEmpty) return found;
        }
      } else if (node is List) {
        for (final item in node) {
          final found = findInTree(item);
          if (found is String && found.trim().isNotEmpty) return found;
        }
      }
      return null;
    }

    final found = findInTree(sasData);
    return (found is String && found.trim().isNotEmpty) ? found.trim() : fallback;
  }
}

class PackagePlan {
  PackagePlan({required this.name, required this.price});
  String name; double price;
  Map<String,dynamic> toJson()=>{'name':name,'price':price};
  factory PackagePlan.fromJson(Map<String,dynamic> j)=>PackagePlan(name:j['name']??'',price:(j['price']??0).toDouble());
}

extension PackagePlanListX on List<PackagePlan> {
  void applyPayload(dynamic payload) {
    final parsed = <PackagePlan>[];

    void addFromMap(Map<String, dynamic> map) {
      final name = (map['name'] ?? '').toString().trim();
      if (name.isEmpty) return;
      parsed.add(PackagePlan(
        name: name,
        price: (map['price'] ?? 0).toDouble(),
      ));
    }

    if (payload is List) {
      for (final item in payload) {
        if (item is Map) {
          addFromMap(Map<String, dynamic>.from(item));
        } else if (item is String && item.trim().isNotEmpty) {
          final decoded = jsonDecode(item);
          if (decoded is Map) addFromMap(Map<String, dynamic>.from(decoded));
        }
      }
    } else if (payload is Map) {
      for (final entry in payload.entries) {
        if (entry.value is Map) {
          addFromMap(Map<String, dynamic>.from(entry.value as Map));
        }
      }
    } else if (payload is String && payload.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(payload);
        if (decoded is List || decoded is Map) {
          applyPayload(decoded);
        }
      } catch (_) {}
    }

    if (parsed.isNotEmpty) {
      clear();
      addAll(parsed);
    }
  }
}

class AppStore {
  static const int dataVersion = 1;
  static const String subscribersRevisionKey = 'subscribersRevision';
  static const String packagesRevisionKey = 'packagesRevision';
  static const String dailyTaskEventsKey = 'dailyTaskEvents';
  static const String subscriptionNodeKey = 'subscription';
  static String? _loadedUid;
    static const String activationTemplate =
      'مرحباً {{customer_name}}،\n✅ تم تفعيل اشتراك الإنترنت بنجاح.\n📦 الباقة: {{package_name}}\n💰 المبلغ الواصل: {{paid_amount}} دينار عراقي\n💰 المبلغ المتبقي: {{remaining_amount}} دينار عراقي\n📅 يبدأ الاشتراك: {{subscription_start}}\n📅 ينتهي الاشتراك: {{subscription_end}}\nللاستفسار يرجى التواصل مع:\n🏢 {{agent_name}}\n📱 {{whatsapp_number}}\n\nشكراً لاختياركم خدمتنا.';
      static const String debtPaidTemplate =
        'مرحباً {{customer_name}}،\n✅ تم استلام مبلغ الدين المترتب بذمتكم.\n💰 المبلغ الواصل: {{paid_amount}} دينار عراقي\n💰 المتبقي: {{remaining_amount}} دينار عراقي\nنشكر لكم التزامكم بالسداد.\nللاستفسار يرجى التواصل مع:\n🏢 {{agent_name}}\n📱 {{whatsapp_number}}\n\nشكراً لاختياركم خدمتنا.';
        static const String debtTemplate =
          'مرحبا {{customer_name}}\nتم تسجيل مبلغ دين جديد على حسابك\nالمبلغ الواصل: {{paid_amount}} دينار عراقي\nالمبلغ المتبقي: {{remaining_amount}} دينار عراقي\nللاستفسار يرجى التواصل مع:\n{{agent_name}}\n{{whatsapp_number}}';
  static const String nearExpiryTemplate =
      'مرحباً {{customer_name}}،\n⏳ نود إعلامكم بأن اشتراك الإنترنت سينتهي قريباً.\n📦 الباقة: {{package_name}}\n📅 تاريخ الانتهاء: {{subscription_end}}\nلضمان استمرار الخدمة دون انقطاع، يرجى مراجعة:\n🏢 {{agent_name}}\n📱 {{whatsapp_number}}\n\nشكراً لاختياركم خدمتنا.';
  static final List<Subscriber> subscribers = [];
  static final List<DailyTaskEvent> dailyTaskEvents = [];
  static String agentFirstName = '';
  static String agentLastName = '';
  static String agentName = '';
  static String agentEmail = '';

  static String get effectiveAgentName {
    final names = [agentFirstName, agentLastName].where((e) => e.trim().isNotEmpty).toList();
    final derived = names.join(' ').trim();
    if (agentName.trim().isNotEmpty) return agentName.trim();
    if (derived.isNotEmpty) return derived;
    return officeName.trim();
  }

  static String subscriptionPlanLabelFor(String plan) {
    switch (plan.trim()) {
      case 'free_15_days':
      case 'trial':
        return 'مجاني 15 يوم';
      case 'three_months':
      case '3m':
        return 'ثلاثة أشهر';
      case 'six_months':
      case '6m':
        return 'ستة أشهر';
      case 'one_year':
      case '1y':
        return 'سنة';
      case 'free':
      default:
        return 'مجاني';
    }
  }

  static int subscriptionDurationDaysFor(String plan) {
    switch (plan.trim()) {
      case 'free_15_days':
      case 'trial':
        return 15;
      case 'three_months':
      case '3m':
        return 90;
      case 'six_months':
      case '6m':
        return 183;
      case 'one_year':
      case '1y':
        return 365;
      case 'free':
      default:
        return 0;
    }
  }

  static String officeName = '';
  static String officePhone = '';
  static String officeAddress = '';
  static String officeLogoBase64 = '';
  static String receiptFooter = '';
  static String sasUsername = '';
  static String subscriptionPlan = '';
  static String subscriptionPlanLabel = '';
  static int subscriptionDurationDays = 0;
  static String subscriptionPrice = '';
  static String paymentMethod = 'master';
  static bool subscriptionAutoExpire = true;
  static String subscriptionLastPaymentId = '';
  static DateTime? subscriptionStartedAt;
  static DateTime? subscriptionEndsAt;
  static String subscriptionStatus = 'inactive';
  static double balance = 0;
  static int nextReceiptNumber = 1;
  static DateTime? lastSasSync;
  static int subscribersRevision = 0;
  static int packagesRevision = 0;
  static final List<PackagePlan> packages = [];

  static void addPackage(PackagePlan package) {
    final normalizedName = package.name.trim();
    if (normalizedName.isEmpty) return;
    final existing = packages.indexWhere((item) => item.name.trim().toLowerCase() == normalizedName.toLowerCase());
    if (existing >= 0) {
      packages[existing].price = package.price;
      return;
    }
    packages.add(PackagePlan(name: normalizedName, price: package.price));
  }

  static void removePackage(PackagePlan package) {
    packages.removeWhere((item) => item.name.trim().toLowerCase() == package.name.trim().toLowerCase());
  }
  static final Map<String,String> messageTemplates = {
    'activation':activationTemplate,
    'extension':'مرحباً {name}، تم تمديد اشتراكك لدى {office} حتى {endDate}.',
    'nearExpiry':nearExpiryTemplate,
    'expired':'مرحباً {name}، اشتراكك لدى {office} منتهي. يرجى التجديد لاستمرار الخدمة.',
    'debt':debtTemplate,
    'debtPaid':debtPaidTemplate,
  };
  static StreamSubscription<DatabaseEvent>? realtimeListener;

  static void _migrateNearExpiryTemplate() {
    // Always normalize activation and near-expiry to the canonical wording.
    messageTemplates['nearExpiry'] = nearExpiryTemplate;
    messageTemplates['activation'] = activationTemplate;

    // Always normalize debt templates to the canonical approved wording.
    messageTemplates['debt'] = debtTemplate;
    messageTemplates['debtPaid'] = debtPaidTemplate;
  }

  /// مسار Firebase الأساسي للوكيل: agents/{uid}
  /// بحيث يبدأ كل حساب جديد بعقدة خاصة به ويُحافظ على فصل البيانات بين الحسابات.
  static DatabaseReference get _agentRef {
    final uid = _uid;
    if (uid == null || uid.isEmpty) throw Exception('User not logged in');
    return FirebaseDatabase.instance.ref('agents/$uid');
  }

  static Map<String, dynamic> buildEmptyAgentNodePayload({required String uid}) {
    final resolvedUid = uid.trim();
    return {
      'profile': {
        'email': '',
        'name': '',
        'firstName': '',
        'lastName': '',
        'admin': '',
        'company': '',
        'phone': '',
        'sasUsername': '',
        'emailKey': '',
        'agentKey': '',
        'currentAgentId': resolvedUid,
        'createdAt': ServerValue.timestamp,
        'status': 'pending_sas',
      },
      'settings': <String, dynamic>{
        subscribersRevisionKey: 0,
      },
      'packages': <String, dynamic>{},
      'subscription': <String, dynamic>{
        'plan': 'free',
        'status': 'inactive',
        'durationDays': 0,
        'startDate': null,
        'endDate': null,
        'autoExpire': true,
        'lastPaymentId': null,
      },
      'messageTemplates': <String, dynamic>{
        'activation': activationTemplate,
        'extension': 'مرحباً {name}، تم تمديد اشتراكك لدى {office} حتى {endDate}.',
        'nearExpiry': nearExpiryTemplate,
        'expired': 'مرحباً {name}، اشتراكك لدى {office} منتهي. يرجى التجديد لاستمرار الخدمة.',
        'debt': debtTemplate,
        'debtPaid': debtPaidTemplate,
      },
      'subscribers': <dynamic>[],
      'debts': <String, dynamic>{},
      'sas': <String, dynamic>{
        'serverUrl': '',
        'username': '',
        'password': '',
      },
    };
  }

  static Future<void> initializeEmptyAgentNode({String? uid}) async {
    final resolvedUid = (uid ?? _uid ?? '').trim();
    if (resolvedUid.isEmpty) return;

    final ref = FirebaseDatabase.instance.ref('agents/$resolvedUid');
    final defaults = buildEmptyAgentNodePayload(uid: resolvedUid);

    await ref.set(defaults).timeout(const Duration(seconds: 10));
  }

  static bool get _isLoggedIn {
    try {
      return FirebaseAuth.instance.currentUser != null;
    } catch (e) {
      debugPrint('FirebaseAuth unavailable, using local storage only: $e');
      return false;
    }
  }

  static String? get _uid {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      return null;
    }
  }

  /// تحميل بيانات الوكيل من Firebase
  static Future<void> _pullFromFirebase() async {
    if (!_isLoggedIn) return;
    try {
      var snapshot = await _agentRef.get().timeout(const Duration(seconds: 10));
      var data = snapshot.value;
      if (data == null || data is! Map) return;
      var agentData = Map<String, dynamic>.from(data);

      // عند بداية التطبيق قد يكون sasUsername غير محمل بعد، فيقرأ AppStore
      // المسار القديم agents/{uid}. إذا وجدنا مؤشراً إلى المسار الحالي
      // agents/{uid}_{sasUsername} نحمل منه البيانات الفعلية قبل تحميل
      // المشتركين حتى لا تفشل مزامنة SAS مع Firebase بسبب اختلاف المسار.
      final uid = _uid;
      final profileForDiscovery = agentData['profile'] is Map
          ? Map<String, dynamic>.from(agentData['profile'])
          : <String, dynamic>{};
      final discoveredUsername = (profileForDiscovery['sasUsername'] ?? '').toString().trim();
      if (uid != null && sasUsername.trim().isEmpty && discoveredUsername.isNotEmpty) {
        sasUsername = discoveredUsername;
        final currentSnapshot = await FirebaseDatabase.instance
            .ref('agents/${uid}_$discoveredUsername')
            .get()
            .timeout(const Duration(seconds: 10));
        final currentData = currentSnapshot.value;
        if (currentData is Map) {
          snapshot = currentSnapshot;
          data = snapshot.value;
          agentData = Map<String, dynamic>.from(data as Map);
        }
      }
      final p = await SharedPreferences.getInstance();

      int remoteRevision = 0;
      final localRevisionBeforePull = subscribersRevision;
      final allowRemoteBootstrap =
          localRevisionBeforePull == 0 && subscribers.isEmpty;
      if (agentData['settings'] is Map) {
        final settings = Map<String, dynamic>.from(agentData['settings']);
        remoteRevision = int.tryParse((settings[subscribersRevisionKey] ?? 0).toString()) ?? 0;
        final shouldApplyRemoteSettings =
            remoteRevision >= localRevisionBeforePull || allowRemoteBootstrap;

        if (shouldApplyRemoteSettings) {
          if (settings['officeName'] != null) { officeName = settings['officeName'].toString(); await p.setString('officeName', officeName); }
          if (settings['officePhone'] != null) { officePhone = settings['officePhone'].toString(); await p.setString('officePhone', officePhone); }
          if (settings['officeAddress'] != null) { officeAddress = settings['officeAddress'].toString(); await p.setString('officeAddress', officeAddress); }
          if (settings['officeLogoBase64'] != null) { officeLogoBase64 = settings['officeLogoBase64'].toString(); await p.setString('officeLogoBase64', officeLogoBase64); }
          if (settings['receiptFooter'] != null) { receiptFooter = settings['receiptFooter'].toString(); await p.setString('receiptFooter', receiptFooter); }
          if (settings['balance'] != null) { balance = (settings['balance'] as num).toDouble(); await p.setDouble('balance', balance); }
          if (settings['nextReceiptNumber'] != null) { nextReceiptNumber = (settings['nextReceiptNumber'] as num).toInt(); await p.setInt('nextReceiptNumber', nextReceiptNumber); }
          if (settings['lastSasSync'] != null) { lastSasSync = DateTime.tryParse(settings['lastSasSync'].toString()); if (lastSasSync != null) await p.setString('lastSasSync', lastSasSync!.toIso8601String()); }
        } else {
          debugPrint('Skip stale Firebase settings snapshot. remoteRevision=$remoteRevision, localRevision=$subscribersRevision');
        }

      }

      final packagesPayload = agentData['packages'];
      final packagesListPayload = agentData['packagesList'];
      final allowBootstrap = subscribersRevision == 0 && subscribers.isEmpty;
      if (packagesPayload != null || packagesListPayload != null) {
        applyPackagesPayload(
          packagesListPayload ?? packagesPayload,
          fromRemote: true,
          remoteRevision: remoteRevision,
          allowBootstrap: allowBootstrap,
        );
        await p.setString('packages', jsonEncode(_packagesListPayload()));
      } else {
        final localP = p.getString('packages');
        if (localP != null) {
          try {
            packages.applyPayload(jsonDecode(localP));
          } catch (_) {}
        }
      }

      if (agentData['messageTemplates'] is Map) {
        for (final entry in (Map<String, dynamic>.from(agentData['messageTemplates'])).entries) {
          if (entry.value != null) messageTemplates[entry.key] = entry.value.toString();
        }
        _migrateNearExpiryTemplate();
        await p.setString('messageTemplates', jsonEncode(messageTemplates));
      } else {
        final localMt = p.getString('messageTemplates');
        if (localMt != null) { try { messageTemplates.addAll(Map<String,String>.from(jsonDecode(localMt))); } catch (_) {} }
        _migrateNearExpiryTemplate();
        await p.setString('messageTemplates', jsonEncode(messageTemplates));
      }

      if (agentData['subscription'] is Map) {
        final subscription = Map<String, dynamic>.from(agentData['subscription']);
        _applySubscriptionMap(subscription);
        await p.setString('subscriptionPlan', subscriptionPlan);
        await p.setString('subscriptionPlanLabel', subscriptionPlanLabel);
        await p.setInt('subscriptionDurationDays', subscriptionDurationDays);
        await p.setString('subscriptionPrice', subscriptionPrice);
        await p.setString('paymentMethod', paymentMethod);
        await p.setBool('subscriptionAutoExpire', subscriptionAutoExpire);
        await p.setString('subscriptionLastPaymentId', subscriptionLastPaymentId);
        await p.setString('subscriptionStatus', subscriptionStatus);
        if (subscriptionStartedAt != null) {
          await p.setString('subscriptionStartedAt', subscriptionStartedAt!.toIso8601String());
        }
        if (subscriptionEndsAt != null) {
          await p.setString('subscriptionEndsAt', subscriptionEndsAt!.toIso8601String());
        }
      } else {
        final legacyPlan = p.getString('subscriptionPlan') ?? '';
        final legacyStarted = p.getString('subscriptionStartedAt') ?? '';
        final legacyEnded = p.getString('subscriptionEndsAt') ?? '';
        if (legacyPlan.isNotEmpty) subscriptionPlan = legacyPlan;
        subscriptionPlanLabel = p.getString('subscriptionPlanLabel') ?? subscriptionPlanLabel;
        if (subscriptionPlan.isNotEmpty) {
          subscriptionPlanLabel = subscriptionPlanLabelFor(subscriptionPlan);
        }
        subscriptionDurationDays = p.getInt('subscriptionDurationDays') ?? subscriptionDurationDays;
        subscriptionPrice = p.getString('subscriptionPrice') ?? subscriptionPrice;
        paymentMethod = p.getString('paymentMethod') ?? paymentMethod;
        subscriptionAutoExpire = p.getBool('subscriptionAutoExpire') ?? subscriptionAutoExpire;
        subscriptionLastPaymentId = p.getString('subscriptionLastPaymentId') ?? subscriptionLastPaymentId;
        subscriptionStatus = p.getString('subscriptionStatus') ?? subscriptionStatus;
        subscriptionStartedAt = _parseDateTime(legacyStarted) ?? subscriptionStartedAt;
        subscriptionEndsAt = _parseDateTime(legacyEnded) ?? subscriptionEndsAt;
        if (subscriptionPlan.isNotEmpty && subscriptionStartedAt != null && subscriptionEndsAt == null) {
          subscriptionEndsAt = subscriptionStartedAt!.add(_subscriptionDurationForPlan(subscriptionPlan));
        }
      }

      if (agentData['profile'] is Map) {
        final profile = Map<String, dynamic>.from(agentData['profile']);
        if (profile['firstName'] != null) {
          agentFirstName = profile['firstName'].toString().trim();
          await p.setString('agentFirstName', agentFirstName);
        }
        if (profile['lastName'] != null) {
          agentLastName = profile['lastName'].toString().trim();
          await p.setString('agentLastName', agentLastName);
        }
        if (profile['name'] != null) {
          agentName = profile['name'].toString().trim();
          await p.setString('agentName', agentName);
        }
        if (agentName.trim().isEmpty) {
          agentName = [agentFirstName, agentLastName].where((e) => e.isNotEmpty).join(' ').trim();
          await p.setString('agentName', agentName);
        }
        if (profile['email'] != null) {
          agentEmail = profile['email'].toString().trim();
          await p.setString('agentEmail', agentEmail);
        }
        if (profile['sasUsername'] != null) sasUsername = profile['sasUsername'].toString();
        if (profile['phone'] != null) officePhone = profile['phone'].toString().trim();
        refreshSubscriptionStatus();
      }

      if (agentData['subscribers'] != null) {
        if (remoteRevision > localRevisionBeforePull || allowRemoteBootstrap) {
          final rawJson = jsonEncode(agentData['subscribers']);
          await p.setString('subscribers', rawJson);
          if (remoteRevision > 0) {
            subscribersRevision = remoteRevision;
            await p.setInt(subscribersRevisionKey, subscribersRevision);
          }
        } else {
          debugPrint('Skip stale Firebase subscribers snapshot. remoteRevision=$remoteRevision, localRevision=$subscribersRevision');
        }
      }
      await _loadSubscribers(p);
      if (remoteRevision > localRevisionBeforePull || allowRemoteBootstrap) {
        applyDebtsPayload(agentData['debts']);
        await p.setString(
          'subscribers',
          jsonEncode(subscribers.map((subscriber) => subscriber.toJson()).toList()),
        );
      }
    } catch (e) {
      debugPrint('Firebase pull failed: $e');
      final p = await SharedPreferences.getInstance();
      await _loadSubscribers(p);
    }
  }

  static Future<void> _loadSubscribers(SharedPreferences p) async {
    final raw = p.getString('subscribers') ?? p.getString('subscribers_backup');
    subscribers.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        final temp=<Subscriber>[];
        if (decoded is List) {
          for (final e in decoded){ if(e is Map) temp.add(Subscriber.fromJson(Map<String,dynamic>.from(e))); }
        } else if (decoded is Map) {
          final iterable = decoded.containsKey('subscribers') ? (decoded['subscribers'] as Iterable) : decoded.values;
          for(final e in iterable){ if(e is Map) temp.add(Subscriber.fromJson(Map<String,dynamic>.from(e))); }
        }
        subscribers..clear()..addAll(temp);
      } catch (_) {
        final backup = p.getString('subscribers_backup');
        if (backup != null && backup.isNotEmpty && backup != raw) {
          try { final decoded = jsonDecode(backup); final List list = decoded['subscribers'] as List; subscribers.addAll(list.map((e) => Subscriber.fromJson(Map<String, dynamic>.from(e)))); } catch (_) { subscribers.clear(); }
        }
      }
    }
  }

  static Future<void> clearForAccountSwitch({bool clearStorage = false}) async {
    realtimeListener?.cancel();
    realtimeListener = null;

    subscribers.clear();
    packages.clear();
    dailyTaskEvents.clear();

    messageTemplates.clear();
    messageTemplates['activation'] = activationTemplate;
    messageTemplates['extension'] = 'مرحباً {name}، تم تمديد اشتراكك لدى {office} حتى {endDate}.';
    messageTemplates['nearExpiry'] = nearExpiryTemplate;
    messageTemplates['expired'] = 'مرحباً {name}، اشتراكك لدى {office} منتهي. يرجى التجديد لاستمرار الخدمة.';
    messageTemplates['debt'] = debtTemplate;
    messageTemplates['debtPaid'] = debtPaidTemplate;

    agentFirstName = '';
    agentLastName = '';
    agentName = '';
    agentEmail = '';
    officeName = '';
    officePhone = '';
    officeAddress = '';
    officeLogoBase64 = '';
    receiptFooter = '';
    balance = 0;
    nextReceiptNumber = 1;
    subscribersRevision = 0;
    packagesRevision = 0;
    lastSasSync = null;
    sasUsername = '';
    subscriptionPlan = 'free';
    subscriptionPlanLabel = '';
    subscriptionDurationDays = 0;
    subscriptionPrice = '';
    paymentMethod = 'master';
    subscriptionAutoExpire = true;
    subscriptionLastPaymentId = '';
    subscriptionStartedAt = null;
    subscriptionEndsAt = null;
    subscriptionStatus = 'inactive';
    _loadedUid = null;

    if (!clearStorage) return;

    final p = await SharedPreferences.getInstance();
    const keysToClear = <String>[
      'officeName',
      'officePhone',
      'officeAddress',
      'officeLogoBase64',
      'receiptFooter',
      'balance',
      'nextReceiptNumber',
      'lastSasSync',
      'packages',
      'messageTemplates',
      'subscriptionPlan',
      'subscriptionPlanLabel',
      'subscriptionDurationDays',
      'subscriptionPrice',
      'paymentMethod',
      'subscriptionAutoExpire',
      'subscriptionLastPaymentId',
      'subscriptionStatus',
      'subscriptionStartedAt',
      'subscriptionEndsAt',
      'subscribers',
      'subscribers_backup',
      'sas_server_url',
      'sas_manager_username',
      'sas_manager_password',
      'sas_manager_password_sec',
      'sas_web_proxy_url',
      'web_proxy_url',
      'proxy_url',
      'render_proxy_url',
      'subscribersRevision',
      'packagesRevision',
      'dailyTaskEvents',
      'subscriptionPlan',
      'subscriptionPlanLabel',
      'subscriptionDurationDays',
      'subscriptionPrice',
      'paymentMethod',
      'subscriptionAutoExpire',
      'subscriptionLastPaymentId',
      'subscriptionStatus',
      'subscriptionStartedAt',
      'subscriptionEndsAt',
      'agentFirstName',
      'agentLastName',
      'agentName',
      'agentEmail',
      'agentId',
      'sasUsername',
      'dataVersion',
    ];
    for (final key in keysToClear) {
      await p.remove(key);
    }
  }

  static Future<void> load() async {
    final uid = _uid;
    if (uid != null && _loadedUid != uid) {
      await clearForAccountSwitch();
      _loadedUid = uid;
    } else if (uid == null) {
      _loadedUid = null;
    }

    final p = await SharedPreferences.getInstance();
    agentFirstName = p.getString('agentFirstName') ?? '';
    agentLastName = p.getString('agentLastName') ?? '';
    agentName = p.getString('agentName') ?? '';
    agentEmail = p.getString('agentEmail') ?? '';
    officeName = p.getString('officeName') ?? '';
    officePhone = p.getString('officePhone') ?? '';
    officeAddress = p.getString('officeAddress') ?? '';
    officeLogoBase64 = p.getString('officeLogoBase64') ?? '';
    receiptFooter = p.getString('receiptFooter') ?? '';
    balance = p.getDouble('balance') ?? 0;
    nextReceiptNumber = p.getInt('nextReceiptNumber') ?? 1;
    subscribersRevision = p.getInt(subscribersRevisionKey) ?? 0;
    packagesRevision = p.getInt(packagesRevisionKey) ?? 0;
    lastSasSync = DateTime.tryParse(p.getString('lastSasSync') ?? '');
    subscriptionPlan = p.getString('subscriptionPlan') ?? '';
    subscriptionPlanLabel = p.getString('subscriptionPlanLabel') ?? '';
    subscriptionDurationDays = p.getInt('subscriptionDurationDays') ?? 0;
    subscriptionPrice = p.getString('subscriptionPrice') ?? '';
    paymentMethod = p.getString('paymentMethod') ?? 'master';
    subscriptionAutoExpire = p.getBool('subscriptionAutoExpire') ?? true;
    subscriptionLastPaymentId = p.getString('subscriptionLastPaymentId') ?? '';
    subscriptionStatus = p.getString('subscriptionStatus') ?? 'inactive';
    subscriptionStartedAt = DateTime.tryParse(p.getString('subscriptionStartedAt') ?? '');
    subscriptionEndsAt = DateTime.tryParse(p.getString('subscriptionEndsAt') ?? '');
    final eventsRaw = p.getString(dailyTaskEventsKey);
    dailyTaskEvents.clear();
    if (eventsRaw != null && eventsRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(eventsRaw);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is Map) {
              dailyTaskEvents.add(
                DailyTaskEvent.fromJson(Map<String, dynamic>.from(e)),
              );
            }
          }
        }
      } catch (_) {}
    }
    _trimDailyTaskEvents();
    try {
      await _pullFromFirebase().timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('Firebase sync on load failed: $e');
      packages.clear();
      final pr = p.getString('packages');
      if (pr != null) { try { packages.addAll((jsonDecode(pr) as List).map((e)=>PackagePlan.fromJson(Map<String,dynamic>.from(e)))); } catch (_) {} }
      final mt = p.getString('messageTemplates');
      if (mt != null) { try { messageTemplates.addAll(Map<String,String>.from(jsonDecode(mt))); } catch (_) {} }
      _migrateNearExpiryTemplate();
      await p.setString('messageTemplates', jsonEncode(messageTemplates));
      await _loadSubscribers(p);
    }

    try {
      await _syncDebtsNodeToFirebase();
    } catch (e) {
      debugPrint('Firebase debts backfill failed: $e');
    }
  }

  static DateTime? _parseDateTime(dynamic value) {
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    if (value is String && value.trim().isNotEmpty) {
      return DateTime.tryParse(value.trim()) ?? DateTime.tryParse(value.trim().replaceFirst(' ', 'T'));
    }
    return null;
  }

  static Duration _subscriptionDurationForPlan(String plan) {
    switch (plan.trim()) {
      case 'free_15_days':
      case 'trial':
        return const Duration(days: 15);
      case 'three_months':
      case '3m':
        return const Duration(days: 90);
      case 'six_months':
      case '6m':
        return const Duration(days: 183);
      case 'one_year':
      case '1y':
        return const Duration(days: 365);
      default:
        return const Duration(days: 0);
    }
  }

  static Map<String, dynamic> _subscriptionMap() => {
        'plan': subscriptionPlan.isNotEmpty ? subscriptionPlan : 'free',
        'status': subscriptionStatus,
        'durationDays': subscriptionDurationDays,
        'startDate': subscriptionStartedAt?.toIso8601String(),
        'endDate': subscriptionEndsAt?.toIso8601String(),
        'autoExpire': subscriptionAutoExpire,
        'lastPaymentId': subscriptionLastPaymentId,
      };

  static void _applySubscriptionMap(Map<String, dynamic> source) {
    final planValue = (source['plan'] ?? '').toString().trim();
    if (planValue.isNotEmpty) subscriptionPlan = planValue;
    final statusValue = (source['status'] ?? '').toString().trim();
    if (statusValue.isNotEmpty) subscriptionStatus = statusValue;
    subscriptionDurationDays = int.tryParse((source['durationDays'] ?? 0).toString()) ?? subscriptionDurationDays;
    subscriptionStartedAt = _parseDateTime(source['startDate']) ?? subscriptionStartedAt;
    subscriptionEndsAt = _parseDateTime(source['endDate']) ?? subscriptionEndsAt;
    if (source['autoExpire'] != null) {
      subscriptionAutoExpire = source['autoExpire'] == true || source['autoExpire'].toString().toLowerCase() == 'true';
    }
    subscriptionLastPaymentId = (source['lastPaymentId'] ?? subscriptionLastPaymentId).toString();
    subscriptionPlanLabel = subscriptionPlanLabelFor(subscriptionPlan);
  }

  static void refreshSubscriptionStatus({DateTime? now}) {
    final reference = now ?? DateTime.now();
    if (subscriptionPlan.isEmpty || subscriptionPlan == 'free') {
      subscriptionStatus = 'inactive';
      return;
    }

    if (subscriptionEndsAt == null) {
      if (subscriptionStartedAt != null) {
        subscriptionEndsAt = subscriptionStartedAt!.add(_subscriptionDurationForPlan(subscriptionPlan));
      } else {
        subscriptionStatus = 'inactive';
        return;
      }
    }

    // Expire immediately when reaching the end instant (>= endDate).
    subscriptionStatus = reference.isBefore(subscriptionEndsAt!) ? 'active' : 'expired';
  }

  static List<Map<String, dynamic>> _packagesListPayload() =>
      packages.map((e) => e.toJson()).toList();

  static void applyPackagesPayload(
    dynamic payload, {
    bool fromRemote = false,
    int remoteRevision = 0,
    bool allowBootstrap = false,
  }) {
    if (fromRemote && !allowBootstrap && remoteRevision <= packagesRevision) {
      return;
    }

    final parsed = <PackagePlan>[];

    void addFromMap(Map<String, dynamic> map) {
      final name = (map['name'] ?? '').toString().trim();
      if (name.isEmpty) return;
      parsed.add(
        PackagePlan(
          name: name,
          price: (map['price'] ?? 0).toDouble(),
        ),
      );
    }

    if (payload is List) {
      for (final item in payload) {
        if (item is Map) {
          addFromMap(Map<String, dynamic>.from(item));
        } else if (item is String && item.trim().isNotEmpty) {
          try {
            final decoded = jsonDecode(item);
            if (decoded is Map) {
              addFromMap(Map<String, dynamic>.from(decoded));
            }
          } catch (_) {}
        }
      }
    } else if (payload is Map) {
      for (final entry in payload.entries) {
        if (entry.value is Map) {
          addFromMap(Map<String, dynamic>.from(entry.value as Map));
        }
      }
    } else if (payload is String && payload.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(payload);
        if (decoded is List || decoded is Map) {
          applyPackagesPayload(
            decoded,
            fromRemote: fromRemote,
            remoteRevision: remoteRevision,
            allowBootstrap: allowBootstrap,
          );
        }
      } catch (_) {}
    }

    if (parsed.isEmpty) {
      packages.clear();
      return;
    }

    packages
      ..clear()
      ..addAll(parsed);
  }

  static Map<String, dynamic> _packagesMapPayload() {
    final map = <String, dynamic>{};
    for (var i = 0; i < packages.length; i++) {
      map['pkg_$i'] = packages[i].toJson();
    }
    return map;
  }

  static Map<String, dynamic> buildDebtsPayload() {
    final debts = <String, dynamic>{};
    for (final subscriber in subscribers) {
      if (subscriber.remaining <= 0.0001) continue;

      final identity = subscriber.sasId.trim().isNotEmpty
          ? 'sas:${subscriber.sasId.trim()}'
          : 'user:${subscriber.user.trim()}';
      final key = base64Url.encode(utf8.encode(identity)).replaceAll('=', '');
      debts[key] = <String, dynamic>{
        'user': subscriber.user,
        'sasId': subscriber.sasId,
        'name': subscriber.name,
        'phone': subscriber.phone,
        'package': subscriber.packageDisplay,
        'subscriptionAmount': subscriber.price,
        'paidAmount': subscriber.paid,
        'remainingAmount': subscriber.remaining,
        'paymentDate': subscriber.paymentDate,
        'payments': subscriber.payments.map((payment) => payment.toJson()).toList(),
      };
    }
    return debts;
  }

  static void applyDebtsPayload(dynamic payload) {
    if (payload is! Map) return;

    for (final rawDebt in payload.values) {
      if (rawDebt is! Map) continue;
      final debt = Map<String, dynamic>.from(rawDebt);
      final sasId = (debt['sasId'] ?? '').toString().trim();
      final user = (debt['user'] ?? '').toString().trim().toLowerCase();
      final index = subscribers.indexWhere((subscriber) {
        if (sasId.isNotEmpty && subscriber.sasId.trim() == sasId) return true;
        return user.isNotEmpty && subscriber.user.trim().toLowerCase() == user;
      });
      if (index < 0) continue;

      final subscriber = subscribers[index];
      final subscriptionAmount =
          (debt['subscriptionAmount'] as num?)?.toDouble();
      final paidAmount = (debt['paidAmount'] as num?)?.toDouble();
      if (subscriptionAmount != null && paidAmount != null) {
        subscriber.setDebtAmounts(
          subscriptionAmount: subscriptionAmount,
          paidAmount: paidAmount,
        );
      }
      subscriber.paymentDate =
          (debt['paymentDate'] ?? subscriber.paymentDate).toString();

      final paymentsPayload = debt['payments'];
      if (paymentsPayload is List) {
        subscriber.payments = paymentsPayload
            .whereType<Map>()
            .map((payment) => PaymentRecord.fromJson(
                  Map<String, dynamic>.from(payment),
                ))
            .toList();
        if (subscriber.payments.isNotEmpty) {
          subscriber.reconcilePaidFromPayments();
        }
      }
    }
  }

  static Future<void> _syncDebtsNodeToFirebase() async {
    if (!_isLoggedIn) return;
    final debtsPayload = buildDebtsPayload();
    await _agentRef
        .child('debts')
        .set(debtsPayload.isEmpty ? null : debtsPayload)
        .timeout(const Duration(seconds: 10));
  }

  static Future<void> save() async {
    if (!_isLoggedIn) debugPrint('AppStore.save: User not logged in, saving locally only');
    final p = await SharedPreferences.getInstance();
    subscribersRevision = DateTime.now().millisecondsSinceEpoch;
    refreshSubscriptionStatus();

    if (agentName.trim().isEmpty) {
      agentName = [agentFirstName, agentLastName].where((e) => e.isNotEmpty).join(' ').trim();
    }

    await p.setString('officeName', officeName);
    await p.setString('officePhone', officePhone);
    await p.setString('officeAddress', officeAddress);
    await p.setString('officeLogoBase64', officeLogoBase64);
    await p.setString('receiptFooter', receiptFooter);
    await p.setDouble('balance', balance);
    await p.setInt('nextReceiptNumber', nextReceiptNumber);
    await p.setInt(subscribersRevisionKey, subscribersRevision);
    packagesRevision = DateTime.now().millisecondsSinceEpoch;
    await p.setInt(packagesRevisionKey, packagesRevision);
    if (lastSasSync != null) await p.setString('lastSasSync', lastSasSync!.toIso8601String());
    await p.setString('packages', jsonEncode(packages.map((e)=>e.toJson()).toList()));
    await p.setString('messageTemplates', jsonEncode(messageTemplates));
    await p.setString('subscriptionPlan', subscriptionPlan);
    await p.setString('subscriptionPlanLabel', subscriptionPlanLabel);
    await p.setInt('subscriptionDurationDays', subscriptionDurationDays);
    await p.setString('subscriptionPrice', subscriptionPrice);
    await p.setString('paymentMethod', paymentMethod);
    await p.setBool('subscriptionAutoExpire', subscriptionAutoExpire);
    await p.setString('subscriptionLastPaymentId', subscriptionLastPaymentId);
    await p.setString('subscriptionStatus', subscriptionStatus);
    if (subscriptionStartedAt != null) await p.setString('subscriptionStartedAt', subscriptionStartedAt!.toIso8601String());
    if (subscriptionEndsAt != null) await p.setString('subscriptionEndsAt', subscriptionEndsAt!.toIso8601String());
    final encoded = jsonEncode(subscribers.map((e) => e.toJson()).toList());
    final previous = p.getString('subscribers');
    if (previous != null && previous.isNotEmpty) await p.setString('subscribers_backup', previous);
    await p.setInt('dataVersion', dataVersion);
    await p.setString('subscribers', encoded);
    _trimDailyTaskEvents();
    await p.setString(
      dailyTaskEventsKey,
      jsonEncode(dailyTaskEvents.map((e) => e.toJson()).toList()),
    );

    if (!_isLoggedIn) return;

    try {
      final ref = _agentRef;
      final currentUser = FirebaseAuth.instance.currentUser;
      await ref.child('profile').update({
        'email': currentUser?.email ?? '',
        if (agentFirstName.isNotEmpty) 'firstName': agentFirstName,
        if (agentLastName.isNotEmpty) 'lastName': agentLastName,
        if (agentName.isNotEmpty) 'name': agentName,
        if (officePhone.trim().isNotEmpty) 'phone': officePhone.trim(),
        if (sasUsername.trim().isNotEmpty) 'sasUsername': sasUsername.trim(),
        'status': sasUsername.trim().isNotEmpty ? 'active' : 'pending_sas',
        'updatedAt': ServerValue.timestamp,
      });

      await ref.child(subscriptionNodeKey).set(_subscriptionMap());

      final packagesMap = _packagesMapPayload();
      final packagesList = _packagesListPayload();
      final debtsPayload = buildDebtsPayload();

      // Write revision and subscribers in a single update to avoid
      // intermediate snapshots where revision is new but subscribers are old.
      final storePatch = <String, dynamic>{
        'settings/officeName': officeName,
        'settings/officePhone': officePhone,
        'settings/officeAddress': officeAddress,
        'settings/officeLogoBase64': officeLogoBase64,
        'settings/receiptFooter': receiptFooter,
        'settings/balance': balance,
        'settings/nextReceiptNumber': nextReceiptNumber,
        'settings/$subscribersRevisionKey': subscribersRevision,
        'subscribers': subscribers.map((e) => e.toJson()).toList(),
        'debts': debtsPayload.isEmpty ? null : debtsPayload,
      };
      if (lastSasSync != null) {
        storePatch['settings/lastSasSync'] = lastSasSync!.toIso8601String();
      }
      await ref.update(storePatch);

      await ref.child('packages').set(packagesMap);
      await ref.child('packagesList').set(packagesList);
      await ref.child('messageTemplates').set(messageTemplates);
      debugPrint('Firebase save completed successfully');
    } catch (e) { debugPrint('Firebase save failed: $e'); }
  }

  static void startRealtimeSync() {
    realtimeListener?.cancel();
    if (!_isLoggedIn) { debugPrint('Realtime: not logged in'); return; }
    try {
      final ref = _agentRef;
      realtimeListener = ref.onValue.listen((event) async {
        final data = event.snapshot.value;
        if (data == null) return;
        try {
          final agentData = Map<String, dynamic>.from(data as Map);
          final p = await SharedPreferences.getInstance();

          int remoteRevision = 0;
          final localRevisionBeforeEvent = subscribersRevision;
          final allowRemoteBootstrap =
              localRevisionBeforeEvent == 0 && subscribers.isEmpty;
          if (agentData['settings'] is Map) {
            final settings = Map<String, dynamic>.from(agentData['settings']);
            remoteRevision = int.tryParse((settings[subscribersRevisionKey] ?? 0).toString()) ?? 0;
            final shouldApplyRemoteSettings =
                remoteRevision >= localRevisionBeforeEvent || allowRemoteBootstrap;

            if (shouldApplyRemoteSettings) {
              if (settings['officeName'] != null) { officeName = settings['officeName'].toString(); await p.setString('officeName', officeName); }
              if (settings['officePhone'] != null) { officePhone = settings['officePhone'].toString(); await p.setString('officePhone', officePhone); }
              if (settings['officeAddress'] != null) { officeAddress = settings['officeAddress'].toString(); await p.setString('officeAddress', officeAddress); }
              if (settings['officeLogoBase64'] != null) { officeLogoBase64 = settings['officeLogoBase64'].toString(); await p.setString('officeLogoBase64', officeLogoBase64); }
              if (settings['receiptFooter'] != null) { receiptFooter = settings['receiptFooter'].toString(); await p.setString('receiptFooter', receiptFooter); }
              if (settings['balance'] != null) { balance = (settings['balance'] as num).toDouble(); await p.setDouble('balance', balance); }
              if (settings['nextReceiptNumber'] != null) { nextReceiptNumber = (settings['nextReceiptNumber'] as num).toInt(); await p.setInt('nextReceiptNumber', nextReceiptNumber); }
              if (settings['lastSasSync'] != null) { lastSasSync = DateTime.tryParse(settings['lastSasSync'].toString()); if (lastSasSync != null) await p.setString('lastSasSync', lastSasSync!.toIso8601String()); }
            } else {
              debugPrint('Realtime: ignored stale settings snapshot. remoteRevision=$remoteRevision, localRevision=$subscribersRevision');
            }

          }
          if (agentData['packages'] is Map) {
            applyPackagesPayload(
              agentData['packages'],
              fromRemote: true,
              remoteRevision: remoteRevision,
              allowBootstrap: subscribersRevision == 0 && subscribers.isEmpty,
            );
            await p.setString('packages', jsonEncode(packages.map((e)=>e.toJson()).toList()));
          }
          if (agentData['messageTemplates'] is Map) {
            for (final entry in (Map<String, dynamic>.from(agentData['messageTemplates'])).entries) {
              if (entry.value != null) messageTemplates[entry.key] = entry.value.toString();
            }
            _migrateNearExpiryTemplate();
            await p.setString('messageTemplates', jsonEncode(messageTemplates));
          }
          if (agentData['profile'] is Map) {
            final profile = Map<String, dynamic>.from(agentData['profile']);
            if (profile['sasUsername'] != null) sasUsername = profile['sasUsername'].toString();
          }
          if (agentData['subscribers'] != null) {
            if (remoteRevision > localRevisionBeforeEvent || allowRemoteBootstrap) {
              final rawJson = jsonEncode(agentData['subscribers']);
              await p.setString('subscribers', rawJson);
              if (remoteRevision > 0) {
                subscribersRevision = remoteRevision;
                await p.setInt(subscribersRevisionKey, subscribersRevision);
              }
              await _loadSubscribers(p);
              applyDebtsPayload(agentData['debts']);
              await p.setString(
                'subscribers',
                jsonEncode(
                  subscribers.map((subscriber) => subscriber.toJson()).toList(),
                ),
              );
            } else {
              debugPrint('Realtime: ignored stale subscribers snapshot. remoteRevision=$remoteRevision, localRevision=$subscribersRevision');
            }
          }
          debugPrint('Realtime agent data updated');
        } catch (e) { debugPrint('Realtime update error: $e'); }
      });
    } catch (e) { debugPrint('Realtime start error: $e'); }
  }

  static Future<void> deleteAllSubscribers() async { subscribers.clear(); await save(); }
  static Future<void> deleteSasSubscribersOnly() async { subscribers.removeWhere((s) => s.source == 'sas'); await save(); }

  static bool isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  static void _trimDailyTaskEvents() {
    final now = DateTime.now();
    dailyTaskEvents.removeWhere((e) => now.difference(e.at).inDays > 30);
    if (dailyTaskEvents.length > 3000) {
      dailyTaskEvents.sort((a, b) => a.at.compareTo(b.at));
      final overflow = dailyTaskEvents.length - 3000;
      dailyTaskEvents.removeRange(0, overflow);
    }
  }

  static Future<void> addDailyTaskEvent(
    DailyTaskEvent event, {
    bool persist = true,
  }) async {
    dailyTaskEvents.insert(0, event);
    _trimDailyTaskEvents();
    if (!persist) return;
    final p = await SharedPreferences.getInstance();
    await p.setString(
      dailyTaskEventsKey,
      jsonEncode(dailyTaskEvents.map((e) => e.toJson()).toList()),
    );
  }

  static Future<int> issueReceiptNumber({bool persist = true}) async {
    final number = nextReceiptNumber;
    nextReceiptNumber++;
    if (persist) {
      await save();
    }
    return number;
  }
}