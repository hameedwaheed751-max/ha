enum FinanceEntryType {
  openingBalance('opening_balance'),
  subscriptionSale('subscription_sale'),
  purchase('purchase'),
  payment('payment'),
  correction('correction'),
  reversal('reversal');

  const FinanceEntryType(this.value);

  final String value;

  static FinanceEntryType fromValue(String value) {
    return FinanceEntryType.values.firstWhere(
      (type) => type.value == value,
      orElse: () => throw FormatException('Unknown entry type: $value'),
    );
  }
}

enum FinanceSaleKind {
  activation('activation'),
  extension('extension');

  const FinanceSaleKind(this.value);

  final String value;

  static FinanceSaleKind? fromValue(String? value) {
    for (final kind in FinanceSaleKind.values) {
      if (kind.value == value) return kind;
    }
    return null;
  }
}

enum ActivationSettlement {
  paidOnActivation('paid_on_activation', 'واصل عند التفعيل'),
  partialPayment('partial_payment', 'تسديد جزء'),
  fullDebt('full_debt', 'دين كامل المبلغ');

  const ActivationSettlement(this.value, this.label);

  final String value;
  final String label;

  static ActivationSettlement? fromValue(String? value) {
    for (final settlement in ActivationSettlement.values) {
      if (settlement.value == value) return settlement;
    }
    return null;
  }
}

enum FinancePolicyCode {
  invalidAmount,
  missingDescription,
  overpayment,
  excessiveCorrection,
  entryNotFound,
  entryNotReversible,
  entryAlreadyReversed,
  reversalLeavesCredit,
}

class FinancePolicyException implements Exception {
  const FinancePolicyException(this.code, this.message);

  final FinancePolicyCode code;
  final String message;

  @override
  String toString() => message;
}

class FinanceSubscriberRef {
  const FinanceSubscriberRef({
    required this.id,
    required this.user,
    required this.name,
  });

  final String id;
  final String user;
  final String name;
}

/// مبالغ الدينار العراقي أعداد صحيحة. موجبة دائماً، ما عدا التصحيح والإلغاء
/// فإشارتهما تحدد اتجاه أثرهما على الرصيد.
class FinanceEntry {
  const FinanceEntry({
    required this.id,
    required this.operationId,
    required this.subscriberId,
    required this.subscriberUser,
    required this.subscriberName,
    required this.type,
    required this.amount,
    required this.at,
    required this.createdBy,
    this.note = '',
    this.packageName = '',
    this.saleKind,
    this.settlement,
    this.sasCost = 0,
    this.receiptNumber,
    this.reversesEntryId = '',
  });

  final String id;
  final String operationId;
  final String subscriberId;
  final String subscriberUser;
  final String subscriberName;
  final FinanceEntryType type;
  final int amount;
  final DateTime at;
  final String createdBy;
  final String note;
  final String packageName;
  final FinanceSaleKind? saleKind;
  final ActivationSettlement? settlement;
  final int sasCost;
  final int? receiptNumber;
  final String reversesEntryId;

  int get balanceEffect =>
      type == FinanceEntryType.payment ? -amount : amount;

  Map<String, dynamic> toJson() => {
    'id': id,
    'operationId': operationId,
    'subscriberId': subscriberId,
    'subscriberUser': subscriberUser,
    'subscriberName': subscriberName,
    'type': type.value,
    'amount': amount,
    'at': at.toUtc().toIso8601String(),
    'createdBy': createdBy,
    if (note.isNotEmpty) 'note': note,
    if (packageName.isNotEmpty) 'packageName': packageName,
    if (saleKind != null) 'saleKind': saleKind!.value,
    if (settlement != null) 'settlement': settlement!.value,
    if (sasCost != 0) 'sasCost': sasCost,
    if (receiptNumber != null) 'receiptNumber': receiptNumber,
    if (reversesEntryId.isNotEmpty) 'reversesEntryId': reversesEntryId,
  };

