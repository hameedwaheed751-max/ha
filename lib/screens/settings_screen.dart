import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models.dart';
import '../services/backup_restore_service.dart';
import '../services/whatsapp_notification_dispatcher.dart';
import '../services/waha_notification_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.openWhatsAppLinking = false,
  });

  final bool openWhatsAppLinking;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController name, phone, address, footer;
  bool _isSaving = false;
  bool _isBackupBusy = false;
  bool? _saveFailed;
  String? _saveMessage;
  Timer? _wahaPollTimer;
  Timer? _wahaQrTimer;
  WahaQrCode? _wahaQrCode;
  String _wahaStatus = 'NOT_CREATED';
  String? _wahaPhoneNumber;
  String? _wahaError;
  bool _wahaBusy = false;
  bool _wahaPolling = false;
  bool _wahaQrLoading = false;
  WahaNotificationService? _wahaService;

  bool get _wahaSelected =>
      WhatsAppNotificationDispatcher.configuredProvider == WhatsAppProvider.waha;

  WahaNotificationService get _activeWahaService => _wahaService!;

  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: AppStore.officeName);
    phone = TextEditingController(text: AppStore.officePhone);
    address = TextEditingController(text: AppStore.officeAddress);
    footer = TextEditingController(text: AppStore.receiptFooter);
    if (_wahaSelected || widget.openWhatsAppLinking) {
      _wahaService = WahaNotificationService.forCurrentUser();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refreshWahaSession();
      });
    }
  }

  @override
  void dispose() {
    _wahaPollTimer?.cancel();
    _wahaQrTimer?.cancel();
    _wahaService?.close();
    name.dispose();
    phone.dispose();
    address.dispose();
    footer.dispose();
    super.dispose();
  }

  Future<void> _startWahaSession() async {
    await _performWahaAction(() async {
      final status = await _activeWahaService.startSession();
      _updateWahaStatus(status);
    });
  }

  Future<void> _refreshWahaSession() async {
    await _performWahaAction(() async {
      final status = await _activeWahaService.getSessionStatus();
      _updateWahaStatus(status, refreshQr: true);
    });
  }

  Future<void> _reconnectWahaSession() async {
    await _performWahaAction(() async {
      final status = await _activeWahaService.reconnectSession();
      _updateWahaStatus(status);
    });
  }

  Future<void> _disconnectWahaSession() async {
    final shouldDisconnect = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('فصل حساب WhatsApp؟'),
        content: const Text(
          'سيتم تسجيل الخروج من WhatsApp على هذا الجهاز، وستحتاج إلى مسح رمز QR جديد لإعادة الربط.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('فصل الحساب'),
          ),
        ],
      ),
    );
    if (shouldDisconnect != true || !mounted) return;

    await _performWahaAction(() async {
      final status = await _activeWahaService.disconnectSession();
      _updateWahaStatus(status);
    });
  }

  Future<void> _performWahaAction(Future<void> Function() action) async {
    setState(() {
      _wahaBusy = true;
      _wahaError = null;
    });
    try {
      await action();
    } on WahaGatewayException catch (error) {
      _setWahaError(error.message);
    } catch (_) {
      _setWahaError('تعذر الاتصال بخدمة ربط WhatsApp.');
    } finally {
      if (mounted) setState(() => _wahaBusy = false);
    }
  }

  void _setWahaError(String message, {bool stopPolling = true}) {
    if (stopPolling) {
      _wahaPollTimer?.cancel();
      _wahaPollTimer = null;
      _wahaQrTimer?.cancel();
      _wahaQrTimer = null;
    }
    if (!mounted) return;
    setState(() {
      _wahaError = _friendlyWahaError(message);
      _wahaQrCode = null;
    });
  }

  String _friendlyWahaError(String message) => switch (message) {
        'unauthorized' =>
          'تعذر اعتماد جلسة الدخول. حدّث الحالة، وإذا استمرت المشكلة سجّل الخروج ثم أعد تسجيل الدخول.',
        'forbidden' => 'هذا الحساب غير مخوّل لإدارة جلسة WhatsApp.',
        'authorization_unavailable' =>
          'تعذر التحقق من صلاحية الحساب حالياً. حاول لاحقاً.',
        'origin_not_allowed' =>
          'عنوان التطبيق غير مسموح له بالاتصال ببوابة WhatsApp.',
        'session_status_unavailable' =>
          'تعذر جلب حالة جلسة WhatsApp من الخادم.',
        'session_not_started' => 'لم تبدأ جلسة WhatsApp بعد.',
        'session_start_failed' => 'تعذر بدء جلسة WhatsApp. حاول مرة أخرى.',
        'session_reconnect_failed' => 'تعذرت إعادة ربط WhatsApp. حاول مرة أخرى.',
        'session_disconnect_failed' => 'تعذر فصل حساب WhatsApp. حاول مرة أخرى.',
        'qr_unavailable' => 'انتهت صلاحية رمز QR أو تعذر تحديثه. حدّث الحالة.',
        'qr_not_available' => 'رمز QR غير متاح الآن. حدّث حالة الجلسة.',
        'Could not connect to the WAHA gateway.' =>
          'تعذر الاتصال ببوابة WhatsApp. تحقق من اتصال الإنترنت وحاول مجدداً.',
        'Could not authenticate with Firebase.' =>
          'تعذر التحقق من جلسة Firebase. أعد تسجيل الدخول وحاول مجدداً.',
        'A signed-in Firebase user is required.' =>
          'يجب تسجيل الدخول إلى التطبيق قبل ربط WhatsApp.',
        _ => message,
      };

  String _wahaStatusLabel(String status) => switch (status) {
        'NOT_CREATED' => 'غير مربوط',
        'STARTING' => 'جارٍ بدء الجلسة',
        'SCAN_QR_CODE' => 'بانتظار مسح رمز QR',
        'WORKING' => 'متصل',
        'STOPPED' => 'متوقف',
        'FAILED' => 'انقطع الاتصال',
        'PASSKEY_REQUIRED' => 'يتطلب إكمال التحقق على الهاتف',
        'PASSKEY_CONFIRMATION_REQUIRED' => 'يرجى تأكيد الرمز على الهاتف',
        _ => 'الحالة: $status',
      };

  void _updateWahaStatus(
    WahaSessionStatus session, {
    bool refreshQr = false,
  }) {
    final status = session.status;
    if (!mounted) return;
    final changed = _wahaStatus != status;
    setState(() {
      _wahaStatus = status;
      _wahaPhoneNumber = session.phoneNumber;
      _wahaError = null;
      if (changed || status != 'SCAN_QR_CODE') _wahaQrCode = null;
    });
    if (status == 'STARTING' || status == 'SCAN_QR_CODE') {
      _wahaPollTimer ??= Timer.periodic(
        const Duration(seconds: 4),
        (_) => _pollWahaStatus(),
      );
      if (status == 'SCAN_QR_CODE') {
        _wahaQrTimer ??= Timer.periodic(
          const Duration(seconds: 20),
          (_) => _loadWahaQr(),
        );
        if (changed || refreshQr) _loadWahaQr();
      } else {
        _wahaQrTimer?.cancel();
        _wahaQrTimer = null;
      }
    } else {
      _wahaPollTimer?.cancel();
      _wahaPollTimer = null;
      _wahaQrTimer?.cancel();
      _wahaQrTimer = null;
    }
  }

  Future<void> _pollWahaStatus() async {
    if (_wahaPolling || !mounted) return;
    _wahaPolling = true;
    try {
      final status = await _activeWahaService.getSessionStatus();
      _updateWahaStatus(status);
    } on WahaGatewayException catch (error) {
      _setWahaError(
        error.message,
        stopPolling: error.statusCode == 401 || error.statusCode == 403,
      );
    } catch (_) {
      _setWahaError(
        'تعذر تحديث حالة جلسة WhatsApp.',
        stopPolling: false,
      );
    } finally {
      _wahaPolling = false;
    }
  }

  Future<void> _loadWahaQr() async {
    if (_wahaQrLoading || !mounted || _wahaStatus != 'SCAN_QR_CODE') return;
    _wahaQrLoading = true;
    try {
      final qr = await _activeWahaService.getSessionQr();
      if (!mounted || _wahaStatus != 'SCAN_QR_CODE') return;
      setState(() => _wahaQrCode = qr);
    } on WahaGatewayException catch (error) {
      if (error.statusCode == 409) {
        if (mounted) setState(() => _wahaQrCode = null);
        return;
      }
      _setWahaError(
        error.message,
        stopPolling: error.statusCode == 401 || error.statusCode == 403,
      );
    } catch (_) {
      _setWahaError('تعذر تحميل رمز QR.', stopPolling: false);
    } finally {
      _wahaQrLoading = false;
    }
  }

  Widget _wahaConnectionSection() {
    final qr = _wahaQrCode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('ربط WhatsApp للحساب', Icons.qr_code_2),
        const Text(
          'اربط حساب WhatsApp الخاص بك لمسح رمز QR. ستُرسل إشعاراتك من جلستك الخاصة.',
        ),
        const SizedBox(height: 10),
        Text('حالة الاتصال: ${_wahaStatusLabel(_wahaStatus)}'),
        if (_wahaStatus == 'WORKING' &&
            _wahaPhoneNumber != null) ...[
          const SizedBox(height: 4),
          Text('الرقم المرتبط: $_wahaPhoneNumber'),
        ],
        if (_wahaError != null) ...[
          const SizedBox(height: 8),
          Text(_wahaError!, style: const TextStyle(color: Colors.red)),
        ],
        if (qr != null) ...[
          const SizedBox(height: 12),
          Center(
            child: Image.memory(
              qr.bytes,
              width: 240,
              height: 240,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const Text('تعذر عرض رمز QR.'),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'امسح الرمز من WhatsApp على هاتفك. لا تشارك هذا الرمز مع الآخرين.',
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _wahaBusy || _wahaStatus != 'NOT_CREATED'
                  ? null
                  : _startWahaSession,
              icon: const Icon(Icons.link),
              label: const Text('ربط واتساب'),
            ),
            OutlinedButton.icon(
              onPressed: _wahaBusy ? null : _refreshWahaSession,
              icon: const Icon(Icons.refresh),
              label: const Text('تحديث الحالة'),
            ),
            OutlinedButton.icon(
              onPressed: _wahaBusy ||
                      _wahaStatus == 'NOT_CREATED' ||
                      _wahaStatus == 'WORKING' ||
                      _wahaStatus == 'SCAN_QR_CODE' ||
                      _wahaStatus == 'STARTING'
                  ? null
                  : _reconnectWahaSession,
              icon: const Icon(Icons.sync),
              label: const Text('إعادة الربط'),
            ),
            if (_wahaStatus == 'SCAN_QR_CODE')
              OutlinedButton.icon(
                onPressed: _wahaBusy || _wahaQrLoading ? null : _loadWahaQr,
                icon: const Icon(Icons.qr_code_2),
                label: const Text('تحديث رمز QR'),
              ),
            if (_wahaStatus != 'NOT_CREATED')
              OutlinedButton.icon(
                onPressed: _wahaBusy ? null : _disconnectWahaSession,
                icon: const Icon(Icons.link_off),
                label: const Text('فصل الحساب'),
              ),
          ],
        ),
      ],
    );
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
              if (widget.openWhatsAppLinking) ...[
                _wahaConnectionSection(),
                const SizedBox(height: 22),
              ],
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
              if (_wahaSelected && !widget.openWhatsAppLinking) ...[
                const SizedBox(height: 22),
                _wahaConnectionSection(),
              ],
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
