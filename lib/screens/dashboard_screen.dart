// ignore_for_file: use_build_context_synchronously, unused_element, unused_local_variable, unnecessary_underscores

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:excel/excel.dart' as xls;
import 'package:file_saver/file_saver.dart';
import 'package:file_picker/file_picker.dart';
import '../models.dart';
import '../sas_api_service.dart';
import '../sas_sync_service.dart';
import '../services/auto_notification_service.dart';
import '../services/render_whatsapp_service.dart';
import 'subscribers_screen.dart';
import 'settings_screen.dart';
import 'alerts_screen.dart';
import 'subscriber_details_screen.dart';
import 'packages_screen.dart';
import 'message_templates_screen.dart';
import 'sas_settings_screen.dart';
import 'receipt_screen.dart';
import 'quick_reports_screen.dart';
import 'today_tasks_screen.dart';
import 'payment_requests_admin_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'login_screen.dart';
import 'subscription_requests_admin_screen.dart';
import 'chat_screen.dart';
import 'add_subscriber_screen.dart';
import 'speed_test_screen.dart';
import 'ping_screen.dart';
import 'accounting_reports_screen.dart';

class DashboardScreen extends StatefulWidget {
  final bool isAgentMode;
  const DashboardScreen({super.key, this.isAgentMode = false});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  String? sasBalanceText;
  String? sasRewardPointsText;
  bool sasWalletLoading = false;
  DateTime _dashboardDate = DateTime.now();
  Timer? _subscriptionGuardTimer;
  bool _handlingExpiredLockout = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startSubscriptionGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadSasWallet();
      AutoNotificationService.runDailyExpiryAutomation();
      _handleSubscriptionGuardTick();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscriptionGuardTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _handleSubscriptionGuardTick();
    }
  }

  void _startSubscriptionGuard() {
    if (!widget.isAgentMode) return;
    _subscriptionGuardTimer?.cancel();
    _subscriptionGuardTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _handleSubscriptionGuardTick();
    });
  }

  Future<void> _handleSubscriptionGuardTick() async {
    if (!mounted || !widget.isAgentMode || _handlingExpiredLockout) return;

    AppStore.refreshSubscriptionStatus();
    if (AppStore.subscriptionStatus != 'expired') return;

    _handlingExpiredLockout = true;
    final user = FirebaseAuth.instance.currentUser;
    final expiredUid = user?.uid ?? '';
    final expiredEmail = (user?.email ?? AppStore.agentEmail)
        .trim()
        .toLowerCase();
    final expiredName = AppStore.agentName.trim();
    final expiredPhone = AppStore.officePhone.trim();

    try {
      await AppStore.clearForAccountSwitch(clearStorage: false);
      await FirebaseAuth.instance.signOut();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => LoginScreen(
            forceExpiredMode: true,
            expiredUid: expiredUid,
            expiredEmail: expiredEmail,
            expiredName: expiredName,
            expiredPhone: expiredPhone,
            expiredRole: 'agent',
          ),
        ),
        (route) => false,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('انتهى اشتراكك، تم تسجيل الخروج تلقائياً.'),
        ),
      );
    } finally {
      _handlingExpiredLockout = false;
    }
  }

  Future<void> _loadSasWallet() async {
    if (sasWalletLoading) return;
    setState(() => sasWalletLoading = true);

    try {
      int? userId;
      for (final s in AppStore.subscribers) {
        final raw = s.sasId.trim().isNotEmpty
            ? s.sasId.trim()
            : (s.sasData['id'] ?? s.sasData['user_id'] ?? '').toString().trim();
        final parsed = int.tryParse(raw);
        if (parsed != null) {
          userId = parsed;
          break;
        }
      }

      if (userId == null) {
        throw Exception('لا يوجد مشترك متزامن يحمل SAS ID');
      }

      final settings = await SasSettings.load();
      final api = SasApiService(settings);
      final wallet = await api.fetchDashboardWallet(userId);

      if (!mounted) return;
      setState(() {
        sasBalanceText = wallet['balance']?.toString();
        sasRewardPointsText = wallet['reward_points']?.toString();
      });
    } catch (_) {
      // نبقي الداشبورد شغال حتى إذا تعذر جلب بيانات SAS.
    } finally {
      if (mounted) setState(() => sasWalletLoading = false);
    }
  }

  Widget _statCard(
    IconData icon,
    String title,
    String value,
    Color color,
    VoidCallback tap,
  ) {
    return InkWell(
      onTap: tap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF1E293B)
              : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.grey.shade200,
          ),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.15),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      color.withValues(alpha: 0.25),
                      color.withValues(alpha: 0.08),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: color, size: 28),
              ),
              const SizedBox(height: 12),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFFE2E8F0)
                        : const Color(0xFF1F2937),
                    shadows: [
                      Shadow(
                        color: color.withValues(alpha: 0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFF94A3B8)
                      : Colors.grey.shade600,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> open(String f) async {
    Navigator.popUntil(context, (route) => route.isFirst);
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SubscribersScreen(filter: f)),
    );
    if (mounted) setState(() {});
  }

  void _coming(String title) {
    Navigator.pop(context);
    showDialog(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(title),
          content: const Text('هذه الصفحة سنربط تفاصيلها في التحديث القادم.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('حسناً'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _drawerTile({
    required IconData icon,
    required String title,
    VoidCallback? onTap,
    Widget? trailing,
    bool selected = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLogout = title == 'تسجيل الخروج';
    final foreground = isLogout
        ? const Color(0xFFF5222D)
        : selected
        ? Colors.white
        : (isDark ? const Color(0xFFE2E8F0) : const Color(0xFF34435E));
    return Container(
      height: 68,
      decoration: BoxDecoration(
        gradient: selected
            ? const LinearGradient(
                colors: [Color(0xFF339447), Color(0xFF1B5E20)],
              )
            : null,
        border: selected
            ? null
            : Border(
                bottom: BorderSide(
                  color: isDark
                      ? const Color(0xFF263449)
                      : const Color(0xFFE8ECF2),
                ),
              ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 22),
        leading: Icon(icon, color: foreground, size: 27),
        title: Text(
          title,
          style: TextStyle(
            color: foreground,
            fontSize: 18,
            fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
        trailing:
            trailing ??
            (selected || isLogout
                ? null
                : Icon(
                    Icons.chevron_left_rounded,
                    color: foreground,
                    size: 25,
                  )),
        onTap: onTap,
      ),
    );
  }

  Widget _subTile(String title, VoidCallback onTap) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      minTileHeight: 52,
      contentPadding: const EdgeInsets.only(right: 68, left: 22),
      leading: Container(
        width: 6,
        height: 6,
        decoration: const BoxDecoration(
          color: Color(0xFF2E7D32),
          shape: BoxShape.circle,
        ),
      ),
      title: Text(
        title,
        style: TextStyle(
          color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF52617A),
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      trailing: Icon(
        Icons.chevron_left_rounded,
        size: 20,
        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF66758D),
      ),
      onTap: onTap,
    );
  }

  Widget _subscriptionDrawerCard() {
    AppStore.refreshSubscriptionStatus();
    final isPlanActive = AppStore.subscriptionStatus == 'active';
    final statusColor = isPlanActive
        ? Colors.green.shade700
        : Colors.red.shade700;
    final planLabel = AppStore.subscriptionPlanLabel.isNotEmpty
        ? AppStore.subscriptionPlanLabel
        : 'لا توجد باقة';
    final statusText = isPlanActive ? 'نشط' : 'منتهي';
    final endDateText = AppStore.subscriptionEndsAt != null
        ? AppStore.subscriptionEndsAt!.toLocal().toString().split(' ').first
        : '—';
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF334155) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border(left: BorderSide(color: statusColor, width: 4)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'معلومات SAS',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: isDark ? const Color(0xFFA5B4FC) : Colors.grey.shade700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            planLabel,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF29323A),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'تاريخ الانتهاء: $endDateText',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: isDark ? const Color(0xFF94A3B8) : Colors.grey.shade700,
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Icon(Icons.circle, size: 8, color: statusColor),
              const SizedBox(width: 6),
              Text(
                statusText,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: statusColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _mainDrawer() {
    AppStore.refreshSubscriptionStatus();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSubscriptionActive = AppStore.subscriptionStatus == 'active';
    final subscriptionStatusColor = isSubscriptionActive
        ? const Color(0xFF22A447)
        : const Color(0xFFF5222D);
    return Drawer(
      width: min(MediaQuery.sizeOf(context).width * 0.82, 410),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(22),
          bottomLeft: Radius.circular(22),
        ),
      ),
      backgroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
      child: SafeArea(
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: Theme(
            data: Theme.of(context).copyWith(
              dividerColor: Colors.transparent,
              expansionTileTheme: ExpansionTileThemeData(
                tilePadding: const EdgeInsets.symmetric(horizontal: 22),
                childrenPadding: EdgeInsets.zero,
                iconColor: isDark
                    ? const Color(0xFFA5B4FC)
                    : const Color(0xFF34435E),
                collapsedIconColor: isDark
                    ? const Color(0xFFA5B4FC)
                    : const Color(0xFF34435E),
                textColor: isDark
                    ? const Color(0xFFE2E8F0)
                    : const Color(0xFF34435E),
                collapsedTextColor: isDark
                    ? const Color(0xFFE2E8F0)
                    : const Color(0xFF34435E),
                backgroundColor: isDark
                    ? const Color(0xFF152035)
                    : const Color(0xFFF8FAFD),
                collapsedBackgroundColor: Colors.transparent,
                shape: Border(
                  bottom: BorderSide(
                    color: isDark
                        ? const Color(0xFF263449)
                        : const Color(0xFFE8ECF2),
                  ),
                ),
                collapsedShape: Border(
                  bottom: BorderSide(
                    color: isDark
                        ? const Color(0xFF263449)
                        : const Color(0xFFE8ECF2),
                  ),
                ),
              ),
            ),
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(22, 22, 22, 14),
                  color: isDark ? const Color(0xFF1E293B) : Colors.white,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF263449)
                                  : Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isDark
                                    ? const Color(0xFF3B4B64)
                                    : const Color(0xFFE8ECF2),
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x15172B4D),
                                  blurRadius: 14,
                                  offset: Offset(0, 5),
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.wifi_tethering_rounded,
                              color: Color(0xFF2E7D32),
                              size: 38,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  AppStore.agentName.isNotEmpty
                                      ? AppStore.agentName
                                      : (AppStore.officeName.isNotEmpty
                                            ? AppStore.officeName
                                            : 'وكيل نت'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isDark
                                        ? const Color(0xFFE2E8F0)
                                        : const Color(0xFF202A3A),
                                    fontSize: 22,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  'مرحباً بك',
                                  style: TextStyle(
                                    color: isDark
                                        ? const Color(0xFF94A3B8)
                                        : const Color(0xFF7B879B),
                                    fontSize: 15,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Row(
                                  children: [
                                    Container(
                                      width: 9,
                                      height: 9,
                                      decoration: BoxDecoration(
                                        color: subscriptionStatusColor,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 7),
                                    Text(
                                      isSubscriptionActive ? 'نشط' : 'منتهي',
                                      style: TextStyle(
                                        color: subscriptionStatusColor,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      _subscriptionDrawerCard(),
                    ],
                  ),
                ),
                _drawerTile(
                  icon: Icons.speed_rounded,
                  title: 'الرئيسية',
                  selected: true,
                  onTap: () => Navigator.pop(context),
                ),
                ExpansionTile(
                  leading: Icon(
                    Icons.groups,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFFA5B4FC)
                        : Colors.blueGrey.shade700,
                  ),
                  iconColor: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFFA5B4FC)
                      : Colors.blueGrey.shade700,
                  collapsedIconColor:
                      Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFFA5B4FC)
                      : Colors.blueGrey.shade700,
                  title: Text(
                    'المشتركين',
                    style: TextStyle(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFFE2E8F0)
                          : const Color(0xFF1F2937),
                      fontSize: 18,
                    ),
                  ),
                  children: [
                    _subTile('قائمة المشتركين', () => open('all')),
                    _subTile('المتصلين', () => open('active')),
                  ],
                ),
                if (!widget.isAgentMode)
                  _drawerTile(
                    icon: Icons.admin_panel_settings_rounded,
                    title: 'مدراء',
                    onTap: () => _coming('مدراء'),
                  ),
                ExpansionTile(
                  leading: Icon(
                    Icons.extension_rounded,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFFA5B4FC)
                        : Colors.blueGrey.shade700,
                  ),
                  iconColor: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFFA5B4FC)
                      : Colors.blueGrey.shade700,
                  collapsedIconColor:
                      Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFFA5B4FC)
                      : Colors.blueGrey.shade700,
                  title: Text(
                    'الباقات',
                    style: TextStyle(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFFE2E8F0)
                          : const Color(0xFF1F2937),
                      fontSize: 18,
                    ),
                  ),
                  children: [
                    _subTile('جدول الاسعار', () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const PackagesScreen(),
                        ),
                      );
                    }),
                  ],
                ),
                ExpansionTile(
                  leading: Icon(
                    Icons.request_page_rounded,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFFA5B4FC)
                        : Colors.blueGrey.shade700,
                  ),
                  iconColor: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFFA5B4FC)
                      : Colors.blueGrey.shade700,
                  collapsedIconColor:
                      Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFFA5B4FC)
                      : Colors.blueGrey.shade700,
                  title: Text(
                    'الحسابات',
                    style: TextStyle(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFFE2E8F0)
                          : const Color(0xFF1F2937),
                      fontSize: 18,
                    ),
                  ),
                  children: [
                    _subTile('فواتير المشتركين', () => open('debts')),
                    _subTile('اصدار فاتورة', () => _coming('اصدار فاتورة')),
                  ],
                ),
                _drawerTile(
                  icon: Icons.calculate_outlined,
                  title: 'التقارير الحسابية',
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AccountingReportsScreen(),
                      ),
                    );
                  },
                ),
                ExpansionTile(
                  leading: Icon(
                    Icons.list_alt_rounded,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFFA5B4FC)
                        : Colors.blueGrey.shade700,
                  ),
                  iconColor: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFFA5B4FC)
                      : Colors.blueGrey.shade700,
                  collapsedIconColor:
                      Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFFA5B4FC)
                      : Colors.blueGrey.shade700,
                  title: Text(
                    'تقارير',
                    style: TextStyle(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFFE2E8F0)
                          : const Color(0xFF1F2937),
                      fontSize: 18,
                    ),
                  ),
                  children: [
                    _subTile('المشتركين الفعالين', () => open('active')),
                    _subTile('المنتهي اشتراكهم', () => open('expired')),
                    _subTile('المهام اليومية', () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const TodayTasksScreen(),
                        ),
                      );
                    }),
                    _subTile('الديون', () {
                      Navigator.pop(context);
                      _openDebtsTable();
                    }),
                  ],
                ),
                ExpansionTile(
                  leading: Icon(
                    Icons.history_rounded,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? const Color(0xFFA5B4FC)
                        : Colors.blueGrey.shade700,
                  ),
                  iconColor: Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFFA5B4FC)
                      : Colors.blueGrey.shade700,
                  collapsedIconColor:
                      Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFFA5B4FC)
                      : Colors.blueGrey.shade700,
                  title: Text(
                    'Log',
                    style: TextStyle(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFFE2E8F0)
                          : const Color(0xFF1F2937),
                      fontSize: 18,
                    ),
                  ),
                  children: [
                    _subTile('سجل العمليات', () => _coming('سجل العمليات')),
                  ],
                ),
                _drawerTile(
                  icon: Icons.cloud_sync_outlined,
                  title: 'ربط SAS Radius',
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const SasSettingsScreen(),
                      ),
                    );
                  },
                ),
                if (!widget.isAgentMode)
                  _drawerTile(
                    icon: Icons.notifications_active_outlined,
                    title: 'التنبيهات ورسائل واتساب',
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const MessageTemplatesScreen(),
                        ),
                      );
                    },
                  ),
                if (!widget.isAgentMode)
                  _drawerTile(
                    icon: Icons.assignment_turned_in_outlined,
                    title: 'طلبات الاشتراك',
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              const SubscriptionRequestsAdminScreen(),
                        ),
                      );
                    },
                  ),
                if (!widget.isAgentMode)
                  _drawerTile(
                    icon: Icons.payments_outlined,
                    title: 'طلبات الدفع',
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const PaymentRequestsAdminScreen(),
                        ),
                      );
                    },
                  ),
                _drawerTile(
                  icon: Icons.speed_outlined,
                  title: 'بيانات SAS المباشرة',
                  onTap: () async {
                    Navigator.pop(context);
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) =>
                          const Center(child: CircularProgressIndicator()),
                    );
                    try {
                      final settings = await SasSettings.load();
                      final api = SasApiService(settings);
                      final data = await api.fetchDashboardWidgets();
                      if (context.mounted) Navigator.pop(context);
                      if (!context.mounted) return;

                      String val(String key) {
                        final v = data[key];
                        if (v == null) return '—';
                        if (v is Map) {
                          for (final k in [
                            'data',
                            'value',
                            'count',
                            'result',
                          ]) {
                            if (v[k] != null) return v[k].toString();
                          }
                        }
                        return v.toString();
                      }

                      showDialog(
                        context: context,
                        builder: (ctx) => Directionality(
                          textDirection: TextDirection.rtl,
                          child: AlertDialog(
                            title: const Text('بيانات SAS المباشرة'),
                            content: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ListTile(
                                    title: const Text('كل المشتركين'),
                                    trailing: Text(val('users_count')),
                                  ),
                                  ListTile(
                                    title: const Text('الفعالون'),
                                    trailing: Text(val('users_active_count')),
                                  ),
                                  ListTile(
                                    title: const Text('أونلاين'),
                                    trailing: Text(val('users_online')),
                                  ),
                                  ListTile(
                                    title: const Text('المنتهون'),
                                    trailing: Text(val('users_expired_count')),
                                  ),
                                  ListTile(
                                    title: const Text('ينتهون خلال 3 أيام'),
                                    trailing: Text(
                                      val('users_expiring_in_3_days'),
                                    ),
                                  ),
                                  ListTile(
                                    title: const Text('ينتهون اليوم'),
                                    trailing: Text(val('users_expiring_today')),
                                  ),
                                  ListTile(
                                    title: const Text('الرصيد'),
                                    trailing: Text(val('balance')),
                                  ),
                                  ListTile(
                                    title: const Text('النقاط'),
                                    trailing: Text(val('reward_points')),
                                  ),
                                  ListTile(
                                    title: const Text('الديون المستحقة'),
                                    trailing: Text(val('outstanding_debts')),
                                  ),
                                ],
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text('إغلاق'),
                              ),
                            ],
                          ),
                        ),
                      );
                    } catch (e) {
                      if (context.mounted) Navigator.pop(context);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('تعذر جلب Dashboard من SAS: $e'),
                          ),
                        );
                      }
                    }
                  },
                ),
                _drawerTile(
                  icon: Icons.insights_outlined,
                  title: 'تقارير سريعة',
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const QuickReportsScreen(),
                      ),
                    );
                  },
                ),
                _drawerTile(
                  icon: Icons.info_outline,
                  title: 'حول التطبيق',
                  onTap: () {
                    Navigator.pop(context);
                    showAboutDialog(
                      context: context,
                      applicationName: 'وكيل نت',
                      applicationVersion: '2.0',
                      applicationLegalese: 'إدارة مشتركي الإنترنت',
                    );
                  },
                ),
                _drawerTile(
                  icon: Icons.logout,
                  title: 'تسجيل الخروج',
                  onTap: () async {
                    await AppStore.clearForAccountSwitch(clearStorage: false);
                    await FirebaseAuth.instance.signOut();
                    if (!mounted) return;
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => LoginScreen()),
                      (route) => false,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openDebtsTable() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DebtsTableScreen()),
    );
    if (mounted) setState(() {});
  }

  int get _expiredToday {
    final now = DateTime.now();
    return AppStore.subscribers
        .where(
          (s) =>
              s.endDate.year == now.year &&
              s.endDate.month == now.month &&
              s.endDate.day == now.day,
        )
        .length;
  }

  int get _expiring3Days {
    final now = DateTime.now();
    return AppStore.subscribers.where((s) {
      if (s.disabled || s.expired) return false;
      final days = s.endDate.difference(now).inDays;
      return days >= 0 && days <= 3;
    }).length;
  }

  Future<void> _syncSubscribersFromDashboard() async {
    try {
      final settings = await SasSettings.load();
      if (settings.username.trim().isEmpty || settings.password.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('أكمل إعدادات ربط SAS أولاً')),
          );
        }
        return;
      }

      final api = SasApiService(settings);
      final result = await SasSyncService.sync(api).timeout(
        const Duration(minutes: 2),
        onTimeout: () => throw Exception('انتهت مهلة المزامنة بعد دقيقتين'),
      );
      AppStore.lastSasSync = DateTime.now();
      await AppStore.save();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'تمت المزامنة — جديد ${result.added}، محدث ${result.updated}، مقروء ${result.read}',
            ),
          ),
        );
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('خطأ المزامنة: $e')));
      }
    }
  }

  Future<void> _showConnectionDiagnostic() async {
    try {
      final settings = await SasSettings.load();
      // TODO: Implement connection diagnostic feature
      final diagnostic =
          'Connection diagnostic: Connecting to ${settings.serverUrl}';

      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text('تشخيص الاتصال'),
              content: SingleChildScrollView(
                child: SelectableText(
                  diagnostic,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('إغلاق'),
                ),
              ],
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('خطأ: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final active = AppStore.subscribers.where((s) => s.isActive).length;
    final expired = AppStore.subscribers.where((s) => s.expired).length;
    final debts = AppStore.subscribers.where((s) => s.remaining > 0).length;
    final dayEvents = AppStore.dailyTaskEvents
        .where((event) => AppStore.isSameDay(event.at, _dashboardDate))
        .toList();
    final daySummary = DailyTaskSummary.fromEvents(dayEvents);
    final alertsCount = _expiredToday + _expiring3Days;
    final latestSubscribers = List<Subscriber>.from(AppStore.subscribers)
      ..sort((a, b) => b.startDate.compareTo(a.startDate));

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        drawer: _mainDrawer(),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          elevation: 0,
          toolbarHeight: 72,
          flexibleSpace: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF4CAF60), Color(0xFF2E7D32)],
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
              ),
            ),
          ),
          title: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                AppStore.effectiveAgentName.isEmpty
                    ? 'اسم الوكيل'
                    : AppStore.effectiveAgentName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                'وكيل نت',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          centerTitle: true,
          leading: Builder(
            builder: (ctx) => IconButton(
              tooltip: 'القائمة الرئيسية',
              onPressed: () => Scaffold.of(ctx).openDrawer(),
              icon: const Icon(Icons.menu_rounded, size: 30),
            ),
          ),
          actions: [
            Stack(
              alignment: Alignment.center,
              children: [
                IconButton(
                  tooltip: 'الإشعارات',
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const AlertsScreen()),
                    );
                    if (mounted) setState(() {});
                  },
                  icon: const Icon(Icons.notifications_none_rounded),
                ),
                if (alertsCount > 0)
                  Positioned(
                    top: 12,
                    left: 8,
                    child: Container(
                      constraints: const BoxConstraints(
                        minWidth: 17,
                        minHeight: 17,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE53935),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      child: Text(
                        alertsCount > 99 ? '99+' : '$alertsCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            IconButton(
              tooltip: 'مزامنة المشتركين',
              onPressed: _syncSubscribersFromDashboard,
              icon: const Icon(Icons.sync_rounded),
            ),
            PopupMenuButton<String>(
              tooltip: 'أدوات إضافية',
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: _openDashboardTool,
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'sas',
                  child: ListTile(
                    leading: Icon(Icons.cloud_sync_outlined),
                    title: Text('الاتصال بـ SAS'),
                  ),
                ),
                PopupMenuItem(
                  value: 'tasks',
                  child: ListTile(
                    leading: Icon(Icons.task_alt_outlined),
                    title: Text('المهام اليومية'),
                  ),
                ),
                PopupMenuItem(
                  value: 'chat',
                  child: ListTile(
                    leading: Icon(Icons.chat_outlined),
                    title: Text('الدردشة'),
                  ),
                ),
                PopupMenuItem(
                  value: 'expiring',
                  child: ListTile(
                    leading: Icon(Icons.event_available_outlined),
                    title: Text('ينتهون قريباً'),
                  ),
                ),
                PopupMenuItem(
                  value: 'diagnostic',
                  child: ListTile(
                    leading: Icon(Icons.analytics_outlined),
                    title: Text('تشخيص الاتصال'),
                  ),
                ),
                PopupMenuItem(
                  value: 'theme',
                  child: ListTile(
                    leading: Icon(Icons.contrast_rounded),
                    title: Text('تغيير المظهر'),
                  ),
                ),
              ],
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: 0,
          height: 68,
          backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
          indicatorColor: isDark
              ? const Color(0xFF245B31)
              : const Color(0xFFDDF1E2),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: _onBottomNavigation,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'الرئيسية',
            ),
            NavigationDestination(
              icon: Icon(Icons.groups_outlined),
              label: 'المشتركين',
            ),
            NavigationDestination(
              icon: Icon(Icons.add_circle, size: 34, color: Color(0xFF2E7D32)),
              label: 'إضافة',
            ),
            NavigationDestination(
              icon: Icon(Icons.bar_chart_rounded),
              label: 'التقارير',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              label: 'الإعدادات',
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: _syncSubscribersFromDashboard,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final horizontalPadding = constraints.maxWidth < 600
                  ? 12.0
                  : 24.0;
              return SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  14,
                  horizontalPadding,
                  28,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 920),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _todayReportCard(daySummary),
                        const SizedBox(height: 12),
                        _dashboardStats(
                          active: active,
                          expired: expired,
                          debts: debts,
                          summary: daySummary,
                        ),
                        const SizedBox(height: 22),
                        _sectionTitle('الوصول السريع', Icons.bolt_rounded),
                        const SizedBox(height: 10),
                        _quickActionsGrid(),
                        const SizedBox(height: 22),
                        _sasInformationSection(active: active),
                        const SizedBox(height: 22),
                        _latestSubscribersSection(
                          latestSubscribers.take(4).toList(),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  String _dashboardDateText(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

  String _money(double amount) => '${amount.toStringAsFixed(0)} د.ع';

  Future<void> _pickDashboardDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dashboardDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) setState(() => _dashboardDate = picked);
  }

  Future<void> _pushDashboard(Widget page) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    if (mounted) setState(() {});
  }

  void _onBottomNavigation(int index) {
    switch (index) {
      case 1:
        _pushDashboard(const SubscribersScreen());
      case 2:
        _pushDashboard(const AddSubscriberScreen());
      case 3:
        _pushDashboard(const QuickReportsScreen());
      case 4:
        _pushDashboard(const SettingsScreen());
    }
  }

  void _openDashboardTool(String value) {
    switch (value) {
      case 'sas':
        _pushDashboard(const SasSettingsScreen());
      case 'tasks':
        _pushDashboard(const TodayTasksScreen());
      case 'chat':
        _pushDashboard(const ChatScreen());
      case 'expiring':
        _pushDashboard(const SubscribersScreen(filter: 'expiring3Days'));
      case 'diagnostic':
        _showConnectionDiagnostic();
      case 'theme':
        AppStore.toggleTheme();
        setState(() {});
    }
  }

  Widget _todayReportCard(DailyTaskSummary summary) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF66BB6A), Color(0xFF43A047)],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x2843A047),
            blurRadius: 14,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'تقرير اليوم',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _dashboardDateText(_dashboardDate),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.82),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: _pickDashboardDate,
                icon: const Icon(Icons.calendar_month_outlined, size: 16),
                label: const Text('تغيير التاريخ'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.55)),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  textStyle: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            'إجمالي النقد الواصل خلال اليوم',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.78),
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _money(summary.totalCollected),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _dashboardStats({
    required int active,
    required int expired,
    required int debts,
    required DailyTaskSummary summary,
  }) {
    final items = <(String, String, IconData, Color)>[
      (
        'حالات التفعيل',
        '${summary.activationCases}',
        Icons.check_circle_rounded,
        const Color(0xFF22A447),
      ),
      (
        'حالات تسديد الديون',
        '${summary.debtPaymentCases}',
        Icons.wifi_rounded,
        const Color(0xFF0877F9),
      ),
      (
        'الواصل من التفعيل',
        _money(summary.activationCollected),
        Icons.payments_rounded,
        const Color(0xFF219653),
      ),
      (
        'الواصل من التسديد',
        _money(summary.debtPaymentsCollected),
        Icons.account_balance_wallet_rounded,
        const Color(0xFFF57C00),
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 720 ? 4 : 2;
        final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final item in items)
              SizedBox(
                width: width,
                child: _metricCard(item.$1, item.$2, item.$3, item.$4),
              ),
          ],
        );
      },
    );
  }

  Widget _metricCard(String title, String value, IconData icon, Color color) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 112),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D16243A),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.11),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.onSurfaceVariant,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              value,
              style: TextStyle(
                color: colors.onSurface,
                fontSize: 17,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title, IconData icon) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF075ECF), size: 20),
        const SizedBox(width: 7),
        Text(
          title,
          style: TextStyle(
            color: colors.onSurface,
            fontSize: 16,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }

  Widget _quickActionsGrid() {
    final colors = Theme.of(context).colorScheme;
    final actions = <(String, IconData, Color, VoidCallback)>[
      (
        'مشترك جديد',
        Icons.person_add_alt_1_rounded,
        const Color(0xFF22A447),
        () => _pushDashboard(const AddSubscriberScreen()),
      ),
      (
        'المهام اليومية',
        Icons.task_alt_rounded,
        const Color(0xFF0877F9),
        () => _pushDashboard(const TodayTasksScreen()),
      ),
      (
        'الدردشة',
        Icons.chat_bubble_outline_rounded,
        const Color(0xFFF57C00),
        () => _pushDashboard(const ChatScreen()),
      ),
      (
        'المشتركين',
        Icons.groups_rounded,
        const Color(0xFF7446D7),
        () => _pushDashboard(const SubscribersScreen()),
      ),
      (
        'التقارير الحسابية',
        Icons.calculate_outlined,
        const Color(0xFF1B7F5C),
        () => _pushDashboard(const AccountingReportsScreen()),
      ),
      (
        'الديون',
        Icons.money_off_rounded,
        const Color(0xFFE53935),
        _openDebtsTable,
      ),
      (
        'اختبار السرعة',
        Icons.speed_rounded,
        const Color(0xFF1261A6),
        () => _pushDashboard(const SpeedTestScreen()),
      ),
      (
        'Ping',
        Icons.network_ping_rounded,
        const Color(0xFF00897B),
        () => _pushDashboard(const PingScreen()),
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 720 ? 6 : 3;
        final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final action in actions)
              SizedBox(
                width: width,
                child: InkWell(
                  onTap: action.$4,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 88),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(action.$2, color: action.$3, size: 27),
                        const SizedBox(height: 9),
                        Text(
                          action.$1,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.onSurface,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _sasInformationSection({required int active}) {
    final items = <(String, String, IconData, Color, VoidCallback)>[
      (
        'الرصيد',
        sasWalletLoading && sasBalanceText == null
            ? '...'
            : (sasBalanceText ?? '--'),
        Icons.account_balance_wallet_rounded,
        const Color(0xFF00897B),
        _loadSasWallet,
      ),
      (
        'النقاط التشجيعية',
        sasWalletLoading && sasRewardPointsText == null
            ? '...'
            : (sasRewardPointsText ?? '--'),
        Icons.card_giftcard_rounded,
        const Color(0xFF7446D7),
        _loadSasWallet,
      ),
      (
        'المشتركين الفعالين',
        '$active',
        Icons.check_circle_rounded,
        const Color(0xFF22A447),
        () => _pushDashboard(const SubscribersScreen(filter: 'active')),
      ),
      (
        'الانتهاء خلال 3 أيام',
        '$_expiring3Days',
        Icons.hourglass_top_rounded,
        const Color(0xFFF57C00),
        () => _pushDashboard(const SubscribersScreen(filter: 'expiring3Days')),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _sectionTitle('قائمة معلومات الساس', Icons.speed_rounded),
            ),
            IconButton(
              tooltip: 'تحديث معلومات SAS',
              onPressed: sasWalletLoading ? null : _loadSasWallet,
              icon: sasWalletLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 720 ? 4 : 2;
            final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final item in items)
                  SizedBox(
                    width: width,
                    child: InkWell(
                      onTap: item.$5,
                      borderRadius: BorderRadius.circular(8),
                      child: _metricCard(item.$1, item.$2, item.$3, item.$4),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _notificationState(String title, String subtitle, bool enabled) {
    final color = enabled ? const Color(0xFF159447) : const Color(0xFF7A8798);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 7),
      child: Row(
        children: [
          Icon(
            enabled ? Icons.check_circle_rounded : Icons.remove_circle_outline,
            color: color,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF68778B),
                    fontSize: 9.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _latestSubscribersSection(List<Subscriber> subscribers) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _sectionTitle('آخر المشتركين', Icons.group_outlined),
            ),
            TextButton.icon(
              onPressed: () => _pushDashboard(const SubscribersScreen()),
              icon: const Icon(Icons.arrow_back_rounded, size: 16),
              label: const Text('عرض جميع المشتركين'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE4EAF2)),
          ),
          child: subscribers.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(28),
                  child: Text(
                    'لا يوجد مشتركون حتى الآن',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF718096)),
                  ),
                )
              : Column(
                  children: [
                    for (var i = 0; i < subscribers.length; i++) ...[
                      _latestSubscriberRow(subscribers[i]),
                      if (i < subscribers.length - 1)
                        const Divider(height: 1, indent: 12, endIndent: 12),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _latestSubscriberRow(Subscriber subscriber) {
    final days = subscriber.endDate.difference(DateTime.now()).inDays;
    final bool isExpired = subscriber.expired;
    final bool isExpiring = !isExpired && days <= 3;
    final color = isExpired
        ? const Color(0xFFE53935)
        : isExpiring
        ? const Color(0xFFF57C00)
        : const Color(0xFF22A447);
    final status = isExpired ? 'منتهي' : (isExpiring ? 'قريب الانتهاء' : 'نشط');
    final avatarText = subscriber.name.trim().isEmpty
        ? 'م'
        : subscriber.name.trim()[0];

    return InkWell(
      onTap: () =>
          _pushDashboard(SubscriberDetailsScreen(subscriber: subscriber)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: [
            CircleAvatar(
              radius: 19,
              backgroundColor: color,
              child: Text(
                avatarText,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    subscriber.name.trim().isEmpty
                        ? subscriber.user
                        : subscriber.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF172B4D),
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 12,
                    runSpacing: 3,
                    children: [
                      _subscriberMeta(
                        Icons.language_rounded,
                        subscriber.ip.trim().isEmpty ? '—' : subscriber.ip,
                      ),
                      _subscriberMeta(
                        Icons.event_outlined,
                        _dashboardDateText(subscriber.endDate),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      color: color,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  isExpired ? 'منتهي' : 'المتبقي ${days < 0 ? 0 : days} يوم',
                  style: TextStyle(
                    color: color,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _subscriberMeta(IconData icon, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: const Color(0xFF718096)),
        const SizedBox(width: 3),
        Text(
          value,
          style: const TextStyle(color: Color(0xFF718096), fontSize: 9.5),
        ),
      ],
    );
  }

  Widget _quickActionCard(
    IconData icon,
    String title,
    Color color,
    VoidCallback onTap,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              color.withValues(alpha: 0.35),
              color.withValues(alpha: 0.12),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.25)),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.2),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 10),
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? const Color(0xFFE2E8F0)
                      : const Color(0xFF1F2937),
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _balance() {
    final c = TextEditingController(text: AppStore.balance.toStringAsFixed(0));
    showDialog(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حالة الرصيد'),
          content: TextField(
            controller: c,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'الرصيد الحالي',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () async {
                AppStore.balance = double.tryParse(c.text) ?? 0;
                await AppStore.save();
                if (ctx.mounted) Navigator.pop(ctx);
                setState(() {});
              },
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
  }

  void _points() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('النقاط التشجيعية'),
            content: SizedBox(
              width: double.maxFinite,
              height: 360,
              child: AppStore.subscribers.isEmpty
                  ? const Center(child: Text('لا يوجد مشتركون'))
                  : ListView(
                      children: AppStore.subscribers
                          .map(
                            (s) => Card(
                              child: ListTile(
                                title: Text(s.name),
                                subtitle: Text('النقاط: ${s.points}'),
                                trailing: FilledButton.tonalIcon(
                                  onPressed: s.points <= 0
                                      ? null
                                      : () async {
                                          s.points--;
                                          final base =
                                              s.endDate.isAfter(DateTime.now())
                                              ? s.endDate
                                              : DateTime.now();
                                          s.endDate = base.add(
                                            const Duration(days: 1),
                                          );
                                          await AppStore.save();
                                          setLocal(() {});
                                          if (mounted) setState(() {});
                                        },
                                  icon: const Icon(Icons.redeem, size: 18),
                                  label: const Text('تمديد يوم'),
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إغلاق'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DebtsTableScreen extends StatefulWidget {
  const DebtsTableScreen({super.key});

  @override
  State<DebtsTableScreen> createState() => _DebtsTableScreenState();
}

class _DebtsTableScreenState extends State<DebtsTableScreen> {
  String _sasProfile(Subscriber s) {
    for (final key in const [
      'profile_name',
      'profile',
      'service_profile',
      'active_profile',
    ]) {
      final v = s.sasData[key];
      if (v != null && v.toString().trim().isNotEmpty)
        return v.toString().trim();
    }
    return s.type.trim().isEmpty ? '—' : s.type;
  }

  final TextEditingController _debtSearchC = TextEditingController();
  final ScrollController _verticalScrollController = ScrollController();
  final ScrollController _horizontalScrollController = ScrollController();
  String _debtQuery = '';
  String _debtFilter = 'الكل';
  String _debtSortBy = 'name';
  bool _debtSortAsc = true;
  int _rowsPerPage = 50;

  @override
  void dispose() {
    _debtSearchC.dispose();
    _verticalScrollController.dispose();
    _horizontalScrollController.dispose();
    super.dispose();
  }

  void _sortDebts(String field) {
    setState(() {
      if (_debtSortBy == field) {
        _debtSortAsc = !_debtSortAsc;
      } else {
        _debtSortBy = field;
        _debtSortAsc = true;
      }
    });
  }

  String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  String _normalizePhone(String phone) {
    var n = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (n.startsWith('0')) n = '964${n.substring(1)}';
    return n;
  }

  double? _parseAmount(String raw) {
    final normalized = raw
        .trim()
        .replaceAll(',', '')
        .replaceAll(' ', '')
        .replaceAll('٠', '0')
        .replaceAll('١', '1')
        .replaceAll('٢', '2')
        .replaceAll('٣', '3')
        .replaceAll('٤', '4')
        .replaceAll('٥', '5')
        .replaceAll('٦', '6')
        .replaceAll('٧', '7')
        .replaceAll('٨', '8')
        .replaceAll('٩', '9')
        .replaceAll('٫', '.')
        .replaceAll('٬', '');
    if (normalized.isEmpty) return null;
    return double.tryParse(normalized);
  }

  Future<void> _editDebt(Subscriber s) async {
    final oldPaid = s.paid;
    final oldRemaining = s.remaining;
    final hadRecordedActivation = AppStore.hasRecordedActivation(s);
    final priceC = TextEditingController(text: s.price.toStringAsFixed(0));
    final paidC = TextEditingController(text: s.paid.toStringAsFixed(0));
    final remainingC = TextEditingController(
      text: s.remaining.toStringAsFixed(0),
    );
    DateTime activationDate = s.startDate;
    String paymentDate = s.paymentDate;
    bool payNow = false;
    String lastEditedField = 'paid';

    bool syncingFields = false;
    void syncFromPaid() {
      if (syncingFields) return;
      syncingFields = true;
      final price = _parseAmount(priceC.text.trim()) ?? 0;
      final paid = (_parseAmount(paidC.text.trim()) ?? 0).clamp(
        0,
        double.infinity,
      );
      final remaining = (price - paid).clamp(0, double.infinity).toDouble();
      remainingC.text = remaining.toStringAsFixed(0);
      syncingFields = false;
    }

    void syncFromRemaining() {
      if (syncingFields) return;
      syncingFields = true;
      final price = _parseAmount(priceC.text.trim()) ?? 0;
      final remaining = (_parseAmount(remainingC.text.trim()) ?? 0).clamp(
        0,
        double.infinity,
      );
      final paid = (price - remaining).clamp(0, price).toDouble();
      paidC.text = paid.toStringAsFixed(0);
      syncingFields = false;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('تعديل دين ${s.name}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: priceC,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) {
                    setLocal(() {
                      if (lastEditedField == 'remaining') {
                        syncFromRemaining();
                      } else {
                        syncFromPaid();
                      }
                    });
                  },
                  decoration: const InputDecoration(
                    labelText: 'مبلغ الاشتراك',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: paidC,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) {
                    setLocal(() {
                      lastEditedField = 'paid';
                      syncFromPaid();
                    });
                  },
                  decoration: const InputDecoration(
                    labelText: 'الواصل',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: remainingC,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) {
                    setLocal(() {
                      lastEditedField = 'remaining';
                      syncFromRemaining();
                    });
                  },
                  decoration: const InputDecoration(
                    labelText: 'المتبقي',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  shape: RoundedRectangleBorder(
                    side: const BorderSide(color: Color(0xFFBDBDBD)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  title: const Text('تاريخ التفعيل'),
                  subtitle: Text(_date(activationDate)),
                  trailing: const Icon(Icons.event),
                  onTap: () async {
                    final d = await showDatePicker(
                      context: ctx,
                      initialDate: activationDate,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (d != null) setLocal(() => activationDate = d);
                  },
                ),
                const SizedBox(height: 12),
                ListTile(
                  shape: RoundedRectangleBorder(
                    side: const BorderSide(color: Color(0xFFBDBDBD)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  title: const Text('تاريخ التسديد'),
                  subtitle: Text(
                    paymentDate.isEmpty ? 'غير مسدد' : paymentDate,
                  ),
                  trailing: const Icon(Icons.event_available),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () {
                    paidC.text = priceC.text.trim();
                    remainingC.text = '0';
                    paymentDate = _date(DateTime.now());
                    payNow = true;
                    Navigator.pop(ctx, true);
                  },
                  icon: const Icon(Icons.payments_rounded),
                  label: const Text('تسديد الآن'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );

    if (ok == true) {
      final parsedPrice = _parseAmount(priceC.text.trim());
      final parsedPaid = _parseAmount(paidC.text.trim());
      final parsedRemaining = _parseAmount(remainingC.text.trim());
      if (parsedPrice == null ||
          parsedPaid == null ||
          parsedRemaining == null ||
          parsedPrice < 0 ||
          parsedPaid < 0 ||
          parsedRemaining < 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تحقق من مبالغ الاشتراك والواصل')),
          );
        }
        return;
      }

      s.price = parsedPrice;
      s.normalizeDebtFields();
      s.startDate = activationDate;

      final now = DateTime.now();
      final targetPaid = payNow
          ? parsedPrice
          : (lastEditedField == 'remaining'
                ? (parsedPrice - parsedRemaining)
                      .clamp(0, parsedPrice)
                      .toDouble()
                : parsedPaid.clamp(0, parsedPrice).toDouble());

      final delta = s.adjustPaidToTarget(
        targetPaid,
        at: now,
        increaseNote: payNow
            ? 'تسديد كامل من الديون'
            : 'تعديل زيادة الواصل من الديون',
        decreaseNote: 'تصحيح تخفيض الواصل من الديون',
      );

      if (delta.abs() > 0.0001) {
        final receiptNumber = await AppStore.issueReceiptNumber(persist: false);
        s.registerInvoiceFromPayment(
          receiptNumber: receiptNumber,
          amount: delta,
          at: now,
          note: delta >= 0
              ? (payNow ? 'فاتورة تسديد كامل' : 'فاتورة تعديل زيادة الواصل')
              : 'فاتورة تصحيح تخفيض الواصل',
        );
        if (delta > 0 && hadRecordedActivation) {
          await AppStore.addDailyTaskEvent(
            DailyTaskEvent(
              type: 'debt_payment',
              subscriberUser: s.user,
              subscriberName: s.name,
              at: now,
              amount: delta,
              remainingAfter: s.remaining,
              note: s.remaining <= 0.0001
                  ? 'تسديد كامل من قائمة الديون'
                  : 'تسديد جزئي من قائمة الديون',
            ),
            persist: false,
          );
        }
        paymentDate = _date(now);
      } else if (parsedRemaining >= 0 &&
          (parsedPrice - parsedRemaining - oldPaid).abs() > 0.0001) {
        paymentDate = _date(now);
      }
      final addedDebt = DailyTaskEvent.addedDebtAmount(
        previousRemaining: oldRemaining,
        currentRemaining: s.remaining,
      );
      if (addedDebt > 0.0001) {
        await AppStore.addDailyTaskEvent(
          DailyTaskEvent(
            type: 'debt_added',
            subscriberUser: s.user,
            subscriberName: s.name,
            at: now,
            amount: addedDebt,
            remainingAfter: s.remaining,
            note: 'إضافة مبلغ من تعديل الديون',
          ),
          persist: false,
        );
      }
      if (s.paid <= 0) {
        paymentDate = '';
      }
      s.paymentDate = paymentDate;
      await AppStore.save();
      if (mounted) setState(() {});
      if (mounted) {
        final afterPaid = s.paid;
        final afterRemaining = s.remaining;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'تم الحفظ: الواصل ${oldPaid.toStringAsFixed(0)} -> ${afterPaid.toStringAsFixed(0)} | '
              'المتبقي ${oldRemaining.toStringAsFixed(0)} -> ${afterRemaining.toStringAsFixed(0)}',
            ),
          ),
        );
      }
      if (payNow && mounted) {
        await _openReceipt(s);
      }
    }
  }

  Future<void> _addDebtAmount(Subscriber s) async {
    final amountController = TextEditingController();
    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('إضافة مبلغ - ${s.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('مبلغ الاشتراك: ${s.price.toStringAsFixed(0)} د.ع'),
              Text('الواصل: ${s.paid.toStringAsFixed(0)} د.ع'),
              Text(
                'المتبقي: ${s.remaining.toStringAsFixed(0)} د.ع',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amountController,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'المبلغ المراد إضافته',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                ctx,
                _parseAmount(amountController.text.trim()),
              ),
              child: const Text('إضافة'),
            ),
          ],
        ),
      ),
    );
    if (amount == null) return;
    if (!amount.isFinite || amount <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('أدخل مبلغاً صحيحاً أكبر من صفر')),
        );
      }
      return;
    }

    final now = DateTime.now();
    s.price += amount;
    s.normalizeDebtFields();
    await AppStore.addDailyTaskEvent(
      DailyTaskEvent(
        type: 'debt_added',
        subscriberUser: s.user,
        subscriberName: s.name,
        at: now,
        amount: amount,
        remainingAfter: s.remaining,
        note: 'إضافة مبلغ من قائمة الديون',
      ),
      persist: false,
    );
    await AppStore.save();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'تمت إضافة ${amount.toStringAsFixed(0)} د.ع | '
          'المتبقي ${s.remaining.toStringAsFixed(0)} د.ع',
        ),
      ),
    );
  }

  Future<void> _partialPayment(Subscriber s) async {
    final amountC = TextEditingController();
    final before = s.remaining;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('تسديد جزئي - ${s.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'المتبقي الحالي: ${before.toStringAsFixed(0)} د.ع',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amountC,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'مبلغ الدفعة',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('تسديد'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final amount = _parseAmount(amountC.text.trim()) ?? 0;
    if (amount <= 0 || amount > before) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('مبلغ الدفعة غير صحيح')));
      }
      return;
    }
    final now = DateTime.now();
    final applied = s.applyPartialPayment(amount, at: now);
    if (applied <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تعذر تسجيل الدفعة')));
      }
      return;
    }

    final receiptNumber = await AppStore.issueReceiptNumber(persist: false);
    s.registerInvoiceFromPayment(
      receiptNumber: receiptNumber,
      amount: applied,
      at: now,
      note: s.remaining <= 0.0001 ? 'فاتورة تسديد كامل' : 'فاتورة تسديد جزئي',
    );
    await AppStore.addDailyTaskEvent(
      DailyTaskEvent(
        type: 'debt_payment',
        subscriberUser: s.user,
        subscriberName: s.name,
        at: now,
        amount: applied,
        remainingAfter: s.remaining,
        note: s.remaining <= 0.0001
            ? 'تسديد كامل من قائمة الديون'
            : 'تسديد جزئي من قائمة الديون',
      ),
      persist: false,
    );
    s.paymentDate = _date(now);
    await AppStore.save();
    if (mounted) setState(() {});
  }

  Future<void> _showPaymentHistory(Subscriber s) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('سجل دفعات ${s.name}'),
          content: SizedBox(
            width: 430,
            child: s.payments.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'لا توجد دفعات مسجلة بعد',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: s.payments.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final p = s.payments.reversed.toList()[i];
                      final d = p.at;
                      final stamp =
                          '${_date(d)}  ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
                      return ListTile(
                        leading: const CircleAvatar(
                          child: Icon(Icons.payments_outlined),
                        ),
                        title: Text(
                          '${p.amount.toStringAsFixed(0)} د.ع',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          '$stamp${p.note.isEmpty ? '' : ' • ${p.note}'}',
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendReminder(Subscriber s) async {
    final n = RenderWhatsAppService.normalizePhone(s.phone);
    if (n.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا يوجد رقم هاتف لهذا المشترك')),
        );
      }
      return;
    }

    final result = await RenderWhatsAppService.notifyDebtAdded(
      s,
      amountAdded: 0,
      remainingBalance: s.remaining,
    );

    if (!mounted) return;
    if (!result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('فشل إرسال واتساب: ${result.error ?? 'خطأ غير معروف'}'),
        ),
      );
      return;
    }

    final deliveryStatus =
        (result.details?['deliveryStatus'] ?? 'accepted').toString();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          deliveryStatus == 'delivered' || deliveryStatus == 'read'
              ? 'تم تسليم تذكير الدين إلى واتساب المشترك'
              : 'قبلت Meta التذكير وهو قيد التسليم للمشترك',
        ),
      ),
    );
  }

  Future<void> _exportDebtExcel(List<Subscriber> debts) async {
    try {
      final excel = xls.Excel.createExcel();
      final sheet = excel['الديون'];
      final defaultSheet = excel.getDefaultSheet();
      if (defaultSheet != null && defaultSheet != 'الديون') {
        excel.delete(defaultSheet);
      }

      final headers = [
        'رقم',
        'اسم المشترك',
        'اليوزر',
        'الهاتف',
        'الباقة',
        'الواصل',
        'المتبقي',
        'تاريخ التفعيل',
        'تاريخ التسديد',
      ];

      sheet.appendRow(headers.map((v) => xls.TextCellValue(v)).toList());

      for (var i = 0; i < debts.length; i++) {
        final s = debts[i];
        sheet.appendRow([
          xls.IntCellValue(i + 1),
          xls.TextCellValue(s.name),
          xls.TextCellValue(s.user),
          xls.TextCellValue(s.phone),
          xls.TextCellValue(_sasProfile(s)),
          xls.DoubleCellValue(s.paid),
          xls.DoubleCellValue(s.remaining),
          xls.TextCellValue(_date(s.startDate)),
          xls.TextCellValue(s.paymentDate.isEmpty ? 'غير مسدد' : s.paymentDate),
        ]);
      }

      final encoded = excel.encode();
      if (encoded == null) {
        throw Exception('تعذر إنشاء ملف Excel');
      }

      final now = DateTime.now();
      final stamp =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
          '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
      final fileName = 'وكيل-نت_Debts_$stamp';

      final savedPath = await FileSaver.instance.saveFile(
        name: fileName,
        bytes: Uint8List.fromList(encoded),
        fileExtension: 'xlsx',
        mimeType: MimeType.microsoftExcel,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            savedPath.isEmpty
                ? 'تم حفظ ملف Excel بنجاح'
                : 'تم حفظ ملف Excel بنجاح:\n$savedPath',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذر تصدير ملف Excel: $e')));
    }
  }

  Future<void> _importDebtExcel(List<Subscriber> currentDebts) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
        dialogTitle: 'اختر ملف الديون',
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('ملف فارغ')));
        return;
      }

      final excel = xls.Excel.decodeBytes(bytes);
      final sheetName = excel.getDefaultSheet();
      if (sheetName == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تعذر قراءة ملف Excel')));
        return;
      }
      final sheet = excel[sheetName];
      final rows = sheet.rows;
      if (rows.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('ملف Excel فارغ')));
        return;
      }

      final header = rows.first
          .map((c) => (c?.value ?? '').toString().trim())
          .toList();
      final requiredHeaders = [
        'رقم',
        'اسم المشترك',
        'اليوزر',
        'الهاتف',
        'الباقة',
        'الواصل',
        'المتبقي',
        'تاريخ التفعيل',
        'تاريخ التسديد',
      ];
      for (final h in requiredHeaders) {
        if (!header.contains(h)) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('رأس الملف غير متطابق: $h مفقود')),
          );
          return;
        }
      }

      final nameIdx = header.indexOf('اسم المشترك');
      final userIdx = header.indexOf('اليوزر');
      final phoneIdx = header.indexOf('الهاتف');
      final packageIdx = header.indexOf('الباقة');
      final paidIdx = header.indexOf('الواصل');
      final remainingIdx = header.indexOf('المتبقي');
      final startDateIdx = header.indexOf('تاريخ التفعيل');
      final paymentDateIdx = header.indexOf('تاريخ التسديد');

      final imported = <Map<String, dynamic>>[];
      for (var i = 1; i < rows.length; i++) {
        final row = rows[i];
        final name = (row.length > nameIdx ? row[nameIdx]?.value : '')
            .toString()
            .trim();
        final user = (row.length > userIdx ? row[userIdx]?.value : '')
            .toString()
            .trim();
        final phone = (row.length > phoneIdx ? row[phoneIdx]?.value : '')
            .toString()
            .trim();
        final packageName =
            (row.length > packageIdx ? row[packageIdx]?.value : '')
                .toString()
                .trim();
        final paidRaw = (row.length > paidIdx ? row[paidIdx]?.value : '')
            .toString()
            .trim();
        final remainingRaw =
            (row.length > remainingIdx ? row[remainingIdx]?.value : '')
                .toString()
                .trim();
        final startDateRaw =
            (row.length > startDateIdx ? row[startDateIdx]?.value : '')
                .toString()
                .trim();
        final paymentDate =
            (row.length > paymentDateIdx ? row[paymentDateIdx]?.value : '')
                .toString()
                .trim();

        double? parseAmount(String raw) {
          final normalized = raw
              .trim()
              .replaceAll(',', '')
              .replaceAll(' ', '')
              .replaceAll('٠', '0')
              .replaceAll('١', '1')
              .replaceAll('٢', '2')
              .replaceAll('٣', '3')
              .replaceAll('٤', '4')
              .replaceAll('٥', '5')
              .replaceAll('٦', '6')
              .replaceAll('٧', '7')
              .replaceAll('٨', '8')
              .replaceAll('٩', '9')
              .replaceAll('٫', '.')
              .replaceAll('٬', '');
          if (normalized.isEmpty) return null;
          return double.tryParse(normalized);
        }

        final paid = parseAmount(paidRaw) ?? 0.0;
        final remaining = parseAmount(remainingRaw) ?? 0.0;
        DateTime? startDate;
        final parts = startDateRaw.split(RegExp(r'[\/\-]'));
        if (parts.length == 3) {
          final year = int.tryParse(parts[0]) ?? 0;
          final month = int.tryParse(parts[1]) ?? 0;
          final day = int.tryParse(parts[2]) ?? 0;
          if (year > 2000 &&
              month >= 1 &&
              month <= 12 &&
              day >= 1 &&
              day <= 31) {
            startDate = DateTime(year, month, day);
          }
        }

        imported.add({
          'name': name,
          'user': user,
          'phone': phone,
          'packageName': packageName,
          'paid': paid,
          'remaining': remaining,
          'startDate': startDate,
          'paymentDate': paymentDate.isEmpty ? 'غير مسدد' : paymentDate,
        });
      }

      if (imported.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا توجد بيانات صالحة في الملف')),
        );
        return;
      }

      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('تأكيد الاستيراد'),
          content: Text(
            'سيتم استيراد ${imported.length} سجل من ملف Excel. هل تريد المتابعة؟',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('استيراد'),
            ),
          ],
        ),
      );
      if (confirm != true) return;

      int matched = 0;
      for (final importedSub in imported) {
        final matchedSub = AppStore.subscribers.where((s) {
          if (importedSub['name'] != null &&
              importedSub['name'].toString().isNotEmpty &&
              s.name.trim().toLowerCase() ==
                  importedSub['name'].toString().trim().toLowerCase())
            return true;
          if (importedSub['user'] != null &&
              importedSub['user'].toString().isNotEmpty &&
              s.user.trim().toLowerCase() ==
                  importedSub['user'].toString().trim().toLowerCase())
            return true;
          if (importedSub['phone'] != null &&
              importedSub['phone'].toString().isNotEmpty &&
              s.phone.trim() == importedSub['phone'].toString().trim())
            return true;
          return false;
        }).firstOrNull;

        if (matchedSub != null) {
          matchedSub.paid = importedSub['paid'] as double;
          matchedSub.price =
              matchedSub.paid + (importedSub['remaining'] as double);
          matchedSub.paymentDate = importedSub['paymentDate'] as String;
          final startDate = importedSub['startDate'] as DateTime?;
          if (startDate != null && startDate.year > 2000) {
            matchedSub.startDate = startDate;
          }
          matched++;
        }
      }

      await AppStore.save();
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('تم استيراد $matched سجل من أصل ${imported.length}'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذر استيراد ملف Excel: $e')));
    }
  }

  Future<void> _openReceipt(Subscriber s) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ReceiptScreen(subscriber: s)),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final q = _debtQuery.trim().toLowerCase();
    final green = const Color(0xFF2E7D32);
    final greenSoft = const Color(0xFFD8F3DC);
    final debtorsCount = AppStore.subscribers
        .where((s) => s.remaining > 0.0001)
        .length;

    final debts =
        AppStore.subscribers.where((s) {
          final matchesSearch =
              q.isEmpty ||
              s.name.toLowerCase().contains(q) ||
              s.user.toLowerCase().contains(q) ||
              s.phone.contains(q) ||
              s.type.toLowerCase().contains(q);
          if (!matchesSearch) return false;
          if (_debtFilter == 'غير مسدد')
            return s.remaining > 0.0001 && s.paid <= 0.0001;
          if (_debtFilter == 'تسديد جزئي')
            return s.remaining > 0.0001 && s.paid > 0.0001;
          return true;
        }).toList()..sort(
          (a, b) => a.name.trim().toLowerCase().compareTo(
            b.name.trim().toLowerCase(),
          ),
        );

    final sortedDebts = List<Subscriber>.from(debts);
    sortedDebts.sort((a, b) {
      int c = 0;
      switch (_debtSortBy) {
        case 'name':
          c = a.name.trim().toLowerCase().compareTo(
            b.name.trim().toLowerCase(),
          );
          break;
        case 'user':
          c = a.user.trim().toLowerCase().compareTo(
            b.user.trim().toLowerCase(),
          );
          break;
        case 'package':
          c = _sasProfile(
            a,
          ).toLowerCase().compareTo(_sasProfile(b).toLowerCase());
          break;
        case 'paid':
          c = a.paid.compareTo(b.paid);
          break;
        case 'remaining':
          c = a.remaining.compareTo(b.remaining);
          break;
        case 'startDate':
          c = a.startDate.compareTo(b.startDate);
          break;
        default:
          c = a.name.trim().toLowerCase().compareTo(
            b.name.trim().toLowerCase(),
          );
      }
      return _debtSortAsc ? c : -c;
    });
    final totalSubscriptions = sortedDebts.fold<double>(
      0,
      (total, subscriber) => total + subscriber.price,
    );
    final totalPaid = sortedDebts.fold<double>(
      0,
      (total, subscriber) => total + subscriber.paid,
    );
    final totalRemaining = sortedDebts.fold<double>(
      0,
      (total, subscriber) => total + subscriber.remaining,
    );

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('الديون والحسابات'),
          actions: [
            IconButton(
              tooltip: 'استيراد Excel',
              icon: const Icon(Icons.upload_file),
              onPressed: () => _importDebtExcel(sortedDebts),
            ),
            IconButton(
              tooltip: 'تصدير Excel',
              icon: const Icon(Icons.download),
              onPressed: () => _exportDebtExcel(sortedDebts),
            ),
          ],
        ),
        body: Scrollbar(
          controller: _verticalScrollController,
          thumbVisibility: true,
          child: ListView(
            controller: _verticalScrollController,
            padding: EdgeInsets.zero,
            children: [
              Container(
                margin: const EdgeInsets.fromLTRB(12, 16, 12, 12),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF12372A),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Wrap(
                  spacing: 24,
                  runSpacing: 14,
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'نظرة عامة على الديون',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'إجمالي المبلغ المتبقي',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.72),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${totalRemaining.toStringAsFixed(0)} د.ع',
                          style: const TextStyle(
                            color: Color(0xFFFFB4AB),
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.22),
                        ),
                      ),
                      child: Text(
                        '$debtorsCount مشترك مديون',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TextField(
                  controller: _debtSearchC,
                  onChanged: (v) => setState(() => _debtQuery = v),
                  decoration: InputDecoration(
                    hintText: 'بحث عن اسم المشترك أو اليوزر أو الهاتف...',
                    prefixIcon: Icon(Icons.search, color: green),
                    suffixIcon: _debtQuery.isEmpty
                        ? null
                        : IconButton(
                            onPressed: () {
                              _debtSearchC.clear();
                              setState(() => _debtQuery = '');
                            },
                            icon: Icon(Icons.close, color: green),
                          ),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                        color: green.withValues(alpha: 0.35),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                        color: green.withValues(alpha: 0.35),
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: green, width: 2),
                    ),
                    isDense: true,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Row(
                  children: ['الكل', 'غير مسدد', 'تسديد جزئي'].map((f) {
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: ChoiceChip(
                          label: SizedBox(
                            width: double.infinity,
                            child: Text(f, textAlign: TextAlign.center),
                          ),
                          selected: _debtFilter == f,
                          selectedColor: greenSoft,
                          checkmarkColor: green,
                          labelStyle: TextStyle(
                            color: _debtFilter == f ? green : null,
                          ),
                          onSelected: (_) => setState(() => _debtFilter = f),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth >= 900
                        ? 4
                        : constraints.maxWidth >= 520
                        ? 2
                        : 1;
                    final width =
                        (constraints.maxWidth - (columns - 1) * 10) / columns;
                    return Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        SizedBox(
                          width: width,
                          child: _debtMetricTile(
                            title: 'مبالغ الاشتراكات',
                            value:
                                '${totalSubscriptions.toStringAsFixed(0)} د.ع',
                            icon: Icons.receipt_long_outlined,
                            color: Colors.blue,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: _debtMetricTile(
                            title: 'إجمالي الواصل',
                            value: '${totalPaid.toStringAsFixed(0)} د.ع',
                            icon: Icons.payments_outlined,
                            color: Colors.green,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: _debtMetricTile(
                            title: 'إجمالي المتبقي',
                            value: '${totalRemaining.toStringAsFixed(0)} د.ع',
                            icon: Icons.money_off_csred_outlined,
                            color: Colors.red,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: _debtMetricTile(
                            title: 'عدد المدينين',
                            value: '$debtorsCount',
                            icon: Icons.people_outline,
                            color: Colors.orange,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              if (sortedDebts.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: const Center(child: Text('لا توجد ديون مطابقة')),
                )
              else
                Card(
                  margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: const BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                  elevation: 0,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Scrollbar(
                      controller: _horizontalScrollController,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _horizontalScrollController,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: max(
                            940.0,
                            MediaQuery.of(context).size.width - 40,
                          ),
                          child: Theme(
                            data: Theme.of(context).copyWith(
                              dataTableTheme: DataTableThemeData(
                                headingRowColor: WidgetStateProperty.all(
                                  greenSoft.withValues(alpha: 0.85),
                                ),
                                headingRowHeight: 56,
                                dataRowMinHeight: 64,
                                dataRowMaxHeight: 64,
                                dividerThickness: 1,
                                headingTextStyle: TextStyle(
                                  color: green,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            child: PaginatedDataTable(
                              showCheckboxColumn: false,
                              horizontalMargin: 8,
                              columnSpacing: 8,
                              rowsPerPage: _rowsPerPage,
                              availableRowsPerPage: const [10, 50, 100],
                              onRowsPerPageChanged: (value) {
                                if (value != null)
                                  setState(() => _rowsPerPage = value);
                              },
                              sortColumnIndex: _debtSortBy == 'name'
                                  ? 1
                                  : _debtSortBy == 'package'
                                  ? 2
                                  : _debtSortBy == 'paid'
                                  ? 3
                                  : _debtSortBy == 'remaining'
                                  ? 4
                                  : _debtSortBy == 'startDate'
                                  ? 5
                                  : null,
                              sortAscending: _debtSortAsc,
                              columns: [
                                const DataColumn(
                                  label: Text(
                                    'ت',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                DataColumn(
                                  label: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    textDirection: TextDirection.rtl,
                                    children: [
                                      const Icon(
                                        Icons.person_outline,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 6),
                                      const Text(
                                        'اسم المشترك',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                  onSort: (index, ascending) =>
                                      _sortDebts('name'),
                                ),
                                DataColumn(
                                  label: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    textDirection: TextDirection.rtl,
                                    children: [
                                      const Icon(
                                        Icons.inventory_2_outlined,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 6),
                                      const Text(
                                        'الباقة',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                  onSort: (index, ascending) =>
                                      _sortDebts('package'),
                                ),
                                DataColumn(
                                  numeric: true,
                                  label: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    textDirection: TextDirection.rtl,
                                    children: [
                                      const Icon(
                                        Icons.payments_outlined,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 6),
                                      const Text(
                                        'الواصل',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                  onSort: (index, ascending) =>
                                      _sortDebts('paid'),
                                ),
                                DataColumn(
                                  numeric: true,
                                  label: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    textDirection: TextDirection.rtl,
                                    children: [
                                      const Icon(
                                        Icons.money_off_csred_outlined,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 6),
                                      const Text(
                                        'المتبقي',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                  onSort: (index, ascending) =>
                                      _sortDebts('remaining'),
                                ),
                                DataColumn(
                                  label: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    textDirection: TextDirection.rtl,
                                    children: [
                                      const Icon(
                                        Icons.event_outlined,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 6),
                                      const Text(
                                        'تاريخ التفعيل',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                  onSort: (index, ascending) =>
                                      _sortDebts('startDate'),
                                ),
                                const DataColumn(
                                  label: Text(
                                    'تاريخ التسديد',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const DataColumn(
                                  label: Text(
                                    'العمليات',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                              source: _DebtsDataSource(
                                data: sortedDebts,
                                onNameTap: (subscriber) async {
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => SubscriberDetailsScreen(
                                        subscriber: subscriber,
                                      ),
                                    ),
                                  );
                                  if (mounted) setState(() {});
                                },
                                onEdit: _editDebt,
                                onAddAmount: _addDebtAmount,
                                onPartialPayment: _partialPayment,
                                onReminder: _sendReminder,
                                onReceipt: _openReceipt,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _debtMetricTile({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      constraints: const BoxConstraints(minHeight: 104),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DebtsDataSource extends DataTableSource {
  _DebtsDataSource({
    required this.data,
    required this.onNameTap,
    required this.onEdit,
    required this.onAddAmount,
    required this.onPartialPayment,
    required this.onReminder,
    required this.onReceipt,
  });

  final List<Subscriber> data;
  final Future<void> Function(Subscriber) onNameTap;
  final void Function(Subscriber) onEdit;
  final void Function(Subscriber) onAddAmount;
  final void Function(Subscriber) onPartialPayment;
  final void Function(Subscriber) onReminder;
  final void Function(Subscriber) onReceipt;

  String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  DataRow? getRow(int index) {
    if (index >= data.length) return null;
    final subscriber = data[index];
    return DataRow(
      cells: [
        DataCell(
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 48),
            child: Text('${index + 1}', textAlign: TextAlign.center),
          ),
        ),
        DataCell(
          InkWell(
            onTap: () => onNameTap(subscriber),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                subscriber.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: Colors.blue,
                ),
              ),
            ),
          ),
        ),
        DataCell(
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              _sasProfile(subscriber),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        DataCell(
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 100),
            child: Text(
              subscriber.paid.toStringAsFixed(0),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        DataCell(
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 100),
            child: Text(
              subscriber.remaining.toStringAsFixed(0),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        DataCell(
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              _date(subscriber.startDate),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        DataCell(
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              subscriber.paymentDate.isEmpty
                  ? 'غير مسدد'
                  : subscriber.paymentDate,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        DataCell(
          Wrap(
            spacing: 4,
            runSpacing: 4,
            alignment: WrapAlignment.center,
            children: [
              PopupMenuButton<String>(
                tooltip: 'العمليات',
                icon: const Icon(Icons.more_vert, color: Colors.blueGrey),
                onSelected: (value) {
                  switch (value) {
                    case 'edit':
                      onEdit(subscriber);
                    case 'add_amount':
                      onAddAmount(subscriber);
                    case 'partial_payment':
                      onPartialPayment(subscriber);
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
                    child: Text(
                      'الواصل: ${subscriber.paid.toStringAsFixed(0)} د.ع',
                    ),
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
                  const PopupMenuItem<String>(
                    value: 'edit',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.edit_outlined),
                      title: Text('تعديل المبالغ'),
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: 'add_amount',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.add_card_outlined),
                      title: Text('إضافة مبلغ'),
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: 'partial_payment',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.payments_outlined),
                      title: Text('تسديد جزء من المبلغ'),
                    ),
                  ),
                ],
              ),
              IconButton(
                tooltip: 'تنبيه',
                onPressed: () => onReminder(subscriber),
                icon: const Icon(
                  Icons.notifications_active,
                  size: 18,
                  color: Color(0xFF2E7D32),
                ),
              ),
              IconButton(
                tooltip: 'وصل',
                onPressed: () => onReceipt(subscriber),
                icon: const Icon(Icons.print, size: 18, color: Colors.blue),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  bool get isRowCountApproximate => false;

  @override
  int get rowCount => data.length;

  @override
  int get selectedRowCount => 0;

  String _sasProfile(Subscriber s) {
    for (final key in const [
      'profile_name',
      'profile',
      'service_profile',
      'active_profile',
    ]) {
      final v = s.sasData[key];
      if (v != null && v.toString().trim().isNotEmpty)
        return v.toString().trim();
    }
    return s.type.trim().isEmpty ? '—' : s.type;
  }
}
