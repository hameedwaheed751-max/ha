import 'dart:async';

import 'package:flutter/material.dart';

import '../earthlink_reseller_service.dart';
import '../models.dart';
import '../sas_api_service.dart';
import '../sas_sync_service.dart';
import '../sas_project_national_service.dart';
import '../services/sas_directory_service.dart';
import '../services/trial_guard_service.dart';

const _defaultProxyUrl =
    'https://netagent-sas-proxy.wakeel-net-hamwdy.workers.dev';

/// قيمة تُرجعها قائمة الدليل حين يختار الوكيل «المشروع الوطني»، فله شاشة
/// ربط خاصة بدل تعبئة الرابط العادي.
class _NationalProjectPick {
  const _NationalProjectPick();
}

const _nationalProjectPick = _NationalProjectPick();

/// قيمة تُرجعها قائمة الدليل حين يختار الوكيل «إيرثلنك»، فله شاشة ربط خاصة
/// (لوحة وكلاء admin.earthlink.iq) بدل ربط ساس radius العادي.
class _EarthlinkPick {
  const _EarthlinkPick();
}

const _earthlinkPick = _EarthlinkPick();

/// ربط SAS Radius: كل الساسات، الأساسي والإضافية، بطاقات بنفس الخيارات.
class SasSettingsScreen extends StatefulWidget {
  const SasSettingsScreen({
    super.key,
    this.loadPrimary,
    this.loadExtras,
    this.planAllowsExtra,
  });

  /// للاختبار؛ الافتراضي يقرأ الإعدادات المحفوظة وخطة الوكيل.
  final Future<SasSettings> Function()? loadPrimary;
  final Future<List<SasSettings>> Function()? loadExtras;
  final bool Function()? planAllowsExtra;

  /// التجربة المجانية تسمح بساس واحد؛ الإضافي للخطط المدفوعة فقط.
  static bool defaultPlanAllowsExtra() =>
      TrialGuardService.isAdmin ||
      (AppStore.subscriptionStatus == 'active' &&
          !TrialGuardService.onFreeTrial);

  static const paidPlanMessage =
      'إضافة ساس آخر تحتاج إلى خطة مدفوعة. التجربة المجانية تسمح بساس واحد فقط.';

  @override
  State<SasSettingsScreen> createState() => _SasSettingsScreenState();
}

class _SasSettingsScreenState extends State<SasSettingsScreen> {
  SasSettings? _primary;
  List<SasSettings> _extras = const [];
  bool _loading = true;
  bool _syncingAll = false;
  String? _busyId;

  /// مزوّدون خاصّون (إعداداتهم منفصلة عن ساس radius) يظهرون كبطاقات مربوطة.
  bool _ftthLinked = false;
  bool _earthlinkLinked = false;

  List<SasSettings> get _accounts => [
    if (_primary != null && _primary!.isLinked) _primary!,
    ..._extras,
  ];

