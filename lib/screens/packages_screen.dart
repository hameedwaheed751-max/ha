import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../sas_api_service.dart';
import '../sas_sync_service.dart';

/// باقات الساس تُضاف تلقائياً عند المزامنة، والوكيل يُدخل سعر كل باقة يدوياً.
class PackagesScreen extends StatefulWidget {
  const PackagesScreen({super.key});

  @override
  State<PackagesScreen> createState() => _PackagesScreenState();
}

class _PackagesScreenState extends State<PackagesScreen> {
  final _priceControllers = <PackagePlan, TextEditingController>{};
  bool _dirty = false;
  bool _saving = false;
  bool _syncing = false;

  @override
  void dispose() {
    for (final controller in _priceControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _priceController(PackagePlan package) {
    return _priceControllers.putIfAbsent(
      package,
      () => TextEditingController(
        text: package.price > 0 ? package.price.toStringAsFixed(0) : '',
      ),
    );
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _save({bool quiet = false}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await AppStore.save();
      if (!mounted) return;
      setState(() => _dirty = false);
      if (!quiet) _snack('تم حفظ أسعار الباقات');
    } catch (e) {
      _snack('تعذر الحفظ: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _syncFromSas() async {
    final settings = await SasSettings.load();
    if (settings.username.trim().isEmpty || settings.password.isEmpty) {
      _snack('أكمل إعدادات ربط SAS أولاً');
      return;
    }
    setState(() => _syncing = true);
    try {
      final before = AppStore.packages.where((p) => p.fromSas).length;
      final added = await SasSyncService.syncPackages(SasApiService(settings));
      final now = AppStore.packages.where((p) => p.fromSas).length;
      if (!mounted) return;
      _snack(
        now == 0 && before == 0
            ? 'تعذرت قراءة باقات الساس'
            : added == 0
            ? 'باقات الساس محدّثة ($now باقة)'
            : 'أُضيفت $added باقة جديدة من الساس، أدخل أسعارها',
      );
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _addManual() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _AddPackageDialog(),
    );
    if (name == null || name.isEmpty) return;
    AppStore.addPackage(PackagePlan(name: name, price: 0));
    await _save(quiet: true);
  }

  Future<void> _delete(PackagePlan package) async {
    AppStore.removePackage(package);
    _priceControllers.remove(package)?.dispose();
    await _save(quiet: true);
  }

  Widget _tile(PackagePlan package, ColorScheme colors) {
    final missingPrice = package.price <= 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    package.name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    package.fromSas
                        ? (missingPrice ? 'من الساس — أدخل السعر' : 'من الساس')
                        : 'يدوية — غير موجودة في الساس',
                    style: TextStyle(
                      fontSize: 12,
                      color: package.fromSas && missingPrice
                          ? colors.error
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 130,
              child: TextField(
                controller: _priceController(package),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'السعر',
                  suffixText: 'د.ع',
                  border: const OutlineInputBorder(),
                  enabledBorder: missingPrice
                      ? OutlineInputBorder(
                          borderSide: BorderSide(color: colors.error),
                        )
                      : null,
                ),
                onChanged: (value) {
                  setState(() {
                    package.price = double.tryParse(value) ?? 0;
                    _dirty = true;
                  });
                },
              ),
            ),
            if (!package.fromSas)
              IconButton(
                tooltip: 'حذف',
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                onPressed: () => _delete(package),
              )
            else
              const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final sas = AppStore.packages.where((p) => p.fromSas).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final manual = AppStore.packages.where((p) => !p.fromSas).toList();
    final unpriced = sas.where((p) => p.price <= 0).length;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _save(quiet: true);
        if (mounted) Navigator.of(this.context).pop();
      },
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('الباقات'),
            centerTitle: true,
            actions: [
              IconButton(
                tooltip: 'جلب الباقات من الساس',
                onPressed: _syncing ? null : _syncFromSas,
                icon: _syncing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
              ),
            ],
          ),
          floatingActionButton: _dirty
              ? FloatingActionButton.extended(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.save),
                  label: const Text('حفظ الأسعار'),
                )
              : FloatingActionButton(
                  tooltip: 'إضافة باقة يدوية',
                  onPressed: _addManual,
                  child: const Icon(Icons.add),
                ),
          body: AppStore.packages.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'لا توجد باقات بعد.\nاضغط زر المزامنة أعلاه لجلب باقات '
                      'الساس، ثم أدخل سعر كل باقة.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
                  children: [
                    Text(
                      'تُضاف باقات الساس تلقائياً عند كل مزامنة. السعر الذي '
                      'تُدخله هو سعر البيع للمشترك ويُقترح عند التفعيل.',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                    if (unpriced > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '$unpriced باقة بدون سعر',
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    if (sas.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        'باقات الساس (${sas.length})',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      for (final package in sas) _tile(package, colors),
                    ],
                    if (manual.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        'باقات يدوية (${manual.length})',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      for (final package in manual) _tile(package, colors),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

/// الحقل يُتلف مع النافذة بعد انتهاء إغلاقها، لا قبله.
class _AddPackageDialog extends StatefulWidget {
  const _AddPackageDialog();

  @override
  State<_AddPackageDialog> createState() => _AddPackageDialogState();
}

class _AddPackageDialogState extends State<_AddPackageDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('إضافة باقة يدوية'),
        content: TextField(
          controller: _name,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'اسم الباقة',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _name.text.trim()),
            child: const Text('إضافة'),
          ),
        ],
      ),
    );
  }
}
