import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

enum FinancialTransactionType {
  openingBalance('opening_balance'),
  invoice('invoice'),
  activation('activation'),
  payment('payment'),
  partialPayment('partial_payment'),
  debt('debt'),
  credit('credit'),
  companyDeposit('company_deposit'),
  activationCost('activation_cost'),
  expense('expense'),
  adjustment('adjustment');

  const FinancialTransactionType(this.value);

  final String value;

  static FinancialTransactionType fromValue(String value) {
    return FinancialTransactionType.values.firstWhere(
      (type) => type.value == value,
      orElse: () => throw FormatException('Unknown transaction type: $value'),
    );
  }
}

class FinancialTransaction {
  const FinancialTransaction({
    required this.id,
    required this.subscriberId,
    required this.date,
    required this.type,
    required this.amount,
    required this.note,
    required this.referenceId,
    required this.monthKey,
    required this.createdAt,
    required this.createdBy,
  });

  final String id;
  final String subscriberId;
  final DateTime date;
  final FinancialTransactionType type;
  final double amount;
  final String note;
  final String referenceId;
  final String monthKey;
  final DateTime createdAt;
  final String createdBy;

  Map<String, dynamic> toJson() => {
    'id': id,
    'subscriberId': subscriberId,
    'date': date.toIso8601String(),
    'type': type.value,
    'amount': amount,
    'note': note,
    'referenceId': referenceId,
    'monthKey': monthKey,
    'createdAt': createdAt.toIso8601String(),
    'createdBy': createdBy,
  };

  factory FinancialTransaction.fromJson(Map<String, dynamic> json) {
    final date = DateTime.parse(json['date'].toString());
    return FinancialTransaction(
      id: json['id'].toString(),
      subscriberId: json['subscriberId'].toString(),
      date: date,
      type: FinancialTransactionType.fromValue(json['type'].toString()),
      amount: (json['amount'] as num).toDouble(),
      note: (json['note'] ?? '').toString(),
      referenceId: (json['referenceId'] ?? '').toString(),
      monthKey: (json['monthKey'] ?? _monthKeyFor(date)).toString(),
      createdAt: DateTime.parse(json['createdAt'].toString()),
      createdBy: (json['createdBy'] ?? '').toString(),
    );
  }
}

class SubscriberMonthlyLedger {
  const SubscriberMonthlyLedger({
    required this.subscriberId,
    required this.monthKey,
    required this.openingBalance,
    required this.monthlyCharges,
    required this.monthlyPayments,
    required this.adjustments,
    required this.closingBalance,
    required this.transactions,
  });

  final String subscriberId;
  final String monthKey;
  final double openingBalance;
  final double monthlyCharges;
  final double monthlyPayments;
  final double adjustments;
  final double closingBalance;
  final List<FinancialTransaction> transactions;

  double get totalCharges => monthlyCharges;
  double get totalPayments => monthlyPayments;
}

