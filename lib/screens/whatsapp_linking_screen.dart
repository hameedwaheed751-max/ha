import 'dart:async';

import 'package:flutter/material.dart';

import '../services/waha_notification_service.dart';
import '../widgets/whatsapp_event_settings_section.dart';

class WhatsAppLinkingScreen extends StatefulWidget {
  const WhatsAppLinkingScreen({super.key});

  @override
  State<WhatsAppLinkingScreen> createState() => _WhatsAppLinkingScreenState();
}

class _WhatsAppLinkingScreenState extends State<WhatsAppLinkingScreen> {
  Timer? _pollTimer;
  Timer? _qrTimer;
  WahaQrCode? _qrCode;
  String _status = 'NOT_CREATED';
  String? _phoneNumber;
  String? _error;
  bool _busy = false;
  bool _polling = false;
  bool _qrLoading = false;
  late final WahaNotificationService _service;

  @override
  void initState() {
    super.initState();
    _service = WahaNotificationService.forCurrentUser();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshSession();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _qrTimer?.cancel();
    _service.close();
    super.dispose();
  }

  Future<void> _startSession() => _performAction(() async {
    _updateStatus(await _service.startSession());
  });

  Future<void> _refreshSession() => _performAction(() async {
    _updateStatus(await _service.getSessionStatus(), refreshQr: true);
  });

  Future<void> _reconnectSession() => _performAction(() async {
    _updateStatus(await _service.reconnectSession());
  });

  Future<void> _disconnectSession() async {
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

    await _performAction(() async {
      _updateStatus(await _service.disconnectSession());
    });
  }

  Future<void> _performAction(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on WahaGatewayException catch (error) {
      _setError(error.message);
    } catch (_) {
      _setError('تعذر الاتصال بخدمة ربط WhatsApp.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setError(String message, {bool stopPolling = true}) {
    if (stopPolling) {
      _pollTimer?.cancel();
      _pollTimer = null;
      _qrTimer?.cancel();
      _qrTimer = null;
    }
    if (!mounted) return;
    setState(() {
      _error = _friendlyError(message);
      _qrCode = null;
    });
  }

  String _friendlyError(String message) => switch (message) {
    'unauthorized' =>
      'تعذر اعتماد جلسة الدخول. حدّث الحالة، وإذا استمرت المشكلة سجّل الخروج ثم أعد تسجيل الدخول.',
    'forbidden' => 'هذا الحساب غير مخوّل لإدارة جلسة WhatsApp.',
    'authorization_unavailable' =>
      'تعذر التحقق من صلاحية الحساب حالياً. حاول لاحقاً.',
    'origin_not_allowed' =>
      'عنوان التطبيق غير مسموح له بالاتصال ببوابة WhatsApp.',
    'session_status_unavailable' => 'تعذر جلب حالة جلسة WhatsApp من الخادم.',
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

  String _statusLabel(String status) => switch (status) {
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

  void _updateStatus(WahaSessionStatus session, {bool refreshQr = false}) {
    final status = session.status;
    if (!mounted) return;
    final changed = _status != status;
    setState(() {
      _status = status;
      _phoneNumber = session.phoneNumber;
      _error = null;
      if (changed || status != 'SCAN_QR_CODE') _qrCode = null;
    });
    if (status == 'STARTING' || status == 'SCAN_QR_CODE') {
      _pollTimer ??= Timer.periodic(
        const Duration(seconds: 4),
        (_) => _pollStatus(),
      );
      if (status == 'SCAN_QR_CODE') {
        _qrTimer ??= Timer.periodic(
          const Duration(seconds: 20),
          (_) => _loadQr(),
        );
        if (changed || refreshQr) _loadQr();
      } else {
        _qrTimer?.cancel();
        _qrTimer = null;
      }
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
      _qrTimer?.cancel();
      _qrTimer = null;
    }
  }

  Future<void> _pollStatus() async {
    if (_polling || !mounted) return;
    _polling = true;
    try {
      _updateStatus(await _service.getSessionStatus());
    } on WahaGatewayException catch (error) {
      _setError(
        error.message,
        stopPolling: error.statusCode == 401 || error.statusCode == 403,
      );
    } catch (_) {
      _setError('تعذر تحديث حالة جلسة WhatsApp.', stopPolling: false);
    } finally {
      _polling = false;
    }
  }

  Future<void> _loadQr() async {
    if (_qrLoading || !mounted || _status != 'SCAN_QR_CODE') return;
    _qrLoading = true;
    try {
      final qr = await _service.getSessionQr();
      if (!mounted || _status != 'SCAN_QR_CODE') return;
      setState(() => _qrCode = qr);
    } on WahaGatewayException catch (error) {
      if (error.statusCode == 409) {
        if (mounted) setState(() => _qrCode = null);
        return;
      }
      _setError(
        error.message,
        stopPolling: error.statusCode == 401 || error.statusCode == 403,
      );
    } catch (_) {
      _setError('تعذر تحميل رمز QR.', stopPolling: false);
    } finally {
      _qrLoading = false;
    }
  }

  Widget _sectionTitle(String title, IconData icon) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );

  Widget _connectionSection() {
    final qr = _qrCode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('ربط WhatsApp للحساب', Icons.qr_code_2),
        const Text(
          'اربط حساب WhatsApp الخاص بك لمسح رمز QR. ستُرسل إشعاراتك من جلستك الخاصة.',
        ),
        const SizedBox(height: 10),
        Text('حالة الاتصال: ${_statusLabel(_status)}'),
        if (_status == 'WORKING' && _phoneNumber != null) ...[
          const SizedBox(height: 4),
          Text('الرقم المرتبط: $_phoneNumber'),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(color: Colors.red)),
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
              onPressed: _busy || _status != 'NOT_CREATED'
                  ? null
                  : _startSession,
              icon: const Icon(Icons.link),
              label: const Text('ربط واتساب'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _refreshSession,
              icon: const Icon(Icons.refresh),
              label: const Text('تحديث الحالة'),
            ),
            OutlinedButton.icon(
              onPressed:
                  _busy ||
                      _status == 'NOT_CREATED' ||
                      _status == 'WORKING' ||
                      _status == 'SCAN_QR_CODE' ||
                      _status == 'STARTING'
                  ? null
                  : _reconnectSession,
              icon: const Icon(Icons.sync),
              label: const Text('إعادة الربط'),
            ),
            if (_status == 'SCAN_QR_CODE')
              OutlinedButton.icon(
                onPressed: _busy || _qrLoading ? null : _loadQr,
                icon: const Icon(Icons.qr_code_2),
                label: const Text('تحديث رمز QR'),
              ),
            if (_status != 'NOT_CREATED')
              OutlinedButton.icon(
                onPressed: _busy ? null : _disconnectSession,
                icon: const Icon(Icons.link_off),
                label: const Text('فصل الحساب'),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(title: const Text('ربط WhatsApp'), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _connectionSection(),
            ),
          ),
          const SizedBox(height: 20),
          const WhatsAppEventSettingsSection(),
        ],
      ),
    ),
  );
}
