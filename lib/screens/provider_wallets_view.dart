import 'package:flutter/material.dart';

import '../models.dart';
import '../services/provider_wallets.dart';

/// لوحة أرصدة الشركات في الداشبورد: صف لكل شركة مربوطة، بتنسيق موحّد،
/// يعرض رصيد كل مزوّد من مصدره (RADIUS مع نقاطه، إيرثلنك، فايبر اكس، FTTH).
class ProviderWalletsView extends StatelessWidget {
  const ProviderWalletsView({
    super.key,
    required this.wallets,
    this.loading = false,
  });

  final ProviderWallets wallets;
  final bool loading;

  static Color _color(WalletProvider p) => switch (p) {
    WalletProvider.radius => const Color(0xFF00796B),
    WalletProvider.earthlink => const Color(0xFF0D6EFD),
    WalletProvider.fiberx => const Color(0xFF7446D7),
    WalletProvider.ftth => const Color(0xFF159447),
  };

  static IconData _icon(WalletProvider p) => switch (p) {
    WalletProvider.radius => Icons.dns_rounded,
    WalletProvider.earthlink => Icons.public_rounded,
    WalletProvider.fiberx => Icons.router_rounded,
    WalletProvider.ftth => Icons.cable_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (wallets.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          loading ? 'جارٍ قراءة الأرصدة…' : 'لا توجد شركات مربوطة بعد',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final w in wallets.items) _tile(context, w)],
    );
  }

  Widget _tile(BuildContext context, ProviderWallet w) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = _color(w.provider);
    final valueText = w.hasBalance
        ? moneyText(w.balance!)
        : (w.note != null ? 'غير متاح' : (w.error != null ? 'تعذّر' : '--'));

    return Container(
      key: ValueKey('wallet-${w.provider.name}-${w.company}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(_icon(w.provider), size: 19, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  w.company,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: scheme.onSurface,
                  ),
                ),
                if (w.rewardPoints != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'النقاط التشجيعية: ${moneyText(w.rewardPoints!)}',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (w.note != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      w.note!,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (w.note == null && w.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'تعذّر قراءة الرصيد',
                      style: TextStyle(fontSize: 11, color: scheme.error),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            valueText,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 15,
              color: w.hasBalance ? color : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