  int get _linkedCount =>
      _accounts.length + (_ftthLinked ? 1 : 0) + (_earthlinkLinked ? 1 : 0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reload();
    });
  }

  Future<void> _reload() async {
    try {
      final primary = await (widget.loadPrimary ?? SasSettings.load)();
      final extras = await (widget.loadExtras ?? SasSettings.loadExtras)();
      // المزوّدون الخاصّون: مربوطون إن حُفظ اسم مستخدمهم (كلمة المرور قد تكون
      // على الجهاز فقط). فشل تحميلهم لا يمنع عرض ساسات radius.
      var ftth = false;
      var earthlink = false;
      try {
        ftth = (await SasProjectNationalSettings.load()).username.trim().isNotEmpty;
      } catch (_) {}
      try {
        earthlink = (await EarthlinkResellerSettings.load()).username
            .trim()
            .isNotEmpty;
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _primary = primary;
        _extras = extras;
        _ftthLinked = ftth;
        _earthlinkLinked = earthlink;
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static const _ftthBusyId = '__ftth__';
  static const _earthlinkBusyId = '__earthlink__';

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// مزامنة مزوّد خاص (FTTH/إيرثلنك) من بطاقته، مع إظهار النتيجة.
  Future<void> _syncProvider(
    String busyId,
    Future<Object?> Function() sync,
  ) async {
    setState(() => _busyId = busyId);
    try {
      await sync().timeout(const Duration(minutes: 3));
      if (mounted) {
        _snack('تمت المزامنة');
        setState(() {});
      }
    } catch (e) {
      if (mounted) _snack('فشلت المزامنة: $e');
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  /// تعديل مزوّد خاص: يفتح شاشة الربط مع اختياره مسبقاً لإعادة إدخال الاعتماد.
  Future<void> _editProvider(String provider) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SasAccountDialog(
        primary: false,
        others: _accounts,
        proxyUrl: _primary?.webProxyUrl.trim().isNotEmpty == true
            ? _primary!.webProxyUrl
            : _defaultProxyUrl,
        initialProvider: provider,
      ),
    );
    if (mounted) await _reload();
  }

  /// يفصل مزوّداً خاصاً: يمسح إعداداته ويحذف مشتركيه من التطبيق، بعد تأكيد.
  Future<void> _unlinkProvider({
    required String title,
    required String busyId,
    required String source,
    required Future<void> Function() clear,
  }) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('فصل $title'),
          content: Text('سيُحذف $title من القائمة ويُزال مشتركوه من التطبيق.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('فصل'),
            ),
          ],
        ),
      ),
    );
    if (confirm != true) return;
    setState(() => _busyId = busyId);
    try {
      await clear();
      AppStore.subscribers.removeWhere((s) => s.source == source);
      await AppStore.save();
      if (mounted) _snack('تم فصل $title');
      await _reload();
    } catch (e) {
      if (mounted) _snack('فشل الفصل: $e');
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  int _countIn(SasSettings account) => AppStore.subscribers
      .where(
        (s) => s.source == 'sas' && s.sasPresence.contains(account.accountId),
      )
      .length;

  Future<void> _add() async {
    final primaryReady = _primary?.isLinked == true;
    if (primaryReady) {
      final allowed =
          (widget.planAllowsExtra ??
          SasSettingsScreen.defaultPlanAllowsExtra)();
      if (!allowed) {
        await showDialog<void>(
          context: context,
          builder: (context) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              icon: const Icon(Icons.workspace_premium_outlined),
              title: const Text('تحتاج إلى خطة مدفوعة'),
              content: const Text(SasSettingsScreen.paidPlanMessage),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('حسناً'),
                ),
              ],
            ),
          ),
        );
        return;
      }
    }
    // أول ساس يربطه الوكيل هو الأساسي.
    await _edit(null, primary: !primaryReady);
  }

  Future<void> _edit(SasSettings? existing, {required bool primary}) async {
    final saved = await showDialog<SasSettings>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SasAccountDialog(
        existing: existing,
        primary: primary,
        others: [
          for (final a in _accounts)
            if (a.accountId != existing?.accountId || existing == null) a,
        ],
        proxyUrl: _primary?.webProxyUrl.trim().isNotEmpty == true
            ? _primary!.webProxyUrl
            : _defaultProxyUrl,
      ),
    );
    if (saved == null) return;
    await _reload();
    await _sync(saved);
  }

  Future<void> _sync(SasSettings account) async {
    setState(() => _busyId = account.accountId);
    try {
      final result = await SasSyncService.sync(
        SasApiService(account),
      ).timeout(const Duration(minutes: 2));
      AppStore.lastSasSync = DateTime.now();
      await AppStore.save();
      _snack(
        '${account.displayName}: جديد ${result.added}، محدث ${result.updated}، '
        'مقروء ${result.read}',
      );
    } catch (e) {
      _snack('تعذرت مزامنة ${account.displayName}: $e');
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _syncAll() async {
    setState(() => _syncingAll = true);
    try {
      final result = await SasSyncService.syncAll();
      if (result.accounts == 0) {
        _snack('اربط ساساً أولاً');
        return;
      }
      if (!result.allFailed) {
        AppStore.lastSasSync = DateTime.now();
        await AppStore.save();
      }
      _snack(
        result.allFailed
            ? 'تعذرت المزامنة: ${result.failures.values.first}'
            : 'تمت المزامنة — ${result.summary}',
      );
    } finally {
      if (mounted) setState(() => _syncingAll = false);
    }
  }

  /// [unlink] يحذف الساس نفسه بعد مشتركيه؛ وإلا يحذف المشتركين فقط.
  Future<void> _delete(SasSettings account, {required bool unlink}) async {
    final id = account.accountId;
    final total = AppStore.countToDelete(all: false, account: id);
    final shared = _countIn(account) - total;
    final notes = [
      if (shared > 0)
        '$shared مشترك موجود في ساس آخر أيضاً لن يُحذف، وينتقل مرجعه إليه.',
      if (unlink) 'سيُفصل الساس من التطبيق، ويمكن ربطه من جديد لاحقاً.',
    ];
    DeleteSubscribersChoice? choice;
    if (total > 0) {
      choice = await showDialog<DeleteSubscribersChoice>(
        context: context,
        builder: (_) => DeleteSubscribersDialog(
          all: false,
          total: total,
          debtors: AppStore.debtorsAmong(all: false, account: id),
          title: unlink
              ? 'حذف ${account.displayName}؟'
              : 'حذف مشتركي ${account.displayName}؟',
          company: account.company,
          notes: notes,
        ),
      );
    } else {
      if (!unlink) {
        _snack('لا يوجد مشتركون خاصون بهذا الساس');
        return;
      }
      choice = await showDialog<DeleteSubscribersChoice>(
        context: context,
        builder: (_) => DeleteSubscribersDialog(
          all: false,
          total: 0,
          debtors: const [],
          title: 'حذف ${account.displayName}؟',
          company: account.company,
          notes: notes,
        ),
      );
    }
    if (choice == null) return;
    setState(() => _busyId = id);
    try {
      await AppStore.deleteSasSubscribersOnly(
        account: id,
        keepDebtors: choice == DeleteSubscribersChoice.keepDebtors,
      );
      if (unlink) {
        if (account.isPrimary) {
          await SasSettings.clearPrimary();
          AppStore.sasUsername = '';
          await AppStore.save();
        } else {
          await SasSettings.removeExtra(id);
        }
      }
      _snack(
        unlink
            ? 'تم حذف ${account.displayName}'
            : 'تم حذف مشتركي ${account.displayName}',
      );
      await _reload();
    } catch (e) {
      _snack('تعذر الحذف: $e');
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _deleteAll() async {
    final total = AppStore.countToDelete(all: true);
    if (total == 0) {
      _snack('لا يوجد مشتركون للحذف');
      return;
    }
    final choice = await showDialog<DeleteSubscribersChoice>(
      context: context,
      builder: (_) => DeleteSubscribersDialog(
        all: true,
        total: total,
        debtors: AppStore.debtorsAmong(all: true),
        notes: const ['الساسات تبقى مربوطة، والمزامنة تعيد مشتركيها.'],
      ),
    );
    if (choice == null) return;
    final keepDebtors = choice == DeleteSubscribersChoice.keepDebtors;
    try {
      await AppStore.deleteAllSubscribers(keepDebtors: keepDebtors);
      _snack(
        keepDebtors
            ? 'تم الحذف، وبقي المدينون في قائمة الديون كمشتركين سابقين'
            : 'تم حذف جميع المشتركين',
      );
      if (mounted) setState(() {});
    } catch (e) {
      _snack('تعذر حذف المشتركين من Firebase: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accounts = _accounts;
    final busy = _busyId != null || _syncingAll;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('ربط SAS Radius'),
          centerTitle: true,
          automaticallyImplyLeading: false,
          leading: IconButton(
            tooltip: 'رجوع',
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _AgentHeader(colors: colors),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'الساسات المربوطة ($_linkedCount)',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          if (accounts.isNotEmpty)
                            TextButton.icon(
                              onPressed: busy ? null : _syncAll,
                              icon: _syncingAll
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.sync),
                              label: const Text('مزامنة الكل'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'مشتركو كل الساسات في قائمة واحدة، وكل عملية تُرسل إلى '
                        'ساس المشترك نفسه.',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                      const SizedBox(height: 10),
                      if (_linkedCount == 0)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.dns_outlined,
                                  size: 40,
                                  color: colors.primary,
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'لم يُربط أي ساس بعد. اربط ساسك ليظهر '
                                  'مشتركوه في التطبيق.',
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        ),
                      for (final account in accounts)
                        SasAccountCard(
                          key: ValueKey('sas-${account.accountId}'),
                          account: account,
                          subscribers: _countIn(account),
                          busy: _busyId == account.accountId,
                          enabled: !busy,
                          onSelected: (action) => switch (action) {
                            SasCardAction.sync => _sync(account),
                            SasCardAction.edit => _edit(
                              account,
                              primary: account.isPrimary,
                            ),
                            SasCardAction.deleteSubscribers => _delete(
                              account,
                              unlink: false,
                            ),
                            SasCardAction.unlink => _delete(
                              account,
                              unlink: true,
                            ),
                          },
                        ),
                      if (_ftthLinked)
                        _ProviderCard(
                          title: 'المشروع الوطني',
                          host: 'admin.ftth.iq',
                          icon: Icons.account_tree_outlined,
                          count: AppStore.subscribers
                              .where((s) => s.source == 'ftth')
                              .length,
                          busy: _busyId == _ftthBusyId,
                          enabled: !busy,
                          onSync: () => _syncProvider(
                            _ftthBusyId,
                            SasProjectNationalService.syncSaved,
                          ),
                          onEdit: () => _editProvider('ftth'),
                          onUnlink: () => _unlinkProvider(
                            title: 'المشروع الوطني',
                            busyId: _ftthBusyId,
                            source: 'ftth',
                            clear: SasProjectNationalSettings.clear,
                          ),
                        ),
                      if (_earthlinkLinked)
                        _ProviderCard(
                          title: 'إيرثلنك',
                          host: 'admin.earthlink.iq',
                          icon: Icons.router_outlined,
                          count: AppStore.subscribers
                              .where((s) => s.source == 'earthlink')
                              .length,
                          busy: _busyId == _earthlinkBusyId,
                          enabled: !busy,
                          onSync: () => _syncProvider(
                            _earthlinkBusyId,
                            EarthlinkResellerService.syncSaved,
                          ),
                          onEdit: () => _editProvider('earthlink'),
                          onUnlink: () => _unlinkProvider(
                            title: 'إيرثلنك',
                            busyId: _earthlinkBusyId,
                            source: 'earthlink',
                            clear: EarthlinkResellerSettings.clear,
                          ),
                        ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 50,
                        child: FilledButton.icon(
                          onPressed: busy ? null : _add,
                          icon: const Icon(Icons.add_link),
                          label: Text(
                            accounts.isEmpty ? 'ربط ساس' : 'إضافة ساس آخر',
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      Card(
                        color: colors.errorContainer.withValues(alpha: 0.35),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'منطقة الحذف',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: colors.error,
                                ),
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'لحذف مشتركي ساس واحد أو فصله استخدم قائمة '
                                'بطاقته. هنا تحذف كل المشتركين من التطبيق، '
                                'ويُسأل عن المدينين قبل الحذف.',
                              ),
                              const SizedBox(height: 10),
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: colors.error,
                                ),
                                onPressed: busy ? null : _deleteAll,
                                icon: const Icon(Icons.delete_forever),
                                label: const Text('حذف جميع المشتركين'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class _AgentHeader extends StatelessWidget {
  const _AgentHeader({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    final name = AppStore.effectiveAgentName;
    return Card(
      color: colors.primaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: colors.primary,
              child: const Icon(Icons.person, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('اسم الوكيل', style: TextStyle(fontSize: 12)),
                  Text(
                    name.isNotEmpty ? name : 'لم يتم إدخال اسم الوكيل بعد',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum SasCardAction { sync, edit, deleteSubscribers, unlink }

/// بطاقة ساس واحد: الشركة فوق اسم الساس، ونفس القائمة لكل الساسات.
class SasAccountCard extends StatelessWidget {
  const SasAccountCard({
    super.key,
    required this.account,
    required this.subscribers,
    required this.onSelected,
    this.busy = false,
    this.enabled = true,
  });

  final SasSettings account;
  final int subscribers;
  final bool busy;
  final bool enabled;
  final ValueChanged<SasCardAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final company = account.company.trim();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: colors.secondaryContainer,
              child: Icon(Icons.dns_rounded, color: colors.secondary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    company.isNotEmpty ? company : 'شركة غير محددة',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: company.isNotEmpty
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                  ),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          account.displayName,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (account.isPrimary) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: colors.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'أساسي',
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.primary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${account.username} • ${account.serverUrl}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (account.needsPassword) ...[
                    const SizedBox(height: 6),
                    InkWell(
                      key: ValueKey('needs-password-${account.accountId}'),
                      onTap: enabled
                          ? () => onSelected(SasCardAction.edit)
                          : null,
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: colors.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.lock_outline,
                              size: 16,
                              color: colors.onErrorContainer,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'أدخل كلمة المرور على هذا الجهاز',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: colors.onErrorContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 2),
                  Text(
                    '$subscribers مشترك',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              PopupMenuButton<SasCardAction>(
                enabled: enabled,
                tooltip: 'خيارات الساس',
                onSelected: onSelected,
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: SasCardAction.sync,
                    child: ListTile(
                      leading: Icon(Icons.sync),
                      title: Text('مزامنة'),
                    ),
                  ),
                  PopupMenuItem(
                    value: SasCardAction.edit,
                    child: ListTile(
                      leading: Icon(Icons.edit_outlined),
                      title: Text('تعديل'),
                    ),
                  ),
                  PopupMenuItem(
                    value: SasCardAction.deleteSubscribers,
                    child: ListTile(
                      leading: Icon(Icons.person_remove_outlined),
                      title: Text('حذف مشتركي هذا الساس'),
                    ),
                  ),
                  PopupMenuItem(
                    value: SasCardAction.unlink,
                    child: ListTile(
                      leading: Icon(Icons.link_off, color: Colors.red),
                      title: Text(
                        'حذف الساس',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// إدخال أو تعديل ساس، أساسياً كان أو إضافياً، بنفس الحقول. يُتحقق من الدخول
/// ومن أن الساس غير مربوط بوكيل آخر قبل الحفظ.
class SasAccountDialog extends StatefulWidget {
  const SasAccountDialog({
    super.key,
    this.existing,
    this.primary = false,
    this.others = const [],
    this.proxyUrl = _defaultProxyUrl,
    this.initialProvider,
  });

  final SasSettings? existing;
  final bool primary;
  final List<SasSettings> others;
  final String proxyUrl;

  /// 'ftth' أو 'earthlink': يفتح الحوار على شاشة ربط هذا المزوّد مباشرة.
  final String? initialProvider;

  @override
  State<SasAccountDialog> createState() => _SasAccountDialogState();
}

class _SasAccountDialogState extends State<SasAccountDialog> {
  late final _company = TextEditingController(text: widget.existing?.company);
  late final _label = TextEditingController(text: widget.existing?.label);
  late final _server = TextEditingController(text: widget.existing?.serverUrl);
  late final _user = TextEditingController(
    text: widget.existing?.username == 'يوزر الساس'
        ? ''
        : widget.existing?.username,
  );
  late final _pass = TextEditingController(text: widget.existing?.password);
  bool _saving = false;
  bool _hide = true;
  String? _error;
  Future<List<DirectoryCompany>>? _directory;

  /// شركة اختِيرت من الدليل: رابطها محفوظ، فنطلب اسم المستخدم وكلمة المرور
  /// فقط ونخفي حقول الشركة والرابط والاسم.
  bool _picked = false;

  /// المشروع الوطني: نفس الواجهة لكن محرّك ربط FTTH خاص بدل ساس radius.
  bool _national = false;

  /// إيرثلنك: نفس الواجهة لكن محرّك لوحة وكلاء admin.earthlink.iq.
  bool _earthlink = false;

  /// اسم مضيف الشركة المختارة، يظهر في ترويسة «رابط محفوظ».
  String _pickedHost = '';

  @override
  void initState() {
    super.initState();
    // دليل الشركات للاختيار السريع؛ فشله لا يمنع الإدخال اليدوي.
    _directory = SasDirectoryService.load();
    // تعديل مزوّد خاص: افتح شاشة ربطه مباشرة.
    switch (widget.initialProvider) {
      case 'ftth':
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _pickNationalProject();
        });
      case 'earthlink':
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _pickEarthlink();
        });
    }
  }

  /// شركة من الدليل: رابطها محفوظ، فنُبقي اسم المستخدم وكلمة المرور فقط.
  /// اسم الساس يُملأ تلقائياً باسم الشركة.
  void _pickCompany(DirectoryCompany company) {
    setState(() {
      _company.text = company.company;
      _server.text = company.serverUrl;
      _label.text = company.company;
      _pickedHost = company.host;
      _picked = true;
      _national = false;
      _earthlink = false;
      _error = null;
    });
  }

  /// «المشروع الوطني» شركة في الدليل لكن بمحرّك ربط FTTH خاص. نفتح نفس
  /// الواجهة (اسم مستخدم + كلمة مرور) ونملأ اليوزر المحفوظ إن وُجد.
  Future<void> _pickNationalProject() async {
    setState(() {
      _company.text = 'المشروع الوطني';
      _server.text = 'https://admin.ftth.iq';
      _label.text = 'المشروع الوطني';
      _pickedHost = 'admin.ftth.iq';
      _national = true;
      _earthlink = false;
      _picked = true;
      _error = null;
    });
    try {
      final saved = await SasProjectNationalSettings.load();
      if (!mounted || !_national) return;
      if (saved.username.trim().isNotEmpty && _user.text.trim().isEmpty) {
        setState(() => _user.text = saved.username.trim());
      }
    } catch (_) {
      // تعذّر تحميل الإعدادات المحفوظة لا يمنع الإدخال اليدوي.
    }
  }

  /// «إيرثلنك» شركة في الدليل بمحرّك لوحة الوكلاء الخاص. نفس الواجهة (اسم
  /// مستخدم + كلمة مرور) ونملأ اليوزر المحفوظ إن وُجد.
  Future<void> _pickEarthlink() async {
    setState(() {
      _company.text = 'إيرثلنك';
      _server.text = 'https://admin.earthlink.iq';
      _label.text = 'إيرثلنك';
      _pickedHost = 'admin.earthlink.iq';
      _earthlink = true;
      _national = false;
      _picked = true;
      _error = null;
    });
    try {
      final saved = await EarthlinkResellerSettings.load();
      if (!mounted || !_earthlink) return;
      if (saved.username.trim().isNotEmpty && _user.text.trim().isEmpty) {
        setState(() => _user.text = saved.username.trim());
      }
    } catch (_) {
      // تعذّر تحميل الإعدادات المحفوظة لا يمنع الإدخال اليدوي.
    }
  }

  /// العودة من وضع الاختيار إلى الإدخال اليدوي واختيار شركة أخرى.
  void _resetPick() {
    setState(() {
      _picked = false;
      _national = false;
      _earthlink = false;
      _pickedHost = '';
      _company.clear();
      _server.clear();
      _label.clear();
      _error = null;
    });
  }

  @override
  void dispose() {
    _company.dispose();
    _label.dispose();
    _server.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  static String _key(String server, String user) =>
      '${server.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '')}|'
      '${user.trim().toLowerCase()}';

  /// ربط المشروع الوطني بمحرّكه الخاص: يتحقق من الدخول ويحفظ الإعدادات.
  /// لا يُنشئ كارت ساس؛ مشتركوه يُزامَنون تلقائياً عند الدخول.
  Future<void> _saveNational() async {
    if (_user.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'أدخل اسم المستخدم وكلمة المرور');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final settings = SasProjectNationalSettings(
      username: _user.text.trim(),
      password: _pass.text,
    );
    final service = SasProjectNationalService(settings);
    try {
      await service.login().timeout(const Duration(seconds: 45));
      await settings.save();
      // مزامنة أولى في الخلفية لتظهر مشتركوه دون انتظار إعادة الدخول.
      unawaited(SasProjectNationalService.syncSaved());
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      service.dispose();
      if (mounted) setState(() => _saving = false);
    }
  }

  /// ربط إيرثلنك: يتحقق من الدخول للوحة الوكلاء ويحفظ الإعدادات.
  /// لا يُنشئ كارت ساس؛ العمليات تتم من شاشة إيرثلنك بالبحث عن المشترك.
  Future<void> _saveEarthlink() async {
    if (_user.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'أدخل اسم المستخدم وكلمة المرور');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final settings = EarthlinkResellerSettings(
      username: _user.text.trim(),
      password: _pass.text,
    );
    final service = EarthlinkResellerService.fromSettings(settings);
    try {
      await service.login().timeout(const Duration(seconds: 45));
      await settings.save();
      // مزامنة أولى فوراً، ونُظهر نتيجتها (عدد المشتركين) أو خطأها بدل الصمت.
      int? count;
      String? syncError;
      try {
        final users = await service.fetchSubscribers().timeout(
          const Duration(seconds: 60),
        );
        count = await service.syncSubscribers(users);
      } catch (e) {
        syncError = '$e';
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            syncError == null
                ? 'تم ربط إيرثلنك ومزامنة ${count ?? 0} مشترك'
                : 'رُبط إيرثلنك، لكن فشلت المزامنة: $syncError',
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      service.dispose();
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    if (_national) {
      await _saveNational();
      return;
    }
    if (_earthlink) {
      await _saveEarthlink();
      return;
    }
    if (_label.text.trim().isEmpty ||
        _server.text.trim().isEmpty ||
        _user.text.trim().isEmpty ||
        _pass.text.isEmpty) {
      setState(() => _error = 'أكمل اسم الساس والرابط واليوزر وكلمة المرور');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final account = SasSettings(
        accountId: widget.primary
            ? ''
            : (widget.existing?.accountId ?? SasSettings.newAccountId()),
        company: _company.text.trim(),
        label: _label.text.trim(),
        serverUrl: _server.text.trim(),
        username: _user.text.trim(),
        password: _pass.text,
        webProxyUrl: widget.existing?.webProxyUrl.trim().isNotEmpty == true
            ? widget.existing!.webProxyUrl
            : widget.proxyUrl,
      );
      final key = _key(account.serverUrl, account.username);
      if (widget.others.any(
        (o) =>
            o.accountId != account.accountId &&
            _key(o.serverUrl, o.username) == key,
      )) {
        throw SasApiException('هذا الساس مربوط مسبقاً');
      }

      await SasApiService(account).login().timeout(const Duration(seconds: 20));
      await TrialGuardService.ensureSasAllowed(
        account.serverUrl,
        account.username,
      );
      if (account.isPrimary) {
        await account.save();
        AppStore.sasUsername = account.username;
        await AppStore.save();
      } else {
        await account.saveExtra();
      }
      // يُضاف الساس للدليل المشترك ليظهر لبقية الوكلاء (اسم ورابط فقط).
      unawaited(
        SasDirectoryService.publish(
          company: account.company,
          serverUrl: account.serverUrl,
        ),
      );
      if (mounted) Navigator.pop(context, account);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  InputDecoration _dec(String label, IconData icon) => InputDecoration(
    labelText: label,
    prefixIcon: Icon(icon),
    border: const OutlineInputBorder(),
  );

  @override
  Widget build(BuildContext context) {
    final title = widget.existing != null
        ? 'تعديل الساس'
        : (widget.primary ? 'ربط الساس' : 'إضافة ساس آخر');
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_picked) ...[
                _PickedCompanyHeader(
                  company: _company.text,
                  host: _pickedHost,
                  national: _national,
                  onChange: _saving ? null : _resetPick,
                ),
                const SizedBox(height: 10),
              ] else ...[
                _CompanyPickerButton(
                  directory: _directory,
                  onPicked: _pickCompany,
                  onNationalProject: _pickNationalProject,
                  onEarthlink: _pickEarthlink,
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _company,
                  decoration: _dec('اسم الشركة', Icons.business_outlined),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _label,
                  decoration: _dec(
                    'اسم الساس (مثلاً: ساس الكرادة)',
                    Icons.label_outline,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _server,
                  keyboardType: TextInputType.url,
                  decoration: _dec('رابط SAS', Icons.dns_outlined),
                ),
                const SizedBox(height: 10),
              ],
              TextField(
                controller: _user,
                decoration: _dec('اسم المستخدم', Icons.person_outline),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _pass,
                obscureText: _hide,
                decoration: _dec('كلمة المرور', Icons.lock_outline).copyWith(
                  helperText: 'تُحفظ على هذا الجهاز فقط',
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _hide = !_hide),
                    icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cable),
            label: const Text('اتصال وحفظ'),
          ),
        ],
      ),
    );
  }
}

/// ترويسة الشركة المختارة من الدليل: اسمها ورابطها المحفوظ، مع زر لتغييرها.
/// بعدها يُدخل الوكيل اسم المستخدم وكلمة المرور فقط.
class _PickedCompanyHeader extends StatelessWidget {
  const _PickedCompanyHeader({
    required this.company,
    required this.host,
    required this.national,
    required this.onChange,
  });

  final String company;
  final String host;
  final bool national;
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: colors.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              national ? Icons.account_tree_outlined : Icons.verified_outlined,
              color: colors.onSecondaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    company,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: colors.onSecondaryContainer,
                    ),
                  ),
                  Text(
                    national ? 'المشروع الوطني — ربط خاص' : 'رابط محفوظ: $host',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSecondaryContainer.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ),
            if (onChange != null)
              TextButton(
                key: const ValueKey('change-company'),
                onPressed: onChange,
                child: const Text('تغيير'),
              ),
          ],
        ),
      ),
    );
  }
}

/// زر «اختر من دليل الشركات» يفتح قائمة بحث بالشعارات. يظهر فقط حين يتوفّر
/// الدليل؛ فشله يُخفيه ويبقى الإدخال اليدوي.
class _CompanyPickerButton extends StatelessWidget {
  const _CompanyPickerButton({
    required this.directory,
    required this.onPicked,
    required this.onNationalProject,
    required this.onEarthlink,
  });

  final Future<List<DirectoryCompany>>? directory;
  final ValueChanged<DirectoryCompany> onPicked;

  /// عند اختيار «المشروع الوطني» من القائمة (شاشة ربط خاصة).
  final VoidCallback onNationalProject;

  /// عند اختيار «إيرثلنك» من القائمة (شاشة ربط خاصة).
  final VoidCallback onEarthlink;

  Future<void> _open(BuildContext context, List<DirectoryCompany> all) async {
    final picked = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CompanyPickerSheet(companies: all),
    );
    if (picked is _NationalProjectPick) {
      onNationalProject();
    } else if (picked is _EarthlinkPick) {
      onEarthlink();
    } else if (picked is DirectoryCompany) {
      onPicked(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    // القائمة تتضمّن دائماً «المشروع الوطني»، فالزر يظهر دوماً حتى أثناء
    // تحميل الدليل البعيد.
    return FutureBuilder<List<DirectoryCompany>>(
      future: directory,
      builder: (context, snapshot) {
        final all = snapshot.data ?? const <DirectoryCompany>[];
        return SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const ValueKey('pick-company-directory'),
            onPressed: () => _open(context, all),
            icon: const Icon(Icons.apartment_outlined),
            label: const Text('اختر من دليل الشركات'),
          ),
        );
      },
    );
  }
}

/// قائمة بحث عن شركة في الدليل مع شعارها، لتعبئة الاسم والرابط.
class _CompanyPickerSheet extends StatefulWidget {
  const _CompanyPickerSheet({required this.companies});

  final List<DirectoryCompany> companies;

  @override
  State<_CompanyPickerSheet> createState() => _CompanyPickerSheetState();
}

class _CompanyPickerSheetState extends State<_CompanyPickerSheet> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<DirectoryCompany> get _filtered {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return widget.companies;
    return widget.companies
        .where(
          (c) =>
              c.company.toLowerCase().contains(q) ||
              c.host.toLowerCase().contains(q),
        )
        .toList();
  }

  /// «المشروع الوطني» مثبّت أعلى القائمة؛ يظهر ما لم يستبعده البحث.
  bool get _showNational {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return 'المشروع الوطني'.contains(q) ||
        'وطني'.contains(q) ||
        'national'.contains(q);
  }

  /// «إيرثلنك» مثبّت أعلى القائمة أيضاً؛ يظهر ما لم يستبعده البحث.
  bool get _showEarthlink {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return 'إيرثلنك'.contains(q) ||
        'ايرثلنك'.contains(q) ||
        'earthlink'.contains(q) ||
        'earthlink.iq'.contains(q);
  }

  /// بطاقات العناصر المثبّتة أعلى القائمة (المشروع الوطني ثم إيرثلنك).
  List<Widget> _pinnedTiles(BuildContext context) => [
    if (_showNational)
      ListTile(
        key: const ValueKey('directory-national-project'),
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: const Icon(Icons.account_tree_outlined),
        ),
        title: const Text('المشروع الوطني'),
        subtitle: const Text('admin.ftth.iq — شاشة ربط خاصة'),
        trailing: const Icon(Icons.verified, size: 18),
        onTap: () => Navigator.pop(context, _nationalProjectPick),
      ),
    if (_showEarthlink)
      ListTile(
        key: const ValueKey('directory-earthlink'),
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: const Icon(Icons.router_outlined),
        ),
        title: const Text('إيرثلنك'),
        subtitle: const Text('admin.earthlink.iq — شاشة ربط خاصة'),
        trailing: const Icon(Icons.verified, size: 18),
        onTap: () => Navigator.pop(context, _earthlinkPick),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    final pinned = _pinnedTiles(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          builder: (context, controller) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  children: [
                    const Text(
                      'دليل الشركات',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _search,
                      autofocus: true,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        hintText: 'ابحث باسم الشركة أو الرابط',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: (filtered.isEmpty && pinned.isEmpty)
                    ? const Center(child: Text('لا توجد شركة مطابقة'))
                    : ListView.builder(
                        controller: controller,
                        itemCount: filtered.length + pinned.length,
                        itemBuilder: (context, i) {
                          if (i < pinned.length) return pinned[i];
                          final c = filtered[i - pinned.length];
                          return ListTile(
                            key: ValueKey('directory-${c.host}'),
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: Image.network(
                                c.logo,
                                width: 32,
                                height: 32,
                                errorBuilder: (_, _, _) =>
                                    const Icon(Icons.dns_rounded),
                              ),
                            ),
                            title: Text(c.company),
                            subtitle: Text(
                              c.host,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: c.seed
                                ? const Icon(Icons.verified, size: 18)
                                : null,
                            onTap: () => Navigator.pop(context, c),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum DeleteSubscribersChoice { keepDebtors, deleteEverything }

/// يسأل الوكيل في كل حذف عن المدينين: إبقاؤهم بديونهم أو حذفهم معها.
/// عند حذف ساس تظهر الشركة فوق العنوان مع الملاحظات الخاصة به.
class DeleteSubscribersDialog extends StatelessWidget {
  const DeleteSubscribersDialog({
    super.key,
    required this.all,
    required this.total,
    required this.debtors,
    this.title,
    this.company = '',
    this.notes = const [],
  });

  final bool all;
  final int total;
  final List<Subscriber> debtors;
  final String? title;
  final String company;
  final List<String> notes;

  @override
  Widget build(BuildContext context) {
    final debt = debtors.fold<double>(0, (sum, s) => sum + s.remaining);
    final hasDebtors = debtors.isNotEmpty;
    final colors = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (company.trim().isNotEmpty)
              Text(
                company.trim(),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colors.primary,
                ),
              ),
            Text(title ?? (all ? 'حذف جميع المشتركين؟' : 'حذف مشتركي SAS؟')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (total > 0)
              Text(
                all
                    ? 'سيُحذف $total مشترك من التطبيق. لا يمكن التراجع.'
                    : 'سيُحذف $total مشترك من هذا الساس، وتبقى البيانات المحلية.',
              ),
            for (final note in notes) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 18, color: colors.primary),
                  const SizedBox(width: 6),
                  Expanded(child: Text(note)),
                ],
              ),
            ],
            if (hasDebtors) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'بينهم ${debtors.length} مدين بمجموع ${moneyText(debt)}.\n'
                  'إبقاؤهم يحفظ ديونهم ووصولاتهم في قائمة الديون كمشتركين '
                  'سابقين، ويمكن تسديدها لاحقاً.',
                  style: TextStyle(color: Colors.orange.shade900),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          if (hasDebtors)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              onPressed: () => Navigator.pop(
                context,
                DeleteSubscribersChoice.deleteEverything,
              ),
              child: const Text('حذف الجميع مع ديونهم'),
            ),
          FilledButton(
            style: hasDebtors
                ? null
                : FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(
              context,
              hasDebtors
                  ? DeleteSubscribersChoice.keepDebtors
                  : DeleteSubscribersChoice.deleteEverything,
            ),
            child: Text(hasDebtors ? 'حذف مع إبقاء المدينين' : 'حذف'),
          ),
        ],
      ),
    );
  }
}

/// يختار الوكيل ساساً حين يربط أكثر من واحد؛ مع ساس واحد يُرجع مباشرة.
/// null إن ألغى الاختيار أو لم يربط أي ساس.
Future<SasSettings?> pickSasAccount(
  BuildContext context, {
  String title = 'اختر الساس',
  Future<List<SasSettings>> Function()? loadAccounts,
}) async {
  final accounts = await (loadAccounts ?? SasSettings.loadAll)();
  if (accounts.length <= 1 || !context.mounted) {
    return accounts.isEmpty ? null : accounts.first;
  }
  return showModalBottomSheet<SasSettings>(
    context: context,
    builder: (sheetContext) => Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            for (final account in accounts)
              ListTile(
                key: ValueKey('pick-account-${account.accountId}'),
                leading: const Icon(Icons.dns_rounded),
                title: Text(account.displayName),
                subtitle: Text(
                  account.company.trim().isNotEmpty
                      ? account.company.trim()
                      : account.username,
                ),
                onTap: () => Navigator.pop(sheetContext, account),
              ),
          ],
        ),
      ),
    ),
  );
}

/// بطاقة مزوّد خاص (FTTH/إيرثلنك) في قائمة الساسات المربوطة: الاسم والمضيف
/// وعدد مشتركيه وزر مزامنة. إعداداته منفصلة، فلا يملك خيارات بطاقة ساس كاملة.
class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.title,
    required this.host,
    required this.icon,
    required this.count,
    required this.busy,
    required this.enabled,
    required this.onSync,
    required this.onEdit,
    required this.onUnlink,
  });

  final String title;
  final String host;
  final IconData icon;
  final int count;
  final bool busy;
  final bool enabled;
  final VoidCallback onSync;
  final VoidCallback onEdit;
  final VoidCallback onUnlink;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: colors.primaryContainer,
          child: Icon(icon, color: colors.onPrimaryContainer),
        ),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text('$host • $count مشترك'),
        trailing: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : PopupMenuButton<String>(
                enabled: enabled,
                icon: const Icon(Icons.more_vert),
                onSelected: (v) => switch (v) {
                  'sync' => onSync(),
                  'edit' => onEdit(),
                  'unlink' => onUnlink(),
                  _ => null,
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'sync',
                    child: Row(
                      children: [
                        Icon(Icons.sync, size: 20),
                        SizedBox(width: 8),
                        Text('مزامنة'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: [
                        Icon(Icons.edit_outlined, size: 20),
                        SizedBox(width: 8),
                        Text('تعديل'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'unlink',
                    child: Row(
                      children: [
                        Icon(Icons.link_off, color: colors.error, size: 20),
                        const SizedBox(width: 8),
                        const Text('فصل'),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