class SubscriberFinancialLedger {
  DatabaseReference get _ledgerRoot {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) {
      throw StateError('A signed-in user is required to access the ledger.');
    }
    return FirebaseDatabase.instance
        .ref('agents/$uid/financialLedger/subscribers');
  }

  DatabaseReference _subscriberTransactionsRef(String subscriberId) {
    if (subscriberId.trim().isEmpty) {
      throw ArgumentError.value(subscriberId, 'subscriberId');
    }
    return _ledgerRoot.child(subscriberId).child('transactions');
  }

  Future<FinancialTransaction> addTransaction({
    required String subscriberId,
    required DateTime date,
    required FinancialTransactionType type,
    required double amount,
    String note = '',
    String referenceId = '',
  }) async {
    if (!amount.isFinite || amount == 0) {
      throw ArgumentError.value(amount, 'amount');
    }
    if (type != FinancialTransactionType.adjustment && amount < 0) {
      throw ArgumentError.value(amount, 'amount', 'Must be positive.');
    }

    final transactionsRef = _subscriberTransactionsRef(subscriberId);
    final normalizedReferenceId = referenceId.trim();
    final id = normalizedReferenceId.isEmpty
        ? transactionsRef.push().key
        : 'ref_${base64Url.encode(utf8.encode(normalizedReferenceId)).replaceAll('=', '')}';
    if (id == null) throw StateError('Could not create a transaction id.');
    final transactionRef = transactionsRef.child(id);
    if (normalizedReferenceId.isNotEmpty) {
      final existing = await transactionRef.get();
      if (existing.value is Map) {
        return FinancialTransaction.fromJson(
          Map<String, dynamic>.from(existing.value as Map),
        );
      }
    }

    final transaction = FinancialTransaction(
      id: id,
      subscriberId: subscriberId,
      date: date,
      type: type,
      amount: amount,
      note: note,
      referenceId: normalizedReferenceId,
      monthKey: _monthKeyFor(date),
      createdAt: DateTime.now(),
      createdBy: FirebaseAuth.instance.currentUser!.uid,
    );
    await transactionRef.set(transaction.toJson());
    return transaction;
  }

  Future<List<FinancialTransaction>> getSubscriberTransactions(
    String subscriberId,
  ) async {
    final snapshot = await _subscriberTransactionsRef(subscriberId).get();
    final transactions = <FinancialTransaction>[];
    for (final child in snapshot.children) {
      final value = child.value;
      if (value is! Map) continue;
      final json = Map<String, dynamic>.from(value);
      json['id'] ??= child.key;
      transactions.add(FinancialTransaction.fromJson(json));
    }
    transactions.sort((a, b) {
      final dateOrder = a.date.compareTo(b.date);
      return dateOrder != 0 ? dateOrder : a.id.compareTo(b.id);
    });
    return transactions;
  }

  Future<Map<String, dynamic>> exportAllTransactions() async {
    final snapshot = await _ledgerRoot.get();
    final value = snapshot.value;
    if (value == null) return <String, dynamic>{};
    if (value is! Map) {
      throw const FormatException('Invalid subscriber financial ledger.');
    }
    final decoded = jsonDecode(jsonEncode(value));
    return Map<String, dynamic>.from(decoded as Map);
  }

  Future<void> replaceAllTransactions(
    Map<String, dynamic> transactions,
  ) async {
    await _ledgerRoot
        .set(transactions.isEmpty ? null : transactions)
        .timeout(const Duration(seconds: 30));
  }

  Future<double> getSubscriberOpeningBalance(
    String subscriberId,
    DateTime month,
  ) async {
    final selectedMonthKey = _monthKeyFor(month);
    final transactions = await getSubscriberTransactions(subscriberId);
    return transactions
        .where((transaction) => transaction.monthKey.compareTo(selectedMonthKey) < 0)
        .fold<double>(0, (balance, transaction) => balance + _balanceEffect(transaction));
  }

  Future<double> getSubscriberMonthlyCharges(
    String subscriberId,
    DateTime month,
  ) async {
    final transactions = await _getTransactionsInMonth(subscriberId, month);
    return transactions
        .where((transaction) => _isCharge(transaction.type))
        .fold<double>(0, (total, transaction) => total + transaction.amount);
  }

  Future<double> getSubscriberMonthlyPayments(
    String subscriberId,
    DateTime month,
  ) async {
    final transactions = await _getTransactionsInMonth(subscriberId, month);
    return transactions
        .where((transaction) => _isPayment(transaction.type))
        .fold<double>(0, (total, transaction) => total + transaction.amount);
  }

  Future<double> getSubscriberClosingBalance(
    String subscriberId,
    DateTime month,
  ) async {
    final ledger = await getSubscriberLedger(subscriberId, month);
    return ledger.closingBalance;
  }

  Future<SubscriberMonthlyLedger> getSubscriberLedger(
    String subscriberId,
    DateTime month,
  ) async {
    final transactions = await _getTransactionsInMonth(subscriberId, month);
    final openingBalance = await getSubscriberOpeningBalance(
      subscriberId,
      month,
    );
    final monthlyCharges = transactions
        .where((transaction) => _isCharge(transaction.type))
        .fold<double>(0, (total, transaction) => total + transaction.amount);
    final monthlyPayments = transactions
        .where((transaction) => _isPayment(transaction.type))
        .fold<double>(0, (total, transaction) => total + transaction.amount);
    final adjustments = transactions
        .where((transaction) => transaction.type == FinancialTransactionType.adjustment)
        .fold<double>(0, (total, transaction) => total + transaction.amount);

    return SubscriberMonthlyLedger(
      subscriberId: subscriberId,
      monthKey: _monthKeyFor(month),
      openingBalance: openingBalance,
      monthlyCharges: monthlyCharges,
      monthlyPayments: monthlyPayments,
      adjustments: adjustments,
      closingBalance:
          openingBalance + monthlyCharges - monthlyPayments + adjustments,
      transactions: transactions,
    );
  }

  Future<List<FinancialTransaction>> _getTransactionsInMonth(
    String subscriberId,
    DateTime month,
  ) async {
    final selectedMonthKey = _monthKeyFor(month);
    final transactions = await getSubscriberTransactions(subscriberId);
    return transactions
        .where((transaction) => transaction.monthKey == selectedMonthKey)
        .toList(growable: false);
  }

  static bool _isCharge(FinancialTransactionType type) =>
      type == FinancialTransactionType.openingBalance ||
      type == FinancialTransactionType.invoice ||
      type == FinancialTransactionType.activation ||
      type == FinancialTransactionType.debt ||
      type == FinancialTransactionType.expense;

  static bool _isPayment(FinancialTransactionType type) =>
      type == FinancialTransactionType.payment ||
      type == FinancialTransactionType.partialPayment ||
      type == FinancialTransactionType.credit;

  static double _balanceEffect(FinancialTransaction transaction) {
    if (transaction.type == FinancialTransactionType.activationCost ||
        transaction.type == FinancialTransactionType.companyDeposit) {
      return 0;
    }
    if (_isCharge(transaction.type)) return transaction.amount;
    if (_isPayment(transaction.type)) return -transaction.amount;
    return transaction.amount;
  }
}

String _monthKeyFor(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';