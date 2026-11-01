import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'finance_ledger.dart';

typedef FinancePlan =
    List<FinanceEntry> Function(List<FinanceEntry> existing);

abstract interface class FinanceStore {
  Future<List<FinanceEntry>> readEntries(String subscriberId);

  Future<int> allocateReceiptNumber();

  /// ينفذ الخطة على أحدث قيود المشترك ذرياً، ويعيد القيود التي كُتبت.
  Future<List<FinanceEntry>> commit(String subscriberId, FinancePlan plan);
}

class FirebaseFinanceStore implements FinanceStore {
  FirebaseFinanceStore({
    required int Function() firstReceiptNumber,
    FirebaseAuth? auth,
    FirebaseDatabase? database,
  }) : _firstReceiptNumber = firstReceiptNumber,
       _uid = (auth ?? FirebaseAuth.instance).currentUser?.uid,
       _database = database;

  final int Function() _firstReceiptNumber;
  final String? _uid;
  final FirebaseDatabase? _database;

  DatabaseReference get _financeRef {
    final uid = _uid;
    if (uid == null || uid.isEmpty) {
      throw StateError('A signed-in Firebase user is required.');
    }
    return (_database ?? FirebaseDatabase.instance).ref('agents/$uid/finance');
  }

  DatabaseReference _entriesRef(String subscriberId) {
    if (subscriberId.trim().isEmpty) {
      throw ArgumentError.value(subscriberId, 'subscriberId');
    }
    return _financeRef.child('subscribers/$subscriberId/entries');
  }

  static List<FinanceEntry> _decode(Object? value) {
    if (value is! Map) return <FinanceEntry>[];
    return value.values
        .whereType<Map>()
        .map((raw) => FinanceEntry.fromJson(Map<String, dynamic>.from(raw)))
        .toList();
  }

  @override
  Future<List<FinanceEntry>> readEntries(String subscriberId) async {
    final snapshot = await _entriesRef(subscriberId).get();
    return _decode(snapshot.value);
  }

  @override
  Future<int> allocateReceiptNumber() async {
    final result = await _financeRef.child('nextReceiptNumber').runTransaction((
      value,
    ) {
      final next = value is num ? value.toInt() : _firstReceiptNumber();
      return Transaction.success(next + 1);
    }, applyLocally: false);
    final stored = result.snapshot.value;
    if (!result.committed || stored is! num) {
      throw StateError('Could not allocate a receipt number.');
    }
    return stored.toInt() - 1;
  }

  @override
  Future<List<FinanceEntry>> commit(
    String subscriberId,
    FinancePlan plan,
  ) async {
    Object? failure;
    var planned = <FinanceEntry>[];
    final result = await _entriesRef(subscriberId).runTransaction((value) {
      failure = null;
      planned = <FinanceEntry>[];
      try {
        planned = plan(_decode(value));
      } catch (error) {
        failure = error;
        // القيمة الفارغة قد تكون ذاكرة محلية فارغة، فنترك الخادم يعيد المحاولة
        // بالقيمة الحقيقية بدل إيقاف العملية بخطأ سياسة غير صحيح.
        return value == null
            ? Transaction.success(null)
            : Transaction.abort();
      }
      if (planned.isEmpty) return Transaction.abort();
      return Transaction.success({
        if (value is Map) ...value,
        for (final entry in planned) entry.id: entry.toJson(),
      });
    }, applyLocally: false);
    final error = failure;
    if (error != null) throw error;
    if (planned.isEmpty) return const <FinanceEntry>[];
    if (!result.committed) {
      throw StateError('Could not save the financial operation.');
    }
    return planned;
  }
}

