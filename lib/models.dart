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

  void registerInvoiceFromPayment({
    required int receiptNumber,
    required double amount,
    DateTime? at,
    String note = '',
  }) {
    if (receiptNumber <= 0 || amount <= 0 || !amount.isFinite) return;
    final stamp = at ?? DateTime.now();
    invoices.add(InvoiceRecord(
      receiptNumber: receiptNumber,
      amount: amount,
      at: stamp,
      monthKey: monthKeyOf(stamp),
      note: note,
    ));
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

class AppStore {
  static const int dataVersion = 1;
  static const String subscribersRevisionKey = 'subscribersRevision';
  static const String dailyTaskEventsKey = 'dailyTaskEvents';
  static const String _legacyNearExpiryTemplate =
      'مرحباً {name}، نذكرك أن اشتراكك ينتهي بتاريخ {endDate}. يرجى التجديد.';
    static const String _legacyActivationTemplate =
      'مرحباً {name}، تم تفعيل اشتراكك لدى {office}. الباقة: {package} وتنتهي بتاريخ {endDate}.';
      static const String _legacyDebtTemplate =
        'مرحباً {name}، المبلغ المتبقي عليك هو {remaining}. يرجى التسديد، شكراً لكم.';
    static const String activationTemplate =
      'مرحباً {{الاسم المشترك}}،\n✅ تم تفعيل اشتراك الإنترنت بنجاح.\n📦 الباقة: {{اسم الباقة}}\n📅 يبدأ الاشتراك: {{تاريخ البدء}}\n📅 ينتهي الاشتراك: {{تاريخ الانتهاء}}\nمبلغ الاشتراك:{{مبلغ الاشتراك}}\n{{الواصل}}\n{{المتبقي}}\nللاستفسار يرجى التواصل مع:\n🏢 {{اسم الوكيل}}\n\nشكراً لاختياركم خدمتنا.';
      static const String debtPaidTemplate =
        'مرحباً {{الاسم المشترك}}،\n✅ تم استلام مبلغ الدين المترتب بذمتكم.\n💰 المبلغ المسدد: {{المبلغ}} دينار عراقي\n📅 تاريخ التسديد: {{التاريخ}}\nنشكر لكم التزامكم بالسداد.\nللاستفسار يرجى التواصل مع:\n🏢 {{اسم الوكيل}}\n\nشكراً لاختياركم خدمتنا.';
        static const String debtTemplate =
          'مرحباً {{الاسم المشترك}}،\n✅ يوجد دين مترتب بذمتكم جراء تفعيل الاشتراك.\n💰 يرجى تسديد: {{المبلغ}} دينار عراقي\n📅 لضمان استمرار الخدمة\nنشكر لكم التزامكم بالسداد.\nللاستفسار يرجى التواصل مع:\n🏢 {{اسم الوكيل}}\n\nشكراً لاختياركم خدمتنا.';
  static const String nearExpiryTemplate =
      'مرحباً {{الاسم المشترك}}،\n⏳ نود إعلامكم بأن اشتراك الإنترنت سينتهي قريباً.\n📅 تاريخ انتهاء الاشتراك: {{تاريخ الانتهاء}}\nلضمان استمرار الخدمة دون انقطاع، يرجى مراجعة:\n🏢 {{اسم الوكيل}}\n\nشكراً لاختياركم خدمتنا.';
  static final List<Subscriber> subscribers = [];
  static final List<DailyTaskEvent> dailyTaskEvents = [];
  static String agentFirstName = '';
  static String agentLastName = '';
  static String agentName = '';
  static String agentEmail = '';
  static String officeName = '';
  static String officePhone = '';
  static String officeAddress = '';
  static String officeLogoBase64 = '';
  static String receiptFooter = '';
  static String sasUsername = '';
  static double balance = 0;
  static int nextReceiptNumber = 1;
  static DateTime? lastSasSync;
  static int subscribersRevision = 0;
  static final List<PackagePlan> packages = [];
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
    final current = (messageTemplates['nearExpiry'] ?? '').trim();
    if (current.isEmpty || current == _legacyNearExpiryTemplate) {
      messageTemplates['nearExpiry'] = nearExpiryTemplate;
    }

    final currentActivation = (messageTemplates['activation'] ?? '').trim();
    if (currentActivation.isEmpty || currentActivation == _legacyActivationTemplate) {
      messageTemplates['activation'] = activationTemplate;
    }

    final currentDebtPaid = (messageTemplates['debtPaid'] ?? '').trim();
    if (currentDebtPaid.isEmpty) {
      messageTemplates['debtPaid'] = debtPaidTemplate;
    }

    final currentDebt = (messageTemplates['debt'] ?? '').trim();
    if (currentDebt.isEmpty || currentDebt == _legacyDebtTemplate) {
      messageTemplates['debt'] = debtTemplate;
    }
  }

  /// المعرف الفريد للوكيل: uid_sasUsername
  static String? get _agentId {
    final uid = _uid;
    if (uid == null) return null;
    if (sasUsername.trim().isNotEmpty) {
      return '${uid}_${sasUsername.trim()}';
    }
    return uid;
  }

  /// مسار Firebase للوكيل: agents/{uid_sasUsername}
  static DatabaseReference get _agentRef {
    final id = _agentId;
    if (id == null) throw Exception('User not logged in');
    return FirebaseDatabase.instance.ref('agents/$id');
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
      if (agentData['settings'] is Map) {
        final settings = Map<String, dynamic>.from(agentData['settings']);
        remoteRevision = int.tryParse((settings[subscribersRevisionKey] ?? 0).toString()) ?? 0;
        final allowBootstrap = subscribersRevision == 0 && subscribers.isEmpty;
        final shouldApplyRemoteSettings = remoteRevision >= subscribersRevision || allowBootstrap;

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

        if (remoteRevision > subscribersRevision) {
          subscribersRevision = remoteRevision;
          await p.setInt(subscribersRevisionKey, subscribersRevision);
        }
      }

      if (agentData['packages'] is Map) {
        packages.clear();
        for (final entry in (Map<String, dynamic>.from(agentData['packages'])).entries) {
          if (entry.value is Map) packages.add(PackagePlan.fromJson(Map<String, dynamic>.from(entry.value)));
        }
        await p.setString('packages', jsonEncode(packages.map((e)=>e.toJson()).toList()));
      } else {
        final localP = p.getString('packages');
        if (localP != null) { try { packages.addAll((jsonDecode(localP) as List).map((e)=>PackagePlan.fromJson(Map<String,dynamic>.from(e)))); } catch (_) {} }
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
        if (profile['email'] != null) {
          agentEmail = profile['email'].toString().trim();
          await p.setString('agentEmail', agentEmail);
        }
        if (profile['sasUsername'] != null) sasUsername = profile['sasUsername'].toString();
      }

      if (agentData['subscribers'] != null) {
        final allowBootstrap = subscribersRevision == 0 && subscribers.isEmpty;
        if (remoteRevision > subscribersRevision || allowBootstrap) {
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

  static Future<void> load() async {
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
    lastSasSync = DateTime.tryParse(p.getString('lastSasSync') ?? '');
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
  }

  static Future<void> save() async {
    if (!_isLoggedIn) debugPrint('AppStore.save: User not logged in, saving locally only');
    final p = await SharedPreferences.getInstance();
    subscribersRevision = DateTime.now().millisecondsSinceEpoch;

    await p.setString('officeName', officeName);
    await p.setString('officePhone', officePhone);
    await p.setString('officeAddress', officeAddress);
    await p.setString('officeLogoBase64', officeLogoBase64);
    await p.setString('receiptFooter', receiptFooter);
    await p.setDouble('balance', balance);
    await p.setInt('nextReceiptNumber', nextReceiptNumber);
    await p.setInt(subscribersRevisionKey, subscribersRevision);
    if (lastSasSync != null) await p.setString('lastSasSync', lastSasSync!.toIso8601String());
    await p.setString('packages', jsonEncode(packages.map((e)=>e.toJson()).toList()));
    await p.setString('messageTemplates', jsonEncode(messageTemplates));
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
        if (sasUsername.trim().isNotEmpty) 'sasUsername': sasUsername.trim(),
        'status': sasUsername.trim().isNotEmpty ? 'active' : 'pending_sas',
        'updatedAt': ServerValue.timestamp,
      });

      final packagesMap = <String, dynamic>{};
      for (var i = 0; i < packages.length; i++) {
        packagesMap['pkg_$i'] = packages[i].toJson();
      }

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
      };
      if (lastSasSync != null) {
        storePatch['settings/lastSasSync'] = lastSasSync!.toIso8601String();
      }
      await ref.update(storePatch);

      await ref.child('packages').set(packagesMap);
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
          if (agentData['settings'] is Map) {
            final settings = Map<String, dynamic>.from(agentData['settings']);
            remoteRevision = int.tryParse((settings[subscribersRevisionKey] ?? 0).toString()) ?? 0;
            final allowBootstrap = subscribersRevision == 0 && subscribers.isEmpty;
            final shouldApplyRemoteSettings = remoteRevision >= subscribersRevision || allowBootstrap;

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

            if (remoteRevision > subscribersRevision) {
              subscribersRevision = remoteRevision;
              await p.setInt(subscribersRevisionKey, subscribersRevision);
            }
          }
          if (agentData['packages'] is Map) {
            packages.clear();
            for (final entry in (Map<String, dynamic>.from(agentData['packages'])).entries) {
              if (entry.value is Map) packages.add(PackagePlan.fromJson(Map<String, dynamic>.from(entry.value)));
            }
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
            final allowBootstrap = subscribersRevision == 0 && subscribers.isEmpty;
            if (remoteRevision > subscribersRevision || allowBootstrap) {
              final rawJson = jsonEncode(agentData['subscribers']);
              await p.setString('subscribers', rawJson);
              if (remoteRevision > 0) {
                subscribersRevision = remoteRevision;
                await p.setInt(subscribersRevisionKey, subscribersRevision);
              }
              await _loadSubscribers(p);
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