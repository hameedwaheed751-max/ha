import '../models.dart';
import '../sas_api_service.dart';

/// رقم من رد الساس مهما كان شكله: 250000 أو "250,000.00" أو "250,000 IQD"
/// أو {value: ...}.
double? parseSasAmount(dynamic raw) {
  if (raw is num) return raw.toDouble();
  if (raw is Map) {
    return parseSasAmount(raw['value'] ?? raw['amount'] ?? raw['balance']);
  }
  final match = RegExp(r'-?\d[\d,]*(?:\.\d+)?').firstMatch('${raw ?? ''}');
  return match == null ? null : double.tryParse(match[0]!.replaceAll(',', ''));
}

/// رصيد ساس واحد من ساسات الوكيل.
class SasWallet {
  const SasWallet({
    required this.account,
    this.balance,
    this.rewardPoints,
    this.error,
  });

  final SasSettings account;
  final double? balance;
  final double? rewardPoints;
  final String? error;

  String get title {
    final company = account.company.trim();
    return company.isEmpty
        ? account.displayName
        : '$company — ${account.displayName}';
  }
}

/// أرصدة كل الساسات المربوطة، لا الأساسي وحده.
class SasWallets {
  const SasWallets(this.items);

  final List<SasWallet> items;

  bool get isEmpty => items.isEmpty;
  bool get several => items.length > 1;

  /// مجموع ما قُرئ؛ null إن لم يُقرأ أي رصيد.
  double? get totalBalance => _sum(items.map((w) => w.balance));
  double? get totalRewardPoints => _sum(items.map((w) => w.rewardPoints));

  static double? _sum(Iterable<double?> values) {
    final known = values.whereType<double>().toList();
    if (known.isEmpty) return null;
    return known.fold<double>(0, (sum, v) => sum + v);
  }

  /// رصيد الساس يُقرأ عبر بيانات مشترك منه، فنختار أول مشترك له رقم فيه.
  static int? userIdIn(Iterable<Subscriber> subscribers, String account) {
    for (final s in subscribers) {
      if (s.isFormer) continue;
      var raw = s.idIn(account) ?? '';
      // مشتركون قدامى من الأساسي حُفظ رقمهم في بيانات الساس فقط.
      if (raw.isEmpty && account.isEmpty && s.source == 'sas') {
        raw = '${s.sasData['id'] ?? s.sasData['user_id'] ?? ''}';
      }
      final id = int.tryParse(raw.trim());
      if (id != null) return id;
    }
    return null;
  }

  static Future<SasWallets> load({
    Future<List<SasSettings>> Function()? loadAccounts,
    Future<Map<String, dynamic>> Function(SasSettings account, int userId)?
    fetchWallet,
    Iterable<Subscriber>? subscribers,
  }) async {
    final accounts = await (loadAccounts ?? SasSettings.loadAll)();
    final people = subscribers ?? AppStore.subscribers;
    final fetch = fetchWallet ?? _fetchWallet;
    final items = await Future.wait(
      accounts.map((account) async {
        if (account.needsPassword) {
          return SasWallet(
            account: account,
            error: account.missingPasswordMessage,
          );
        }
        final userId = userIdIn(people, account.accountId);
        if (userId == null) {
          return SasWallet(
            account: account,
            error: 'زامن هذا الساس أولاً ليُقرأ رصيده',
          );
        }
        try {
          final wallet = await fetch(account, userId);
          return SasWallet(
            account: account,
            balance: parseSasAmount(wallet['balance']),
            rewardPoints: parseSasAmount(wallet['reward_points']),
          );
        } catch (e) {
          return SasWallet(account: account, error: '$e');
        }
      }),
    );
    return SasWallets(items);
  }

  static Future<Map<String, dynamic>> _fetchWallet(
    SasSettings account,
    int userId,
  ) async {
    final api = SasApiService(account);
    try {
      return await api.fetchDashboardWallet(userId);
    } finally {
      api.dispose();
    }
  }
}
