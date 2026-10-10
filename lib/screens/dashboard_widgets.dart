import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../models.dart';

String dashboardReferenceAssetPath(String path) =>
    kIsWeb ? Uri.encodeFull(path) : path;

class DebtOperationsMenu extends StatelessWidget {
  const DebtOperationsMenu({
    super.key,
    required this.subscriber,
    this.onEdit,
    this.onAddAmount,
    this.onPartialPayment,
    this.showLabel = false,
  });

  final Subscriber subscriber;
  final Future<void> Function(Subscriber)? onEdit;
  final Future<void> Function(Subscriber)? onAddAmount;
  final Future<void> Function(Subscriber)? onPartialPayment;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'العمليات',
      icon: showLabel ? null : const Icon(Icons.more_vert, color: Colors.blueGrey),
      child: showLabel
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Theme.of(context).dividerColor),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.more_vert, color: Colors.blueGrey),
                  const SizedBox(width: 4),
                  Text(
                    'العمليات',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            )
          : null,
      onSelected: (value) async {
        switch (value) {
          case 'edit':
            await onEdit?.call(subscriber);
          case 'add_amount':
            await onAddAmount?.call(subscriber);
          case 'partial_payment':
            await onPartialPayment?.call(subscriber);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Text(
            'مبلغ الاشتراك: ${subscriber.price.toStringAsFixed(0)} د.ع',
          ),
        ),
        PopupMenuItem<String>(
          enabled: false,
          child: Text('الواصل: ${subscriber.paid.toStringAsFixed(0)} د.ع'),
        ),
        PopupMenuItem<String>(
          enabled: false,
          child: Text(
            'المتبقي: ${subscriber.remaining.toStringAsFixed(0)} د.ع',
            style: const TextStyle(
              color: Colors.red,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const PopupMenuDivider(),
        if (onEdit != null)
          const PopupMenuItem<String>(
            value: 'edit',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.edit_outlined),
              title: Text('تعديل المبالغ'),
            ),
          ),
        if (onAddAmount != null)
          const PopupMenuItem<String>(
            value: 'add_amount',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.add_card_outlined),
              title: Text('إضافة مبلغ'),
            ),
          ),
        if (onPartialPayment != null)
          const PopupMenuItem<String>(
            value: 'partial_payment',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.payments_outlined),
              title: Text('تسديد جزء من المبلغ'),
            ),
          ),
      ],
    );
  }
}

class DashboardSectionTitle extends StatelessWidget {
  const DashboardSectionTitle({
    super.key,
    required this.title,
    required this.icon,
    this.color,
    this.fontSize = 16,
  });

  final String title;
  final IconData icon;
  final Color? color;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, color: color ?? const Color(0xFF2E7D32), size: 20),
        const SizedBox(width: 7),
        Text(
          title,
          style: TextStyle(
            color: colors.onSurface,
            fontSize: fontSize,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}

class DashboardMetricCard extends StatelessWidget {
  const DashboardMetricCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.assetName,
    required this.color,
    this.minHeight = 128,
  });

  final String title;
  final String subtitle;
  final String value;
  final String assetName;
  final Color color;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      constraints: BoxConstraints(minHeight: minHeight),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.green.shade100,
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: isDark ? 0.12 : 0.12),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            textDirection: TextDirection.ltr,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      color.withValues(alpha: 0.22),
                      color.withValues(alpha: 0.08),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Image.asset(
                  dashboardReferenceAssetPath(assetName),
                  width: 64,
                  height: 64,
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    value,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      color: color,
                      height: 1.1,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1F2937),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
