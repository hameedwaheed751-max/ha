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
    this.onCorrectCarriedDebt,
    this.showLabel = false,
  });

  final Subscriber subscriber;
  final Future<void> Function(Subscriber)? onEdit;
  final Future<void> Function(Subscriber)? onAddAmount;
  final Future<void> Function(Subscriber)? onPartialPayment;
  final Future<void> Function(Subscriber)? onCorrectCarriedDebt;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'العمليات',
      icon: showLabel
          ? null
          : const Icon(Icons.more_vert, color: Colors.blueGrey),
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
          case 'correct_carried':
            await onCorrectCarriedDebt?.call(subscriber);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          child: Text('مبلغ الاشتراك: ${moneyText(subscriber.price)}'),
        ),
        PopupMenuItem<String>(
          enabled: false,
          child: Text('الواصل: ${moneyText(subscriber.paid)}'),
        ),
        PopupMenuItem<String>(
          enabled: false,
          child: Text(
            'المتبقي: ${moneyText(subscriber.remaining)}',
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
        if (onCorrectCarriedDebt != null && subscriber.carriedDebt > 0.0001)
          const PopupMenuItem<String>(
            value: 'correct_carried',
            child: ListTile(
              dense: true,
              leading: Icon(Icons.rule_rounded),
              title: Text('تصحيح الدين المرحّل'),
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

class DashboardStatCard extends StatelessWidget {
  const DashboardStatCard({
    super.key,
    required this.label,
    required this.value,
    required this.assetName,
    required this.color,
    this.caption,
    this.tinted = true,
    this.iconSize = 48,
    this.onTap,
  });

  final String label;
  final String value;
  final String assetName;
  final Color color;
  final String? caption;
  final bool tinted;
  final double iconSize;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF1E293B) : Colors.white;
    final radius = BorderRadius.circular(18);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: tinted
                  ? [
                      Color.alphaBlend(color.withValues(alpha: 0.05), surface),
                      Color.alphaBlend(color.withValues(alpha: 0.15), surface),
                    ]
                  : [surface, surface],
            ),
            border: Border.all(
              color: tinted
                  ? color.withValues(alpha: 0.28)
                  : (isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : const Color(0xFFE3EDE5)),
            ),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.1),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                dashboardReferenceAssetPath(assetName),
                width: iconSize,
                height: iconSize,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 5),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  style: TextStyle(
                    color: isDark
                        ? Color.lerp(color, Colors.white, 0.35)
                        : color,
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.onSurface,
                  fontSize: 11.5,
                  height: 1.25,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (caption != null) ...[
                const SizedBox(height: 2),
                Text(
                  caption!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 10,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class DashboardBottomBar extends StatelessWidget {
  const DashboardBottomBar({
    super.key,
    required this.onSelected,
    this.selectedIndex = 0,
  });

  static const addIndex = 2;
  static const _items = [
    (Icons.home_rounded, 'الرئيسية'),
    (Icons.groups_rounded, 'المشتركين'),
    (Icons.add_rounded, 'إضافة'),
    (Icons.bar_chart_rounded, 'التقارير'),
    (Icons.settings_rounded, 'الإعدادات'),
  ];

  final ValueChanged<int> onSelected;
  final int selectedIndex;

  Widget _item(int index) {
    final item = _items[index];
    final selected = index == selectedIndex;
    final isAdd = index == addIndex;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 7),
        child: Material(
          color: selected
              ? Colors.white.withValues(alpha: 0.16)
              : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: selected
                ? BorderSide(color: Colors.white.withValues(alpha: 0.28))
                : BorderSide.none,
          ),
          child: InkWell(
            onTap: () => onSelected(index),
            borderRadius: BorderRadius.circular(14),
            child: Column(
              mainAxisAlignment: isAdd
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.center,
              children: [
                if (!isAdd) Icon(item.$1, color: Colors.white, size: 23),
                const SizedBox(height: 2),
                Text(
                  item.$2,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: selected ? 1 : 0.85),
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
                if (isAdd) const SizedBox(height: 3),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.topCenter,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF0B5D2E),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
              image: DecorationImage(
                image: AssetImage(
                  dashboardReferenceAssetPath('assets/dashboard/waves.jpg'),
                ),
                fit: BoxFit.cover,
                colorFilter: const ColorFilter.mode(
                  Color(0x33062E18),
                  BlendMode.srcOver,
                ),
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x330B5D2E),
                  blurRadius: 12,
                  offset: Offset(0, -3),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: SizedBox(
                height: 68,
                child: Row(
                  children: [for (var i = 0; i < _items.length; i++) _item(i)],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          child: Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF4CD964), Color(0xFF12873F)],
              ),
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x5512873F),
                  blurRadius: 10,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => onSelected(addIndex),
                child: const Tooltip(
                  message: 'إضافة',
                  child: Icon(Icons.add_rounded, color: Colors.white, size: 36),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
