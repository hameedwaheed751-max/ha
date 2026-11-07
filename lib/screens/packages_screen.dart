import 'dart:async';

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
  Timer? _autoSave;

  @override
  void dispose() {
    _autoSave?.cancel();
    if (_dirty) unawaited(AppStore.save());
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
    _autoSave?.cancel();
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await AppStore.save();
      if (!mounted) return;
      setState(() => _dirty = false);
      final cloudError = AppStore.lastSaveSyncError;
      if (cloudError != null) {
        _snack('حُفظت الأسعار على الجهاز فقط: $cloudError');
      } else if (!quiet) {
        _snack('تم حفظ أسعار الباقات');
      }
    } catch (e) {
      _snack('تعذر الحفظ: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _scheduleSave() {
    _autoSave?.cancel();
    _autoSave = Timer(
      const Duration(milliseconds: 1200),
      () => _save(quiet: true),
    );
  }

  Future<void> _syncFromSas() async {
    final accounts = await SasSettings.loadAll();
    if (accounts.isEmpty) {
      _snack('أكمل إعدادات ربط SAS أولاً');
      return;
    }
    if (_dirty) await _save(quiet: true);
    setState(() => _syncing = true);
    try {
      final before = AppStore.packages.where((p) => p.fromSas).length;
      var added = 0;
      for (final settings in accounts) {
        added += await SasSyncService.syncPackages(
          SasApiService(settings),
          // قائمة ساس واحد لا تمثل كل الباقات حين يوجد أكثر من ساس.
          complete: accounts.length == 1,
        );
      }
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
                        : 'غير موجودة في الساس',
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
                inputFormatters: [
                  const _WesternDigitsFormatter(),
                  FilteringTextInputFormatter.digitsOnly,
                ],
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
                  _scheduleSave();
                },
                onSubmitted: (_) => _save(quiet: true),
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
    final others = AppStore.packages.where((p) => !p.fromSas).toList();
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
              : null,
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
                      'تُدخله هو سعر البيع للمشترك ويُقترح عند التفعيل، '
                      'ويُحفظ تلقائياً.',
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
                    if (others.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        'باقات غير موجودة في الساس (${others.length})',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      for (final package in others) _tile(package, colors),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

/// يحوّل الأرقام العربية والفارسية إلى إنجليزية حتى لا يمسحها فلتر الأرقام.
class _WesternDigitsFormatter extends TextInputFormatter {
  const _WesternDigitsFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    const persian = '۰۱۲۳۴۵۶۷۸۹';
    final buffer = StringBuffer();
    for (final char in newValue.text.split('')) {
      final a = arabic.indexOf(char);
      final f = persian.indexOf(char);
      buffer.write(a >= 0 ? '$a' : (f >= 0 ? '$f' : char));
    }
    final text = buffer.toString();
    if (text == newValue.text) return newValue;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