  factory FinanceEntry.fromJson(Map<String, dynamic> json) => FinanceEntry(
    id: json['id'].toString(),
    operationId: json['operationId'].toString(),
    subscriberId: json['subscriberId'].toString(),
    subscriberUser: (json['subscriberUser'] ?? '').toString(),
    subscriberName: (json['subscriberName'] ?? '').toString(),
    type: FinanceEntryType.fromValue(json['type'].toString()),
    amount: (json['amount'] as num).toInt(),
    at: DateTime.parse(json['at'].toString()).toLocal(),
    createdBy: (json['createdBy'] ?? '').toString(),
    note: (json['note'] ?? '').toString(),
    packageName: (json['packageName'] ?? '').toString(),
    saleKind: FinanceSaleKind.fromValue(json['saleKind']?.toString()),
    settlement: ActivationSettlement.fromValue(json['settlement']?.toString()),
    sasCost: (json['sasCost'] as num?)?.toInt() ?? 0,
    receiptNumber: (json['receiptNumber'] as num?)?.toInt(),
    reversesEntryId: (json['reversesEntryId'] ?? '').toString(),
  );
}

class FinanceOpenItem {
  const FinanceOpenItem({required this.entry, required this.outstanding});

  final FinanceEntry entry;
  final int outstanding;
}

Set<String> _reversedEntryIds(Iterable<FinanceEntry> entries) => {
  for (final entry in entries)
    if (entry.type == FinanceEntryType.reversal) entry.reversesEntryId,
};

List<FinanceEntry> _activeEntries(Iterable<FinanceEntry> entries) {
  final reversed = _reversedEntryIds(entries);
  return entries
      .where(
        (entry) =>
            entry.type != FinanceEntryType.reversal &&
            !reversed.contains(entry.id),
      )
      .toList()
    ..sort((a, b) {
      final dateOrder = a.at.compareTo(b.at);
      return dateOrder != 0 ? dateOrder : a.id.compareTo(b.id);
    });
}

class FinanceAccount {
  FinanceAccount._(this.balance, this.openItems);

  factory FinanceAccount.fromEntries(Iterable<FinanceEntry> entries) {
    final active = _activeEntries(entries);
    final balance = active.fold<int>(
      0,
      (total, entry) => total + entry.balanceEffect,
    );
    var credits = active
        .where((entry) => entry.balanceEffect < 0)
        .fold<int>(0, (total, entry) => total - entry.balanceEffect);
    final openItems = <FinanceOpenItem>[];
    for (final entry in active.where((entry) => entry.balanceEffect > 0)) {
      final covered = credits < entry.balanceEffect
          ? credits
          : entry.balanceEffect;
      credits -= covered;
      final outstanding = entry.balanceEffect - covered;
      if (outstanding > 0) {
        openItems.add(FinanceOpenItem(entry: entry, outstanding: outstanding));
      }
    }
    return FinanceAccount._(balance, List.unmodifiable(openItems));
  }

  final int balance;
  final List<FinanceOpenItem> openItems;

  DateTime? get oldestOpenAt =>
      openItems.isEmpty ? null : openItems.first.entry.at;

  int? debtAgeInDays(DateTime now) => oldestOpenAt == null
      ? null
      : now.difference(oldestOpenAt!).inDays;
}

class FinancePurchaseInput {
  const FinancePurchaseInput({
    required this.description,
    required this.amount,
    this.paidAmount = 0,
  });

  final String description;
  final int amount;
  final int paidAmount;
}

class FinanceSaleInput {
  const FinanceSaleInput({
    required this.packageName,
    required this.salePrice,
    required this.settlement,
    this.sasCost = 0,
    this.partialAmount = 0,
    this.saleKind = FinanceSaleKind.activation,
    this.purchase,
  });

  final String packageName;
  final int salePrice;
  final ActivationSettlement settlement;
  final int sasCost;
  final int partialAmount;
  final FinanceSaleKind saleKind;
  final FinancePurchaseInput? purchase;

  int get subscriptionPaid => switch (settlement) {
    ActivationSettlement.paidOnActivation => salePrice,
    ActivationSettlement.partialPayment => partialAmount,
    ActivationSettlement.fullDebt => 0,
  };

