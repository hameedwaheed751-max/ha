import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models.dart';
import '../services/backup_restore_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController name, phone, address, footer;
  bool _isSaving = false;
  bool _isBackupBusy = false;
  bool? _saveFailed;
  String? _saveMessage;

  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: AppStore.officeName);
    phone = TextEditingController(text: AppStore.officePhone);
    address = TextEditingController(text: AppStore.officeAddress);
    footer = TextEditingController(text: AppStore.receiptFooter);
  }

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    address.dispose();
    footer.dispose();
    super.dispose();
  }

  InputDecoration dec(String x) => InputDecoration(
        labelText: x,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      );

  Widget _sectionTitle(String title, IconData icon) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          ],
        ),
      );

  Future<void> _saveSettings() async {
    setState(() {
      _isSaving = true;
      _saveMessage = null;
      _saveFailed = null;
    });
    try {
      AppStore.officeName = name.text.trim();
      AppStore.officePhone = phone.text.trim();
      AppStore.officeAddress = address.text.trim();
      AppStore.receiptFooter = footer.text.trim();
      await AppStore.save();
      if (!mounted) return;
      setState(() {
        _saveFailed = AppStore.lastSaveSyncError != null;
        _saveMessage = AppStore.lastSaveSyncError != null
            ? 'حُفظت البيانات على الجهاز، لكن تعذرت المزامنة. تحقق من الاتصال ثم أعد المحاولة.'
            : 'تم حفظ الإعدادات ومزامنتها بنجاح.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saveFailed = true;
        _saveMessage = 'تعذر حفظ الإعدادات. تحقق من البيانات وحاول مجددًا.';
      });
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _exportBackup() async {
    setState(() => _isBackupBusy = true);
    try {
      final backup = await BackupRestoreService().createBackup();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final savedPath = await FileSaver.instance.saveFile(
        name: 'NetAgent_backup_$stamp',
        bytes: Uint8List.fromList(
          utf8.encode(const JsonEncoder.withIndent('  ').convert(backup)),
        ),
        fileExtension: 'json',
        mimeType: MimeType.json,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            savedPath.isEmpty
                ? 'تم إنشاء النسخة الاحتياطية.'
                : 'تم إنشاء النسخة الاحتياطية: $savedPath',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر إنشاء النسخة الاحتياطية: $error')),
      );
    } finally {
      if (mounted) setState(() => _isBackupBusy = false);
    }
  }

  Future<void> _restoreBackup() async {
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
      if (selection == null || selection.files.isEmpty) return;
      final bytes = selection.files.single.bytes;
      if (bytes == null) {
        throw const FormatException('تعذر قراءة الملف المحدد.');
      }
      final contents = utf8.decode(bytes);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('تأكيد استعادة النسخة'),
            content: const Text(
              'ستُستبدل بيانات المشتركين والباقات والسجلات والإعدادات المكتبية الحالية بمحتوى النسخة الاحتياطية. هل تريد المتابعة؟',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('استعادة'),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true || !mounted) return;

      setState(() => _isBackupBusy = true);
      final result = await BackupRestoreService().restoreBackup(contents);
      if (!mounted) return;
      setState(() {
        name.text = AppStore.officeName;
        phone.text = AppStore.officePhone;
        address.text = AppStore.officeAddress;
        footer.text = AppStore.receiptFooter;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.syncWarning == null
                ? 'تمت استعادة النسخة الاحتياطية بنجاح.'
                : 'تمت الاستعادة محلياً، لكن ${result.syncWarning}',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذرت استعادة النسخة الاحتياطية: $error')),
      );
    } finally {
      if (mounted) setState(() => _isBackupBusy = false);
    }
  }

  Future<void> pickLogo() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
      maxWidth: 900,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    setState(() => AppStore.officeLogoBase64 = base64Encode(bytes));
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: const Text('إعدادات المكتب'), centerTitle: true),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _sectionTitle('هوية المكتب', Icons.business_outlined),
              Center(
                child: InkWell(
                  borderRadius: BorderRadius.circular(60),
                  onTap: pickLogo,
                  child: CircleAvatar(
                    radius: 52,
                    backgroundColor: Colors.blue.shade50,
                    backgroundImage: AppStore.officeLogoBase64.isNotEmpty
                        ? MemoryImage(base64Decode(AppStore.officeLogoBase64))
                        : null,
                    child: AppStore.officeLogoBase64.isEmpty
                        ? const Icon(Icons.add_photo_alternate_outlined, size: 38)
                        : null,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Center(child: Text('اضغط لاختيار شعار المكتب')),
              if (AppStore.officeLogoBase64.isNotEmpty)
                TextButton.icon(
                  onPressed: () => setState(() => AppStore.officeLogoBase64 = ''),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('حذف الشعار'),
                ),
              const SizedBox(height: 14),
              TextField(controller: name, decoration: dec('اسم المكتب')),
              const SizedBox(height: 22),
              _sectionTitle('بيانات التواصل', Icons.contact_phone_outlined),
              const SizedBox(height: 12),
              TextField(controller: phone, keyboardType: TextInputType.phone, decoration: dec('رقم هاتف المكتب')),
              const SizedBox(height: 12),
              TextField(controller: address, decoration: dec('عنوان المكتب')),
              const SizedBox(height: 22),
              _sectionTitle('تفاصيل الإيصال', Icons.receipt_long_outlined),
              const SizedBox(height: 12),
              TextField(controller: footer, maxLines: 2, decoration: dec('ملاحظة أسفل الوصل')),
              const SizedBox(height: 22),
              _sectionTitle('النسخ الاحتياطي والاستعادة', Icons.backup_outlined),
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text(
                  'تتضمن النسخة بيانات المشتركين والفواتير. احفظ الملف في مكان آمن؛ ولا تتضمن كلمات مرور SAS.',
                ),
              ),
              SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _isBackupBusy ? null : _exportBackup,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('إنشاء نسخة احتياطية'),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _isBackupBusy ? null : _restoreBackup,
                  icon: _isBackupBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.restore_page_outlined),
                  label: Text(_isBackupBusy ? 'جارٍ تنفيذ العملية' : 'استعادة نسخة احتياطية'),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: _isSaving ? null : _saveSettings,
                  icon: _isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save),
                  label: Text(_isSaving ? 'جارٍ الحفظ' : 'حفظ الإعدادات'),
                ),
              ),
              if (_saveMessage != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: (_saveFailed! ? Colors.red : Colors.green)
                        .withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: (_saveFailed! ? Colors.red : Colors.green)
                          .withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _saveFailed! ? Icons.error_outline : Icons.check_circle_outline,
                        color: _saveFailed! ? Colors.red : Colors.green,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_saveMessage!)),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      );
}
