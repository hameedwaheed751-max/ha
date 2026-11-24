import 'package:flutter/foundation.dart' show kIsWeb;

import '../earthlink_mobile_service.dart';
import '../earthlink_reseller_service.dart';
import '../fiberx_service.dart';
import '../sas_project_national_service.dart';
import 'sas_wallets.dart';

/// الشركة التي يعود لها الرصيد، لتحديد مصدره وتنسيقه.
enum WalletProvider { radius, earthlink, fiberx, ftth }

/// رصيد شركة واحدة مربوطة، كما يظهر في لوحة أرصدة الداشبورد.
class ProviderWallet {
  const ProviderWallet({
    required this.provider,
    required this.company,
    this.balance,
    this.rewardPoints,
    this.error,
    this.note,
  });

  final WalletProvider provider;

  /// العنوان المعروض (اسم الشركة/الساس).
  final String company;

  /// الرصيد المقروء؛ null إن تعذّر أو لم يتوفّر.
  final double? balance;

  /// النقاط التشجيعية — لـRADIUS فقط.
  final double? rewardPoints;

  /// سبب تعذّر القراءة (خطأ اتصال/جلسة).
  final String? error;

  /// سبب عدم التوفّر المتوقّع (لا نقطة التقاط بعد، أو يُقرأ من أندرويد).
  final String? note;

  bool get hasBalance => balance != null;
}

/// أرصدة كل الشركات المربوطة (RADIUS + إيرثلنك + فايبر اكس + FTTH)، كلٌّ من
/// مصدره الخاص. تحلّ محل عرض رصيد الساس وحده في الداشبورد.
class ProviderWallets {
  const ProviderWallets(this.items);

  final List<ProviderWallet> items;

  bool get isEmpty => items.isEmpty;
  bool get several => items.length > 1;

  /// يقرأ أرصدة كل المزوّدين المربوطين بالتوازي. المحمّلات قابلة للحقن
  /// للاختبار؛ القيم الافتراضية تقرأ الإعدادات الحقيقية وتسجّل الدخول.
  static Future<ProviderWallets> load({
    Future<SasWallets> Function()? radius,
    Future<ProviderWallet?> Function()? earthlink,
    Future<ProviderWallet?> Function()? fiberx,
    Future<ProviderWallet?> Function()? ftth,
  }) async {
    final radiusFuture = (radius ?? SasWallets.load)();
    final earthlinkFuture = (earthlink ?? _loadEarthlink)();
    final fiberxFuture = (fiberx ?? _loadFiberx)();
    final ftthFuture = (ftth ?? _loadFtth)();

    final radiusWallets = await radiusFuture;
    final el = await earthlinkFuture;
    final fx = await fiberxFuture;
    final ft = await ftthFuture;

    return ProviderWallets([
      for (final w in radiusWallets.items) _fromSas(w),
      ?el,
      ?fx,
      ?ft,
    ]);
  }

  static ProviderWallet _fromSas(SasWallet w) => ProviderWallet(
    provider: WalletProvider.radius,
    company: w.title,
    balance: w.balance,
    rewardPoints: w.rewardPoints,
    error: w.error,
  );

  /// رصيد الوكيل لدى إيرثلنك عبر تطبيق الجوال (بلا VPN).
  static Future<ProviderWallet?> _loadEarthlink() async {
    final settings = await EarthlinkResellerSettings.load();
    if (!settings.isComplete) return null;
    const company = 'إيرثلنك';
    // API إيرثلنك يرفض من المتصفح (CORS)؛ يُقرأ من تطبيق أندرويد.
    if (kIsWeb) {
      return const ProviderWallet(
        provider: WalletProvider.earthlink,
        company: company,
        note: 'يُقرأ من تطبيق أندرويد',
      );
    }
    final service = EarthlinkMobileService.fromSettings(settings);
    try {
      final balance = await service.fetchBalance();
      return ProviderWallet(
        provider: WalletProvider.earthlink,
        company: company,
        balance: balance,
      );
    } catch (e) {
      return ProviderWallet(
        provider: WalletProvider.earthlink,
        company: company,
        error: '$e',
      );
    } finally {
      service.dispose();
    }
  }

  /// فايبر اكس: لا نقطة التقاط لرصيد محفظة الوكيل بعد، فنعرض «غير متاح».
  static Future<ProviderWallet?> _loadFiberx() async {
    final settings = await FiberXSettings.load();
    if (!settings.isComplete) return null;
    return const ProviderWallet(
      provider: WalletProvider.fiberx,
      company: 'فايبر اكس',
      note: 'غير متاح — يلزم التقاط نقطة الرصيد',
    );
  }

  /// رصيد محفظة الوكيل في FTTH (partner wallet).
  static Future<ProviderWallet?> _loadFtth() async {
    final settings = await SasProjectNationalSettings.load();
    if (!settings.isComplete) return null;
    const company = 'FTTH';
    // المتصفح يمنع الاتصال بموقع FTTH (CORS)؛ يُقرأ من تطبيق أندرويد.
    if (kIsWeb) {
      return const ProviderWallet(
        provider: WalletProvider.ftth,
        company: company,
        note: 'يُقرأ من تطبيق أندرويد',
      );
    }
    final service = SasProjectNationalService(settings);
    try {
      final balance = await service.fetchOwnPartnerBalance();
      return ProviderWallet(
        provider: WalletProvider.ftth,
        company: company,
        balance: balance,
      );
    } catch (e) {
      return ProviderWallet(
        provider: WalletProvider.ftth,
        company: company,
        error: '$e',
      );
    } finally {
      service.dispose();
    }
  }
}