  int get collected => subscriptionPaid + (purchase?.paidAmount ?? 0);
}

class FinancePolicy {
  const FinancePolicy._();

  static void _requirePositive(int amount, String label) {
    if (amount <= 0) {
      throw FinancePolicyException(
        FinancePolicyCode.invalidAmount,
        '$label يجب أن يكون أكبر من صفر',
      );
    }
  }

  static String _requireText(String value, String message) {
    final text = value.trim();
    if (text.isEmpty) {
      throw FinancePolicyException(
        FinancePolicyCode.missingDescription,
        message,
      );
    }
    return text;
  }

  static void _validatePurchase(FinancePurchaseInput purchase) {
    _requireText(purchase.description, 'اكتب وصف المشتريات');
    _requirePositive(purchase.amount, 'مبلغ المشتريات');
    if (purchase.paidAmount < 0 || purchase.paidAmount > purchase.amount) {
      throw const FinancePolicyException(
        FinancePolicyCode.invalidAmount,
        'واصل المشتريات يجب أن يكون بين صفر ومبلغها',
      );
    }
  }

  static void _validateSale(FinanceSaleInput sale) {
    _requirePositive(sale.salePrice, 'سعر البيع');
    if (sale.sasCost < 0) {
      throw const FinancePolicyException(
        FinancePolicyCode.invalidAmount,
        'كلفة SAS لا يمكن أن تكون سالبة',
      );
    }
    if (sale.settlement == ActivationSettlement.partialPayment &&
        (sale.partialAmount <= 0 || sale.partialAmount >= sale.salePrice)) {
      throw const FinancePolicyException(
        FinancePolicyCode.invalidAmount,
        'تسديد الجزء يجب أن يكون بين صفر وسعر البيع',
      );
    }
    final purchase = sale.purchase;
    if (purchase != null) _validatePurchase(purchase);
  }

  static FinanceEntry _entry({
    required String operationId,
    required int index,
    required FinanceSubscriberRef subscriber,
    required FinanceEntryType type,
    required int amount,
    required DateTime at,
    required String createdBy,
    String note = '',
    String packageName = '',
    FinanceSaleKind? saleKind,
    ActivationSettlement? settlement,
    int sasCost = 0,
    int? receiptNumber,
    String reversesEntryId = '',
  }) => FinanceEntry(
    id: '${operationId}_$index',
    operationId: operationId,
    subscriberId: subscriber.id,
    subscriberUser: subscriber.user,
    subscriberName: subscriber.name,
    type: type,
    amount: amount,
    at: at,
    createdBy: createdBy,
    note: note,
    packageName: packageName,
    saleKind: saleKind,
    settlement: settlement,
    sasCost: sasCost,
    receiptNumber: receiptNumber,
    reversesEntryId: reversesEntryId,
  );

  static int _requireReceipt(int? receiptNumber) {
    if (receiptNumber == null) {
      throw ArgumentError.notNull('receiptNumber');
    }
    return receiptNumber;
  }

  static List<FinanceEntry> sale({
    required String operationId,
    required FinanceSubscriberRef subscriber,
    required FinanceSaleInput input,
    required DateTime at,
    required String createdBy,
    int? receiptNumber,
  }) {
    _validateSale(input);
    final purchase = input.purchase;
    var index = 0;
    return [
      _entry(
        operationId: operationId,
        index: index++,
        subscriber: subscriber,
        type: FinanceEntryType.subscriptionSale,
        amount: input.salePrice,
        at: at,
        createdBy: createdBy,
        packageName: input.packageName.trim(),
        saleKind: input.saleKind,
        settlement: input.settlement,
        sasCost: input.sasCost,
      ),
      if (purchase != null)
        _entry(
          operationId: operationId,
          index: index++,
          subscriber: subscriber,
          type: FinanceEntryType.purchase,
          amount: purchase.amount,
          at: at,
          createdBy: createdBy,
          note: purchase.description.trim(),
        ),
      if (input.collected > 0)
        _entry(
          operationId: operationId,
          index: index++,
          subscriber: subscriber,
          type: FinanceEntryType.payment,
          amount: input.collected,
          at: at,
          createdBy: createdBy,
          note: input.settlement.label,
          receiptNumber: _requireReceipt(receiptNumber),
        ),
    ];
  }

