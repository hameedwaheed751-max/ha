// ignore_for_file: use_build_context_synchronously, unused_element, unused_local_variable, unnecessary_underscores

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:excel/excel.dart' as xls;
import 'package:file_saver/file_saver.dart';
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

class DashboardScreen extends StatefulWidget {
  final bool isAgentMode;
  const DashboardScreen({super.key, this.isAgentMode = false});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with WidgetsBindingObserver {
  String? sasBalanceText;
  String? sasRewardPointsText;
  bool sasWalletLoading = false;
  Timer? _subscriptionGuardTimer;
  bool _handlingExpiredLockout = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSasWallet();
    AutoNotificationService.runDailyExpiryAutomation();
    _startSubscriptionGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) {
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
    final expiredEmail = (user?.email ?? AppStore.agentEmail).trim().toLowerCase();
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
        const SnackBar(content: Text('انتهى اشتراكك، تم تسجيل الخروج تلقائياً.')),
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

  Widget card(IconData icon, String title, String value, Color color, VoidCallback tap) =>
      InkWell(
        onTap: tap,
        borderRadius: BorderRadius.circular(22),
        child: Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(icon, color: color, size: 31),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      value,
                      maxLines: 1,
                      style: const TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                Text(title, textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      );

  Future<void> open(String f) async {
    Navigator.popUntil(context, (route) => route.isFirst);
    await Navigator.push(context, MaterialPageRoute(builder: (_) => SubscribersScreen(filter: f)));
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
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('حسناً'))],
        ),
      ),
    );
  }

  Widget _drawerTile({required IconData icon, required String title, VoidCallback? onTap, Widget? trailing, bool selected = false}) {
    return Container(
      color: selected ? const Color(0xFF37414A) : Colors.transparent,
      child: ListTile(
        leading: Icon(icon, color: selected ? Colors.white : const Color(0xFFAAB5C8)),
        title: Text(title, style: TextStyle(color: selected ? Colors.white : const Color(0xFFE4E7EB), fontSize: 18)),
        trailing: trailing,
        onTap: onTap,
      ),
    );
  }

  Widget _subTile(String title, VoidCallback onTap) => ListTile(
        contentPadding: const EdgeInsets.only(right: 70, left: 18),
        title: Text(title, style: const TextStyle(color: Color(0xFFB9BEC5), fontSize: 17)),
        onTap: onTap,
      );

  Widget _subscriptionDrawerCard() {
    AppStore.refreshSubscriptionStatus();
    final isPlanActive = AppStore.subscriptionStatus == 'active';
    final statusColor = isPlanActive ? Colors.green.shade700 : Colors.red.shade700;
    final planLabel = AppStore.subscriptionPlanLabel.isNotEmpty ? AppStore.subscriptionPlanLabel : 'لا توجد باقة';
    final statusText = isPlanActive ? 'نشط' : 'منتهي';
    final endDateText = AppStore.subscriptionEndsAt != null
        ? AppStore.subscriptionEndsAt!.toLocal().toString().split(' ').first
        : '—';

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border(left: BorderSide(color: statusColor, width: 4)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('معلومات SAS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.grey.shade700)),
          const SizedBox(height: 4),
          Text(planLabel, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xFF29323A))),
          const SizedBox(height: 2),
          Text(
            'تاريخ الانتهاء: $endDateText',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.grey.shade700),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Icon(Icons.circle, size: 8, color: statusColor),
              const SizedBox(width: 6),
              Text(statusText, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: statusColor)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _mainDrawer() {
    return Drawer(
      backgroundColor: const Color(0xFF29323A),
      child: SafeArea(
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
                color: Colors.white,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.menu, size: 30, color: Color(0xFF5D6770)),
                        const Spacer(),
                        Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Text(
                            AppStore.agentName.isNotEmpty
                                ? AppStore.agentName
                                : (AppStore.officeName.isNotEmpty ? AppStore.officeName : 'وكيل جديد'),
                            style: const TextStyle(color: Color(0xFFE8492E), fontSize: 20, fontWeight: FontWeight.w900),
                          ),
                          Text(
                            AppStore.agentEmail.isNotEmpty
                                ? AppStore.agentEmail
                                : 'وكيل نت',
                            style: const TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                        ]),
                      ],
                    ),
                    _subscriptionDrawerCard(),
                  ],
                ),
              ),
              _drawerTile(icon: Icons.speed_rounded, title: 'الرئيسية', selected: true, onTap: () => Navigator.pop(context)),
              ExpansionTile(
                leading: const Icon(Icons.groups, color: Color(0xFFAAB5C8)),
                iconColor: const Color(0xFFAAB5C8),
                collapsedIconColor: const Color(0xFFAAB5C8),
                title: const Text('المشتركين', style: TextStyle(color: Color(0xFFE4E7EB), fontSize: 18)),
                children: [
                  _subTile('قائمة المشتركين', () => open('all')),
                  _subTile('المتصلين', () => open('active')),
                ],
              ),
              if (!widget.isAgentMode)
                _drawerTile(icon: Icons.admin_panel_settings_rounded, title: 'مدراء', onTap: () => _coming('مدراء')),
              ExpansionTile(
                leading: const Icon(Icons.extension_rounded, color: Color(0xFFAAB5C8)),
                iconColor: const Color(0xFFAAB5C8),
                collapsedIconColor: const Color(0xFFAAB5C8),
                title: const Text('الباقات', style: TextStyle(color: Color(0xFFE4E7EB), fontSize: 18)),
                children: [_subTile('جدول الاسعار', () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => const PackagesScreen())); })],
              ),
              ExpansionTile(
                leading: const Icon(Icons.request_page_rounded, color: Color(0xFFAAB5C8)),
                iconColor: const Color(0xFFAAB5C8),
                collapsedIconColor: const Color(0xFFAAB5C8),
                title: const Text('الحسابات', style: TextStyle(color: Color(0xFFE4E7EB), fontSize: 18)),
                children: [
                  _subTile('فواتير المشتركين', () => open('debts')),
                  _subTile('اصدار فاتورة', () => _coming('اصدار فاتورة')),
                ],
              ),
              ExpansionTile(
                leading: const Icon(Icons.list_alt_rounded, color: Color(0xFFAAB5C8)),
                iconColor: const Color(0xFFAAB5C8),
                collapsedIconColor: const Color(0xFFAAB5C8),
                title: const Text('تقارير', style: TextStyle(color: Color(0xFFE4E7EB), fontSize: 18)),
                children: [
                  _subTile('المشتركين الفعالين', () => open('active')),
                  _subTile('المنتهي اشتراكهم', () => open('expired')),
                  _subTile('المهام اليومية', () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const TodayTasksScreen()),
                    );
                  }),
                  _subTile('الديون', () { Navigator.pop(context); _openDebtsTable(); }),
                ],
              ),
              ExpansionTile(
                leading: const Icon(Icons.history_rounded, color: Color(0xFFAAB5C8)),
                iconColor: const Color(0xFFAAB5C8),
                collapsedIconColor: const Color(0xFFAAB5C8),
                title: const Text('Log', style: TextStyle(color: Color(0xFFE4E7EB), fontSize: 18)),
                children: [_subTile('سجل العمليات', () => _coming('سجل العمليات'))],
              ),
              _drawerTile(icon: Icons.cloud_sync_outlined, title: 'ربط SAS Radius', onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => const SasSettingsScreen())); }),
              _drawerTile(icon: Icons.notifications_active_outlined, title: 'التنبيهات ورسائل واتساب', onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => const MessageTemplatesScreen())); }),
              if (!widget.isAgentMode)
                _drawerTile(
                  icon: Icons.assignment_turned_in_outlined,
                  title: 'طلبات الاشتراك',
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const SubscriptionRequestsAdminScreen()));
                  },
                ),
              if (!widget.isAgentMode)
                _drawerTile(
                  icon: Icons.payments_outlined,
                  title: 'طلبات الدفع',
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const PaymentRequestsAdminScreen()));
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
                    builder: (_) => const Center(child: CircularProgressIndicator()),
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
                        for (final k in ['data', 'value', 'count', 'result']) {
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
                                ListTile(title: const Text('كل المشتركين'), trailing: Text(val('users_count'))),
                                ListTile(title: const Text('الفعالون'), trailing: Text(val('users_active_count'))),
                                ListTile(title: const Text('أونلاين'), trailing: Text(val('users_online'))),
                                ListTile(title: const Text('المنتهون'), trailing: Text(val('users_expired_count'))),
                                ListTile(title: const Text('ينتهون خلال 3 أيام'), trailing: Text(val('users_expiring_in_3_days'))),
                                ListTile(title: const Text('ينتهون اليوم'), trailing: Text(val('users_expiring_today'))),
                                ListTile(title: const Text('الرصيد'), trailing: Text(val('balance'))),
                                ListTile(title: const Text('النقاط'), trailing: Text(val('reward_points'))),
                                ListTile(title: const Text('الديون المستحقة'), trailing: Text(val('outstanding_debts'))),
                              ],
                            ),
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
                          ],
                        ),
                      ),
                    );
                  } catch (e) {
                    if (context.mounted) Navigator.pop(context);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('تعذر جلب Dashboard من SAS: $e')),
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
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const QuickReportsScreen()));
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
                    applicationVersion: 'v108',
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
    return AppStore.subscribers.where((s) =>
      s.endDate.year == now.year &&
      s.endDate.month == now.month &&
      s.endDate.day == now.day).length;
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
          SnackBar(content: Text('تمت المزامنة — جديد ${result.added}، محدث ${result.updated}، مقروء ${result.read}')),
        );
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ المزامنة: $e')));
      }
    }
  }

  Future<void> _showConnectionDiagnostic() async {
    try {
      final settings = await SasSettings.load();
      // TODO: Implement connection diagnostic feature
      final diagnostic = 'Connection diagnostic: Connecting to ${settings.serverUrl}';
      
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text('تشخيص الاتصال'),
              content: SingleChildScrollView(
                child: SelectableText(diagnostic, style: const TextStyle(fontFamily: 'monospace', fontSize: 10)),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
              ],
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = AppStore.subscribers.where((s) => s.isActive).length;
    final expired = AppStore.subscribers.where((s) => s.expired).length;
    final debts = AppStore.subscribers.where((s) => s.remaining > 0).length;
    AppStore.refreshSubscriptionStatus();
    final isPlanActive = AppStore.subscriptionStatus == 'active';
    final statusColor = isPlanActive ? Colors.green.shade700 : Colors.red.shade700;
    final statusIcon = isPlanActive ? Icons.verified_user_rounded : Icons.warning_amber_rounded;
    final statusText = isPlanActive
        ? 'باقتك نشطة حتى ${AppStore.subscriptionEndsAt != null ? AppStore.subscriptionEndsAt!.toLocal().toString().split(' ').first : '—'}'
        : 'انتهت مدة الباقة يرجى التجديد';

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        drawer: _mainDrawer(),
        appBar: AppBar(
          title: Column(children: [
            Text(AppStore.officeName, style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(
              AppStore.sasUsername.isNotEmpty
                  ? 'وكيل نت | ${AppStore.sasUsername}'
                  : 'وكيل نت',
              style: const TextStyle(fontSize: 11),
            ),
          ]),
          centerTitle: true,
          leading: Builder(
            builder: (ctx) => IconButton(
              tooltip: 'القائمة الرئيسية',
              onPressed: () => Scaffold.of(ctx).openDrawer(),
              icon: const Icon(Icons.menu_rounded, size: 30),
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'تشخيص الاتصال',
              onPressed: _showConnectionDiagnostic,
              icon: const Icon(Icons.analytics_outlined),
            ),
            IconButton(
              tooltip: 'الضبط',
              onPressed: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
                if (mounted) setState(() {});
              },
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _quickActionCard(Icons.cloud_sync_outlined, 'الاتصال بـ SAS', Colors.blue, () async {
                    await Navigator.push(context, MaterialPageRoute(builder: (_) => const SasSettingsScreen()));
                    if (mounted) setState(() {});
                  }),
                  _quickActionCard(Icons.sync_alt_outlined, 'مزامنة المشتركين', Colors.green, _syncSubscribersFromDashboard),
                  _quickActionCard(Icons.notifications_active_outlined, 'التنبيهات', Colors.amber.shade800, () async {
                    await Navigator.push(context, MaterialPageRoute(builder: (_) => const AlertsScreen()));
                    if (mounted) setState(() {});
                  }),
                  _quickActionCard(Icons.task_alt_outlined, 'المهام اليومية', Colors.indigo, () async {
                    await Navigator.push(context, MaterialPageRoute(builder: (_) => const TodayTasksScreen()));
                    if (mounted) setState(() {});
                  }),
                  _quickActionCard(Icons.event_available_outlined, 'ينتهون قريباً', Colors.orange, () async {
                    await Navigator.push(context, MaterialPageRoute(builder: (_) => const SubscribersScreen(filter: 'expiring3Days')));
                    if (mounted) setState(() {});
                  }),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final columns = width >= 1200 ? 4 : (width >= 760 ? 3 : 2);
                  final maxWidth = width >= 1100 ? 1050.0 : width;
                  final ratio = width >= 760 ? 1.35 : 1.0;

                  return Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      width: maxWidth,
                      child: GridView.count(
                        padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
                        crossAxisCount: columns,
                        childAspectRatio: ratio,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        children: [
                          card(Icons.groups_rounded, 'عدد المشتركين', '${AppStore.subscribers.length}', Colors.blue, () => open('all')),
                          card(Icons.verified_rounded, 'المشتركين الفعالين', '$active', Colors.green, () => open('active')),
                          card(Icons.event_busy_rounded, 'المنتهي اشتراكهم', '$expired', Colors.orange, () => open('expired')),
                          card(Icons.hourglass_top_rounded, 'ينتهون خلال 3 أيام', '$_expiring3Days', Colors.orange.shade700, () => open('expiring3Days')),
                          card(
                            Icons.account_balance_wallet_rounded,
                            'الرصيد',
                            sasWalletLoading && sasBalanceText == null ? '...' : (sasBalanceText ?? '--'),
                            Colors.teal,
                            _loadSasWallet,
                          ),
                          card(
                            Icons.card_giftcard_rounded,
                            'النقاط التشجيعية',
                            sasWalletLoading && sasRewardPointsText == null ? '...' : (sasRewardPointsText ?? '--'),
                            Colors.purple,
                            _loadSasWallet,
                          ),
                          card(Icons.money_off_rounded, 'الديون', '$debts', Colors.red, _openDebtsTable),
                          card(
                            Icons.notifications_active_rounded,
                            'التنبيهات',
                            '${_expiredToday + _expiring3Days}',
                            Colors.amber.shade800,
                            () async {
                              await Navigator.push(context, MaterialPageRoute(builder: (_) => const AlertsScreen()));
                              if (mounted) setState(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _quickActionCard(IconData icon, String title, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Card(
        elevation: 0,
        color: color.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 10),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
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
          content: TextField(controller: c, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'الرصيد الحالي', border: OutlineInputBorder())),
          actions: [FilledButton(onPressed: () async {AppStore.balance = double.tryParse(c.text) ?? 0; await AppStore.save(); if (ctx.mounted) Navigator.pop(ctx); setState(() {});}, child: const Text('حفظ'))],
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
                  : ListView(children: AppStore.subscribers.map((s) => Card(child: ListTile(
                      title: Text(s.name),
                      subtitle: Text('النقاط: ${s.points}'),
                      trailing: FilledButton.tonalIcon(
                        onPressed: s.points <= 0 ? null : () async {
                          s.points--;
                          final base = s.endDate.isAfter(DateTime.now()) ? s.endDate : DateTime.now();
                          s.endDate = base.add(const Duration(days: 1));
                          await AppStore.save();
                          setLocal(() {});
                          if (mounted) setState(() {});
                        },
                        icon: const Icon(Icons.redeem, size: 18),
                        label: const Text('تمديد يوم'),
                      ),
                    ))).toList()),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق'))],
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
    for (final key in const ['profile_name', 'profile', 'service_profile', 'active_profile']) {
      final v = s.sasData[key];
      if (v != null && v.toString().trim().isNotEmpty) return v.toString().trim();
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
    final oldPrice = s.price;
    final oldPaid = s.paid;
    final oldRemaining = s.remaining;
    final priceC = TextEditingController(text: s.price.toStringAsFixed(0));
    final paidC = TextEditingController(text: s.paid.toStringAsFixed(0));
    final remainingC = TextEditingController(text: s.remaining.toStringAsFixed(0));
    DateTime activationDate = s.startDate;
    String paymentDate = s.paymentDate;
    bool payNow = false;
    String lastEditedField = 'paid';

    bool syncingFields = false;
    void syncFromPaid() {
      if (syncingFields) return;
      syncingFields = true;
      final price = _parseAmount(priceC.text.trim()) ?? 0;
      final paid = (_parseAmount(paidC.text.trim()) ?? 0).clamp(0, double.infinity);
      final remaining = (price - paid).clamp(0, double.infinity).toDouble();
      remainingC.text = remaining.toStringAsFixed(0);
      syncingFields = false;
    }

    void syncFromRemaining() {
      if (syncingFields) return;
      syncingFields = true;
      final price = _parseAmount(priceC.text.trim()) ?? 0;
      final remaining = (_parseAmount(remainingC.text.trim()) ?? 0).clamp(0, double.infinity);
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
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
                  subtitle: Text(paymentDate.isEmpty ? 'غير مسدد' : paymentDate),
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
      if (parsedPrice == null || parsedPaid == null || parsedRemaining == null || parsedPrice < 0 || parsedPaid < 0 || parsedRemaining < 0) {
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
              ? (parsedPrice - parsedRemaining).clamp(0, parsedPrice).toDouble()
              : parsedPaid.clamp(0, parsedPrice).toDouble());

      final delta = s.adjustPaidToTarget(
        targetPaid,
        at: now,
        increaseNote: payNow ? 'تسديد كامل من الديون' : 'تعديل زيادة الواصل من الديون',
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
        if (delta > 0) {
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
      } else if (parsedRemaining >= 0 && (parsedPrice - parsedRemaining - oldPaid).abs() > 0.0001) {
        paymentDate = _date(now);
      }
      final addedDebt = parsedPrice - oldPrice;
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
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
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
              Text('المتبقي الحالي: ${before.toStringAsFixed(0)} د.ع',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              TextField(
                controller: amountC,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'مبلغ الدفعة', border: OutlineInputBorder()),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تسديد')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final amount = _parseAmount(amountC.text.trim()) ?? 0;
    if (amount <= 0 || amount > before) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('مبلغ الدفعة غير صحيح')),
        );
      }
      return;
    }
    final now = DateTime.now();
    final applied = s.applyPartialPayment(amount, at: now);
    if (applied <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر تسجيل الدفعة')), 
        );
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
                    child: Text('لا توجد دفعات مسجلة بعد', textAlign: TextAlign.center),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: s.payments.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final p = s.payments.reversed.toList()[i];
                      final d = p.at;
                      final stamp =
                          '${_date(d)}  ${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
                      return ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.payments_outlined)),
                        title: Text('${p.amount.toStringAsFixed(0)} د.ع',
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text('$stamp${p.note.isEmpty ? '' : ' • ${p.note}'}'),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
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
        SnackBar(content: Text('فشل إرسال واتساب: ${result.error ?? 'خطأ غير معروف'}')),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم إرسال تذكير الدين عبر واتساب')),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تصدير ملف Excel: $e')),
      );
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
    final debtorsCount = AppStore.subscribers.where((s) => s.remaining > 0.0001).length;

    final debts = AppStore.subscribers.where((s) {
      final matchesSearch = q.isEmpty ||
          s.name.toLowerCase().contains(q) ||
          s.user.toLowerCase().contains(q) ||
          s.phone.contains(q) ||
          s.type.toLowerCase().contains(q);
      if (!matchesSearch) return false;
      if (_debtFilter == 'غير مسدد') return s.remaining > 0.0001 && s.paid <= 0.0001;
      if (_debtFilter == 'تسديد جزئي') return s.remaining > 0.0001 && s.paid > 0.0001;
      return true;
    }).toList()
      ..sort((a, b) => a.name.trim().toLowerCase().compareTo(
            b.name.trim().toLowerCase(),
          ));

    final sortedDebts = List<Subscriber>.from(debts);
    sortedDebts.sort((a, b) {
      int c = 0;
      switch (_debtSortBy) {
        case 'name':
          c = a.name.trim().toLowerCase().compareTo(b.name.trim().toLowerCase());
          break;
        case 'user':
          c = a.user.trim().toLowerCase().compareTo(b.user.trim().toLowerCase());
          break;
        case 'package':
          c = _sasProfile(a).toLowerCase().compareTo(_sasProfile(b).toLowerCase());
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
          c = a.name.trim().toLowerCase().compareTo(b.name.trim().toLowerCase());
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
              tooltip: 'تصدير Excel',
              icon: Icon(Icons.download, color: green),
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
                      borderSide: BorderSide(color: green.withValues(alpha: 0.35)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: green.withValues(alpha: 0.35)),
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
                          label: SizedBox(width: double.infinity, child: Text(f, textAlign: TextAlign.center)),
                          selected: _debtFilter == f,
                          selectedColor: greenSoft,
                          checkmarkColor: green,
                          labelStyle: TextStyle(color: _debtFilter == f ? green : null),
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
                            value: '${totalSubscriptions.toStringAsFixed(0)} د.ع',
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
                          width: max(940.0, MediaQuery.of(context).size.width - 40),
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
                                if (value != null) setState(() => _rowsPerPage = value);
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
                                const DataColumn(label: Text('ت', style: TextStyle(fontWeight: FontWeight.bold))),
                                DataColumn(
                                  label: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    textDirection: TextDirection.rtl,
                                    children: [
                                      const Icon(Icons.person_outline, size: 18),
                                      const SizedBox(width: 6),
                                      const Text('اسم المشترك', style: TextStyle(fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                  onSort: (index, ascending) => _sortDebts('name'),
                                ),
                                DataColumn(
                                  label: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    textDirection: TextDirection.rtl,
                                    children: [
                                      const Icon(Icons.inventory_2_outlined, size: 18),
                                      const SizedBox(width: 6),
                                      const Text('الباقة', style: TextStyle(fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                  onSort: (index, ascending) => _sortDebts('package'),
                                ),
                                DataColumn(
                                  numeric: true,
                                  label: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    textDirection: TextDirection.rtl,
                                    children: [
                                      const Icon(Icons.payments_outlined, size: 18),
                                      const SizedBox(width: 6),
                                      const Text('الواصل', style: TextStyle(fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                  onSort: (index, ascending) => _sortDebts('paid'),
                                ),
                                DataColumn(
                                  numeric: true,
                                  label: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    textDirection: TextDirection.rtl,
                                    children: [
                                      const Icon(Icons.money_off_csred_outlined, size: 18),
                                      const SizedBox(width: 6),
                                      const Text('المتبقي', style: TextStyle(fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                  onSort: (index, ascending) => _sortDebts('remaining'),
                                ),
                                DataColumn(
                                  label: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    textDirection: TextDirection.rtl,
                                    children: [
                                      const Icon(Icons.event_outlined, size: 18),
                                      const SizedBox(width: 6),
                                      const Text('تاريخ التفعيل', style: TextStyle(fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                  onSort: (index, ascending) => _sortDebts('startDate'),
                                ),
                                const DataColumn(label: Text('تاريخ التسديد', style: TextStyle(fontWeight: FontWeight.bold))),
                                const DataColumn(label: Text('العمليات', style: TextStyle(fontWeight: FontWeight.bold))),
                              ],
                              source: _DebtsDataSource(
                                data: sortedDebts,
                                onNameTap: (subscriber) async {
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => SubscriberDetailsScreen(subscriber: subscriber)),
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

  String _date(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  DataRow? getRow(int index) {
    if (index >= data.length) return null;
    final subscriber = data[index];
    return DataRow(cells: [
      DataCell(ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 48),
        child: Text('${index + 1}', textAlign: TextAlign.center),
      )),
      DataCell(
        InkWell(
          onTap: () => onNameTap(subscriber),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              subscriber.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.blue),
            ),
          ),
        ),
      ),
      DataCell(ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 180),
        child: Text(_sasProfile(subscriber), overflow: TextOverflow.ellipsis),
      )),
      DataCell(ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 100),
        child: Text(subscriber.paid.toStringAsFixed(0), textAlign: TextAlign.center),
      )),
      DataCell(ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 100),
        child: Text(
          subscriber.remaining.toStringAsFixed(0),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
        ),
      )),
      DataCell(ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 120),
        child: Text(_date(subscriber.startDate), overflow: TextOverflow.ellipsis),
      )),
      DataCell(ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 120),
        child: Text(subscriber.paymentDate.isEmpty ? 'غير مسدد' : subscriber.paymentDate, overflow: TextOverflow.ellipsis),
      )),
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
              icon: const Icon(Icons.notifications_active, size: 18, color: Color(0xFF2E7D32)),
            ),
            IconButton(
              tooltip: 'وصل',
              onPressed: () => onReceipt(subscriber),
              icon: const Icon(Icons.print, size: 18, color: Colors.blue),
            ),
          ],
        ),
      ),
    ]);
  }

  @override
  bool get isRowCountApproximate => false;

  @override
  int get rowCount => data.length;

  @override
  int get selectedRowCount => 0;

  String _sasProfile(Subscriber s) {
    for (final key in const ['profile_name', 'profile', 'service_profile', 'active_profile']) {
      final v = s.sasData[key];
      if (v != null && v.toString().trim().isNotEmpty) return v.toString().trim();
    }
    return s.type.trim().isEmpty ? '—' : s.type;
  }
}
