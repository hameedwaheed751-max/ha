import 'package:flutter/material.dart';

import '../models.dart';
import '../sas_api_service.dart';
import '../sas_sync_service.dart';
import '../services/trial_guard_service.dart';

const _defaultProxyUrl =
    'https://netagent-sas-proxy.wakeel-net-hamwdy.workers.dev';

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

  List<SasSettings> get _accounts => [
    if (_primary != null && _primary!.isConfigured) _primary!,
    ..._extras,
  ];

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
      if (!mounted) return;
      setState(() {
        _primary = primary;
        _extras = extras;
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  int _countIn(SasSettings account) => AppStore.subscribers
      .where(
        (s) => s.source == 'sas' && s.sasPresence.contains(account.accountId),
      )
      .length;

  Future<void> _add() async {
    final primaryReady = _primary?.isConfigured == true;
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
                              'الساسات المربوطة (${accounts.length})',
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
                      if (accounts.isEmpty)
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
  });

  final SasSettings? existing;
  final bool primary;
  final List<SasSettings> others;
  final String proxyUrl;

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

  Future<void> _save() async {
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
              TextField(
                controller: _user,
                decoration: _dec('اسم المستخدم', Icons.person_outline),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _pass,
                obscureText: _hide,
                decoration: _dec('كلمة المرور', Icons.lock_outline).copyWith(
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