  static List<FinanceEntry> purchase({
    required String operationId,
    required FinanceSubscriberRef subscriber,
    required FinancePurchaseInput input,
    required DateTime at,
    required String createdBy,
    int? receiptNumber,
  }) {
    _validatePurchase(input);
    return [
      _entry(
        operationId: operationId,
        index: 0,
        subscriber: subscriber,
        type: FinanceEntryType.purchase,
        amount: input.amount,
        at: at,
        createdBy: createdBy,
        note: input.description.trim(),
      ),
      if (input.paidAmount > 0)
        _entry(
          operationId: operationId,
          index: 1,
          subscriber: subscriber,
          type: FinanceEntryType.payment,
          amount: input.paidAmount,
          at: at,
          createdBy: createdBy,
          note: 'واصل مشتريات',
          receiptNumber: _requireReceipt(receiptNumber),
        ),
    ];
  }

  static List<FinanceEntry> payment({
    required String operationId,
    required FinanceSubscriberRef subscriber,
    required List<FinanceEntry> existing,
    required int amount,
    required DateTime at,
    required String createdBy,
    int? receiptNumber,
    String note = '',
  }) {
    _requirePositive(amount, 'مبلغ الدفعة');
    final balance = FinanceAccount.fromEntries(existing).balance;
    if (amount > balance) {
      throw FinancePolicyException(
        FinancePolicyCode.overpayment,
        'الدفعة أكبر من الدين. الحد الأعلى $balance د.ع',
      );
    }
    return [
      _entry(
        operationId: operationId,
        index: 0,
        subscriber: subscriber,
        type: FinanceEntryType.payment,
        amount: amount,
        at: at,
        createdBy: createdBy,
        note: note.trim(),
        receiptNumber: _requireReceipt(receiptNumber),
      ),
    ];
  }

  static List<FinanceEntry> correction({
    required String operationId,
    required FinanceSubscriberRef subscriber,
    required List<FinanceEntry> existing,
    required int amount,
    required String reason,
    required DateTime at,
    required String createdBy,
  }) {
    final text = _requireText(reason, 'اكتب سبب التصحيح');
    if (amount == 0) {
      throw const FinancePolicyException(
        FinancePolicyCode.invalidAmount,
        'مبلغ التصحيح لا يمكن أن يكون صفراً',
      );
    }
    final balance = FinanceAccount.fromEntries(existing).balance;
    if (balance + amount < 0) {
      throw FinancePolicyException(
        FinancePolicyCode.excessiveCorrection,
        'التخفيض أكبر من الدين. الحد الأعلى $balance د.ع',
      );
    }
    return [
      _entry(
        operationId: operationId,
        index: 0,
        subscriber: subscriber,
        type: FinanceEntryType.correction,
        amount: amount,
        at: at,
        createdBy: createdBy,
        note: text,
      ),
    ];
  }

