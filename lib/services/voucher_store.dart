/// نماذج ودوال نقية لمتجر الكروت (VoucherStore) في SAS — قابلة للاختبار بلا
/// شبكة. نداءات الشبكة نفسها في SasApiService تعيد استخدام جلسة SAS.
///
/// من الـ HAR (sas.otto-isp.com):
///   GET  /VoucherStore/index.php/api/auth      → رصيد المكتب
///   GET  /VoucherStore/index.php/api/purchase  → سجل الشراء
///   POST /VoucherStore/index.php/api/purchase  → {"quantity","cardValue"} (JSON صريح)
///        الرد: {"status":200,"message":"rsp_success"}
library;

/// واجهة ضيّقة لمتجر الكروت تُنفّذها SasApiService — تتيح اختبار شاشة الكروت
/// بمزوّد وهمي بلا شبكة.
abstract class VoucherApi {
  Future<double?> fetchVoucherBalance();
  Future<List<VoucherPurchase>> fetchVoucherPurchases();
  Future<String> buyVouchers({required int cardValue, required int quantity});
}

/// دفعة كروت مُشتراة كما يعيدها GET purchase.
class VoucherPurchase {
  const VoucherPurchase({
    required this.cardValue,
    required this.qty,
    required this.status,
    required this.createdAt,
  });

  final int cardValue;
  final int qty;

  /// 2 = مكتمل (تولّدت الكروت)، 0/1 = قيد التنفيذ.
  final int status;
  final String createdAt;

  bool get isComplete => status == 2;

  String get statusLabel => switch (status) {
    2 => 'مكتمل',
    0 || 1 => 'قيد التنفيذ',
    _ => 'غير معروف',
  };

  static int _asInt(dynamic v) {
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}'.trim()) ??
        double.tryParse('${v ?? ''}'.trim())?.toInt() ??
        0;
  }

  static VoucherPurchase? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    return VoucherPurchase(
      cardValue: _asInt(raw['card_value'] ?? raw['cardValue']),
      qty: _asInt(raw['qty'] ?? raw['quantity']),
      status: _asInt(raw['status']),
      createdAt: '${raw['created_at'] ?? raw['createdAt'] ?? ''}'.trim(),
    );
  }

  /// يقبل الرد كاملاً ({status,data:[...]}) أو قائمة مباشرة.
  static List<VoucherPurchase> parseList(dynamic response) {
    dynamic data = response;
    if (response is Map) data = response['data'];
    if (data is! List) return const [];
    final out = <VoucherPurchase>[];
    for (final item in data) {
      final p = fromMap(item);
      if (p != null) out.add(p);
    }
    return out;
  }
}

/// جسم طلب شراء الكروت — نصوص كما في الـ HAR تماماً.
Map<String, dynamic> voucherBuyBody({
  required int cardValue,
  required int quantity,
}) => {
  'quantity': '$quantity',
  'cardValue': '$cardValue',
};

/// الرصيد من رد auth: {"data":{"balance":"232000.000",...}} أو خريطة مباشرة.
double? parseVoucherBalance(dynamic response) {
  dynamic data = response;
  if (response is Map && response['data'] is Map) data = response['data'];
  if (data is! Map) return null;
  final raw = data['balance'];
  if (raw is num) return raw.toDouble();
  return double.tryParse('${raw ?? ''}'.trim().replaceAll(',', ''));
}

/// نجاح الشراء: status=200 ورسالة لا تحمل خطأ.
bool voucherBuySucceeded(dynamic response) {
  if (response is! Map) return false;
  final status = response['status'];
  final ok = status == 200 || status == '200' || status == true;
  if (!ok) return false;
  final msg = '${response['message'] ?? response['msg'] ?? ''}'.toLowerCase();
  if (msg.contains('error') || msg.contains('fail')) return false;
  return true;
}

/// رسالة عربية واضحة من رد الشراء (نجاحاً أو خطأً).
String voucherResultMessage(dynamic response) {
  final raw = response is Map
      ? '${response['message'] ?? response['msg'] ?? response['error'] ?? ''}'
      : '';
  final c = raw.toLowerCase();
  if (c.contains('success')) return 'تم شراء الكروت بنجاح';
  if (c.contains('insufficient') || c.contains('balance')) {
    return 'الرصيد غير كافٍ لإتمام الشراء';
  }
  if (c.contains('limit')) return 'تجاوزت الحد المسموح';
  if (raw.trim().isEmpty) return 'تعذّر إتمام الشراء';
  return raw;
}
