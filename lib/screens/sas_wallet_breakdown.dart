import 'package:flutter/material.dart';

import '../models.dart';
import '../services/sas_wallets.dart';

/// رصيد كل ساس تحت المجموع، حين يربط الوكيل أكثر من ساس.
class SasWalletBreakdown extends StatelessWidget {
  const SasWalletBreakdown({
    super.key,
    required this.wallets,
    this.onDark = false,
  });

  final SasWallets wallets;

  /// داخل بطاقة ملونة: نص أبيض.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final muted = onDark
        ? Colors.white70
        : Theme.of(context).colorScheme.onSurfaceVariant;
    final strong = onDark
        ? Colors.white
        : Theme.of(context).colorScheme.onSurface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final wallet in wallets.items)
          Padding(
            key: ValueKey('wallet-${wallet.account.accountId}'),
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Icon(Icons.dns_rounded, size: 14, color: muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    wallet.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: wallet.error ?? '',
                  child: Text(
                    wallet.balance != null
                        ? moneyText(wallet.balance!)
                        : 'غير متاح',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: wallet.balance != null ? strong : muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