  static List<FinanceEntry> reversal({
    required String operationId,
    required FinanceSubscriberRef subscriber,
    required List<FinanceEntry> existing,
    required String entryId,
    required String reason,
    required DateTime at,
    required String createdBy,
  }) {
    final text = _requireText(reason, 'اكتب سبب الإلغاء');
    FinanceEntry? target;
    for (final entry in existing) {
      if (entry.id == entryId) target = entry;
    }
    if (target == null) {
      throw const FinancePolicyException(
        FinancePolicyCode.entryNotFound,
        'العملية غير موجودة',
      );
    }
    if (target.type == FinanceEntryType.reversal) {
      throw const FinancePolicyException(
        FinancePolicyCode.entryNotReversible,
        'لا يمكن إلغاء عملية إلغاء',
      );
    }
    if (_reversedEntryIds(existing).contains(entryId)) {
      throw const FinancePolicyException(
        FinancePolicyCode.entryAlreadyReversed,
        'أُلغيت هذه العملية سابقاً',
      );
    }
    final balance = FinanceAccount.fromEntries(existing).balance;
    if (balance - target.balanceEffect < 0) {
      throw const FinancePolicyException(
        FinancePolicyCode.reversalLeavesCredit,
        'ألغِ الدفعات المرتبطة بهذه العملية أولاً',
      );
    }
    return [
      _entry(
        operationId: operationId,
        index: 0,
        subscriber: subscriber,
        type: FinanceEntryType.reversal,
        amount: -target.balanceEffect,
        at: at,
        createdBy: createdBy,
        note: text,
        reversesEntryId: entryId,
      ),
    ];
  }
}

/// [from] داخل الفترة و[to] خارجها، لذلك لا يتداخل يومان ولا شهران.
class FinancePeriod {
  const FinancePeriod({required this.from, required this.to});

  factory FinancePeriod.day(DateTime date) => FinancePeriod(
    from: DateTime(date.year, date.month, date.day),
    to: DateTime(date.year, date.month, date.day + 1),
  );

  factory FinancePeriod.month(DateTime date) => FinancePeriod(
    from: DateTime(date.year, date.month),
    to: DateTime(date.year, date.month + 1),
  );

  final DateTime from;
  final DateTime to;

  bool contains(DateTime date) => !date.isBefore(from) && date.isBefore(to);
}

enum FinanceMovementType {
  collectedOnActivation('واصل من التفعيل'),
  collectedOnPurchase('واصل المشتريات'),
  debtRepayment('تسديد دين'),
  debtAdded('دين مضاف'),
  debtReduced('تخفيض دين');

  const FinanceMovementType(this.label);

  final String label;
}

/// حركة واحدة كما يراها الوكيل. البيع والدفعة في عملية واحدة لا يظهران
/// كحركتين: المدفوع واصل، وما لم يُدفع فقط يصبح ديناً مضافاً.
class FinanceMovement {
  const FinanceMovement({
    required this.type,
    required this.amount,
    required this.at,
    required this.operationId,
    required this.subscriberId,
    required this.subscriberUser,
    required this.subscriberName,
    this.note = '',
    this.receiptNumber,
  });

  final FinanceMovementType type;
  final int amount;
  final DateTime at;
  final String operationId;
  final String subscriberId;
  final String subscriberUser;
  final String subscriberName;
  final String note;
  final int? receiptNumber;

  static List<FinanceMovement> forPeriod(
    Iterable<FinanceEntry> entries,
    FinancePeriod period,
  ) {
    final operations = <String, List<FinanceEntry>>{};
    for (final entry in _activeEntries(entries)) {
      if (!period.contains(entry.at)) continue;
      operations.putIfAbsent(entry.operationId, () => []).add(entry);
    }
    return [
      for (final operation in operations.values) ..._fromOperation(operation),
    ];
  }

