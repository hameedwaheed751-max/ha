import 'package:flutter/material.dart';

import '../models.dart';
import '../sas_api_service.dart';
import '../sas_sync_service.dart';
import '../services/trial_guard_service.dart';
import 'sas_settings_screen.dart';

/// الساسات الإضافية للوكيل؛ الساس الأساسي يبقى في إعدادات الاتصال أعلاه.
class ExtraSasSection extends StatefulWidget {
  const ExtraSasSection({super.key, this.planAllowsExtra, this.loadAccounts});

  /// للاختبار؛ الافتراضي يقرأ خطة الوكيل.
  final bool Function()? planAllowsExtra;
  final Future<List<SasSettings>> Function()? loadAccounts;

  /// التجربة المجانية تسمح بساس واحد؛ الإضافي للخطط المدفوعة فقط.
  static bool defaultPlanAllowsExtra() =>
      TrialGuardService.isAdmin ||
      (AppStore.subscriptionStatus == 'active' &&
          !TrialGuardService.onFreeTrial);

  static const paidPlanMessage =
      'إضافة ساس آخر تحتاج إلى خطة مدفوعة. التجربة المجانية تسمح بساس واحد فقط.';

  @override
  State<ExtraSasSection> createState() => _ExtraSasSectionState();
}

class _ExtraSasSectionState extends State<ExtraSasSection> {
  List<SasSettings> _accounts = const [];
  bool _loading = true;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final accounts = await (widget.loadAccounts ?? SasSettings.loadExtras)();
      if (mounted) setState(() => _accounts = accounts);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _add() async {
    final allowed =
        (widget.planAllowsExtra ?? ExtraSasSection.defaultPlanAllowsExtra)();
    if (!allowed) {
      await showDialog<void>(
        context: context,
        builder: (context) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            icon: const Icon(Icons.workspace_premium_outlined),
            title: const Text('تحتاج إلى خطة مدفوعة'),
            content: const Text(ExtraSasSection.paidPlanMessage),
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
    if (AppStore.sasUsername.trim().isEmpty) {
      _snack('اربط الساس الأساسي أولاً من إعدادات الاتصال أعلاه');
      return;
    }
    await _edit(null);
  }

  Future<void> _edit(SasSettings? existing) async {
    final saved = await showDialog<SasSettings>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ExtraSasDialog(existing: existing, others: _accounts),
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

  Future<void> _delete(SasSettings account) async {
    final total = AppStore.countToDelete(
      all: false,
      account: account.accountId,
    );
    DeleteSubscribersChoice? choice = DeleteSubscribersChoice.deleteEverything;
    if (total > 0) {
      choice = await showDialog<DeleteSubscribersChoice>(
        context: context,
        builder: (_) => DeleteSubscribersDialog(
          all: false,
          total: total,
          debtors: AppStore.debtorsAmong(
            all: false,
            account: account.accountId,
          ),
          title: 'حذف ${account.displayName}؟',
        ),
      );
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: Text('حذف ${account.displayName}؟'),
            content: const Text('لا يوجد مشتركون من هذا الساس في التطبيق.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('حذف'),
              ),
            ],
          ),
        ),
      );
      if (ok != true) choice = null;
    }
    if (choice == null) return;
    setState(() => _busyId = account.accountId);
    try {
      await AppStore.deleteSasSubscribersOnly(
        account: account.accountId,
        keepDebtors: choice == DeleteSubscribersChoice.keepDebtors,
      );
      await SasSettings.removeExtra(account.accountId);
      _snack('تم حذف ${account.displayName}');
      await _reload();
    } catch (e) {
      _snack('تعذر الحذف: $e');
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'ساسات إضافية',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              'لمن يعمل على أكثر من ساس: مشتركو كل ساس يظهرون في نفس القائمة، '
              'وكل عملية تُرسل إلى ساس المشترك نفسه.',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else
              for (final account in _accounts)
                Card(
                  key: ValueKey('extra-${account.accountId}'),
                  color: colors.surfaceContainerHighest,
                  child: ListTile(
                    leading: const Icon(Icons.dns_outlined),
                    title: Text(
                      account.displayName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      '${account.username} • ${account.serverUrl}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: _busyId == account.accountId
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : PopupMenuButton<String>(
                            onSelected: (action) => switch (action) {
                              'sync' => _sync(account),
                              'edit' => _edit(account),
                              _ => _delete(account),
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'sync',
                                child: Text('مزامنة'),
                              ),
                              PopupMenuItem(
                                value: 'edit',
                                child: Text('تعديل'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text(
                                  'حذف الساس',
                                  style: TextStyle(color: Colors.red),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: _busyId == null ? _add : null,
              icon: const Icon(Icons.add),
              label: const Text('إضافة ساس آخر'),
            ),
          ],
        ),
      ),
    );
  }
}

/// إدخال ساس إضافي: يُتحقق من الدخول ومن أن الساس غير مربوط بوكيل آخر قبل حفظه.
class ExtraSasDialog extends StatefulWidget {
  const ExtraSasDialog({super.key, this.existing, this.others = const []});

  final SasSettings? existing;
  final List<SasSettings> others;

  @override
  State<ExtraSasDialog> createState() => _ExtraSasDialogState();
}

class _ExtraSasDialogState extends State<ExtraSasDialog> {
  late final _label = TextEditingController(text: widget.existing?.label);
  late final _server = TextEditingController(text: widget.existing?.serverUrl);
  late final _user = TextEditingController(text: widget.existing?.username);
  late final _pass = TextEditingController(text: widget.existing?.password);
  bool _saving = false;
  bool _hide = true;
  String? _error;

  @override
  void dispose() {
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
      setState(() => _error = 'أكمل الاسم والرابط واليوزر وكلمة المرور');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final primary = await SasSettings.load();
      final account = SasSettings(
        accountId: widget.existing?.accountId ?? SasSettings.newAccountId(),
        label: _label.text.trim(),
        serverUrl: _server.text.trim(),
        username: _user.text.trim(),
        password: _pass.text,
        webProxyUrl: primary.webProxyUrl,
      );
      final key = _key(account.serverUrl, account.username);
      final duplicate =
          _key(primary.serverUrl, primary.username) == key ||
          widget.others.any(
            (o) =>
                o.accountId != account.accountId &&
                _key(o.serverUrl, o.username) == key,
          );
      if (duplicate) throw SasApiException('هذا الساس مربوط مسبقاً');

      await SasApiService(account).login().timeout(const Duration(seconds: 20));
      await TrialGuardService.ensureSasAllowed(
        account.serverUrl,
        account.username,
      );
      await account.saveExtra();
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
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(widget.existing == null ? 'إضافة ساس آخر' : 'تعديل الساس'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _label,
                decoration: _dec('اسم الساس (مثلاً: ساس الكرادة)', Icons.label),
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