class FinanceService {
  FinanceService({required this.store, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const int _precheckReceiptNumber = 1;

  final FinanceStore store;
  final DateTime Function() _clock;

  static String newOperationId() {
    final random = Random.secure();
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final nonce = List.generate(
      8,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '$stamp$nonce';
  }

  /// إعادة الطلب بنفس [operationId] تعيد قيوده الأصلية ولا تكررها.
  Future<List<FinanceEntry>> _run({
    required String subscriberId,
    required String operationId,
    required bool needsReceipt,
    required List<FinanceEntry> Function(
      List<FinanceEntry> existing,
      int? receiptNumber,
    )
    build,
  }) async {
    List<FinanceEntry> recorded(List<FinanceEntry> entries) => entries
        .where((entry) => entry.operationId == operationId)
        .toList();

    final existing = await store.readEntries(subscriberId);
    final previous = recorded(existing);
    if (previous.isNotEmpty) return previous;

    build(existing, needsReceipt ? _precheckReceiptNumber : null);
    final receiptNumber = needsReceipt
        ? await store.allocateReceiptNumber()
        : null;
    final written = await store.commit(subscriberId, (entries) {
      if (recorded(entries).isNotEmpty) return const <FinanceEntry>[];
      return build(entries, receiptNumber);
    });
    if (written.isNotEmpty) return written;
    return recorded(await store.readEntries(subscriberId));
  }

  Future<List<FinanceEntry>> recordSale({
    required String operationId,
    required FinanceSubscriberRef subscriber,
    required FinanceSaleInput input,
    required String createdBy,
  }) {
    final at = _clock();
    return _run(
      subscriberId: subscriber.id,
      operationId: operationId,
      needsReceipt: input.collected > 0,
      build: (_, receiptNumber) => FinancePolicy.sale(
        operationId: operationId,
        subscriber: subscriber,
        input: input,
        at: at,
        createdBy: createdBy,
        receiptNumber: receiptNumber,
      ),
    );
  }

  Future<List<FinanceEntry>> recordPurchase({
    required String operationId,
    required FinanceSubscriberRef subscriber,
    required FinancePurchaseInput input,
    required String createdBy,
  }) {
    final at = _clock();
    return _run(
      subscriberId: subscriber.id,
      operationId: operationId,
      needsReceipt: input.paidAmount > 0,
      build: (_, receiptNumber) => FinancePolicy.purchase(
        operationId: operationId,
        subscriber: subscriber,
        input: input,
        at: at,
        createdBy: createdBy,
        receiptNumber: receiptNumber,
      ),
    );
  }

  Future<List<FinanceEntry>> recordPayment({
    required String operationId,
    required FinanceSubscriberRef subscriber,
    required int amount,
    required String createdBy,
    String note = '',
  }) {
    final at = _clock();
    return _run(
      subscriberId: subscriber.id,
      operationId: operationId,
      needsReceipt: true,
      build: (existing, receiptNumber) => FinancePolicy.payment(
        operationId: operationId,
        subscriber: subscriber,
        existing: existing,
        amount: amount,
        at: at,
        createdBy: createdBy,
        receiptNumber: receiptNumber,
        note: note,
      ),
    );
  }

  Future<List<FinanceEntry>> recordCorrection({
    required String operationId,
    required FinanceSubscriberRef subscriber,
    required int amount,
    required String reason,
    required String createdBy,
  }) {
    final at = _clock();
    return _run(
      subscriberId: subscriber.id,
      operationId: operationId,
      needsReceipt: false,
      build: (existing, _) => FinancePolicy.correction(
        operationId: operationId,
        subscriber: subscriber,
        existing: existing,
        amount: amount,
        reason: reason,
        at: at,
        createdBy: createdBy,
      ),
    );
  }

  Future<List<FinanceEntry>> reverseEntry({
    required String operationId,
    required FinanceSubscriberRef subscriber,
    required String entryId,
    required String reason,
    required String createdBy,
  }) {
    final at = _clock();
    return _run(
      subscriberId: subscriber.id,
      operationId: operationId,
      needsReceipt: false,
      build: (existing, _) => FinancePolicy.reversal(
        operationId: operationId,
        subscriber: subscriber,
        existing: existing,
        entryId: entryId,
        reason: reason,
        at: at,
        createdBy: createdBy,
      ),
    );
  }
}