  static List<FinanceMovement> _fromOperation(List<FinanceEntry> operation) {
    final first = operation.first;
    FinanceMovement movement(
      FinanceMovementType type,
      int amount, {
      String note = '',
      int? receiptNumber,
    }) => FinanceMovement(
      type: type,
      amount: amount,
      at: first.at,
      operationId: first.operationId,
      subscriberId: first.subscriberId,
      subscriberUser: first.subscriberUser,
      subscriberName: first.subscriberName,
      note: note,
      receiptNumber: receiptNumber,
    );

    final movements = <FinanceMovement>[];
    var charged = 0;
    var paid = 0;
    var description = '';
    var hasSale = false;
    int? receiptNumber;
    for (final entry in operation) {
      switch (entry.type) {
        case FinanceEntryType.subscriptionSale:
          hasSale = true;
          charged += entry.amount;
          description = entry.packageName;
        case FinanceEntryType.purchase:
          charged += entry.amount;
          if (description.isEmpty) description = entry.note;
        case FinanceEntryType.payment:
          paid += entry.amount;
          receiptNumber = entry.receiptNumber;
        case FinanceEntryType.correction:
          movements.add(
            movement(
              entry.amount > 0
                  ? FinanceMovementType.debtAdded
                  : FinanceMovementType.debtReduced,
              entry.amount.abs(),
              note: entry.note,
            ),
          );
        case FinanceEntryType.openingBalance:
        case FinanceEntryType.reversal:
          break;
      }
    }

    final paidOnCharge = paid < charged ? paid : charged;
    if (paidOnCharge > 0) {
      movements.add(
        movement(
          hasSale
              ? FinanceMovementType.collectedOnActivation
              : FinanceMovementType.collectedOnPurchase,
          paidOnCharge,
          note: description,
          receiptNumber: receiptNumber,
        ),
      );
    }
    if (paid > paidOnCharge) {
      movements.add(
        movement(
          FinanceMovementType.debtRepayment,
          paid - paidOnCharge,
          receiptNumber: receiptNumber,
        ),
      );
    }
    if (charged > paid) {
      movements.add(
        movement(
          FinanceMovementType.debtAdded,
          charged - paid,
          note: description,
        ),
      );
    }
    return movements;
  }
}

/// تُحسب من حركات الفترة نفسها ولا تُخزن، فكل شهر يبدأ من صفر تلقائياً
/// وتتطابق مجاميع الأيام مع مجموع الشهر.
class FinanceSummary {
  const FinanceSummary({
    required this.subscriptionSales,
    required this.purchases,
    required this.collectedOnActivation,
    required this.collectedOnPurchases,
    required this.debtRepayments,
    required this.debtAdded,
    required this.debtReduced,
    required this.sasCost,
    required this.activationCount,
    required this.extensionCount,
  });

  final int subscriptionSales;
  final int purchases;
  final int collectedOnActivation;
  final int collectedOnPurchases;
  final int debtRepayments;
  final int debtAdded;
  final int debtReduced;
  final int sasCost;
  final int activationCount;
  final int extensionCount;

  int get collected =>
      collectedOnActivation + collectedOnPurchases + debtRepayments;
  int get totalSales => subscriptionSales + purchases;
  int get subscriptionProfit => subscriptionSales - sasCost;

  factory FinanceSummary.forPeriod(
    Iterable<FinanceEntry> entries,
    FinancePeriod period,
  ) {
    var subscriptionSales = 0;
    var purchases = 0;
    var sasCost = 0;
    var activationCount = 0;
    var extensionCount = 0;
    for (final entry in _activeEntries(entries)) {
      if (!period.contains(entry.at)) continue;
      if (entry.type == FinanceEntryType.purchase) {
        purchases += entry.amount;
      } else if (entry.type == FinanceEntryType.subscriptionSale) {
        subscriptionSales += entry.amount;
        sasCost += entry.sasCost;
        if (entry.saleKind == FinanceSaleKind.extension) {
          extensionCount++;
        } else {
          activationCount++;
        }
      }
    }

    int totalOf(FinanceMovementType type, List<FinanceMovement> movements) =>
        movements
            .where((movement) => movement.type == type)
            .fold<int>(0, (total, movement) => total + movement.amount);

    final movements = FinanceMovement.forPeriod(entries, period);
    return FinanceSummary(
      subscriptionSales: subscriptionSales,
      purchases: purchases,
      collectedOnActivation: totalOf(
        FinanceMovementType.collectedOnActivation,
        movements,
      ),
      collectedOnPurchases: totalOf(
        FinanceMovementType.collectedOnPurchase,
        movements,
      ),
      debtRepayments: totalOf(FinanceMovementType.debtRepayment, movements),
      debtAdded: totalOf(FinanceMovementType.debtAdded, movements),
      debtReduced: totalOf(FinanceMovementType.debtReduced, movements),
      sasCost: sasCost,
      activationCount: activationCount,
      extensionCount: extensionCount,
    );
  }
}
