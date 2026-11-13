import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models.dart';
import '../sas_api_service.dart';
import '../sas_project_national_service.dart';
import '../sas_sync_service.dart';
import '../services/onboarding_gate.dart';
import 'dashboard_screen.dart';
import 'login_screen.dart';
import 'sas_settings_screen.dart';

/// نتيجة محاولة مزامنة: نجحت أم لا، مع رسالة للعرض.
typedef SyncOutcome = ({bool ok, String message});

/// بوابة أول دخول للباقة المجانية: تُلزم الوكيل بربط ساس (RADIUS أو FTTH)
/// وإتمام أول مزامنة ناجحة قبل الدخول إلى التطبيق. لا يوجد تخطٍّ.
class SasOnboardingScreen extends StatefulWidget {
  const SasOnboardingScreen({
    super.key,
    this.checkLinked,
    this.runSync,
    this.onDone,
  });

  /// هل رُبط ساس؟ (حقن للاختبار؛ الافتراضي يفحص الإعدادات الحقيقية.)
  final Future<bool> Function()? checkLinked;

  /// تشغيل المزامنة. (حقن للاختبار.)
  final Future<SyncOutcome> Function()? runSync;

  /// يُستدعى بعد نجاح المزامنة بدل الانتقال إلى الداشبورد (للاختبار).
  final VoidCallback? onDone;

  @override
  State<SasOnboardingScreen> createState() => _SasOnboardingScreenState();
}

class _SasOnboardingScreenState extends State<SasOnboardingScreen> {
  bool? _linked;
  bool _syncing = false;
  bool _synced = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refreshLinked();
  }

  Future<void> _refreshLinked() async {
    final check = widget.checkLinked ?? _defaultCheckLinked;
    final linked = await check();
    if (!mounted) return;
    setState(() => _linked = linked);
  }

  Future<void> _openSasSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SasSettingsScreen()),
    );
    if (mounted) await _refreshLinked();
  }

  Future<void> _doSync() async {
    if (_syncing) return;
    setState(() {
      _syncing = true;
      _error = null;
    });
    final run = widget.runSync ?? _defaultRunSync;
    SyncOutcome res;
    try {
      res = await run();
    } catch (e) {
      res = (ok: false, message: 'تعذّرت المزامنة: $e');
    }
    if (!mounted) return;
    if (res.ok) {
      setState(() {
        _synced = true;
        _syncing = false;
      });
      await OnboardingGate.markTrialOnboarded();
      if (!mounted) return;
      final done = widget.onDone;
      if (done != null) {
        done();
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => const DashboardScreen(isAgentMode: true),
          ),
        );
      }
    } else {
      setState(() {
        _syncing = false;
        _error = res.message;
      });
    }
  }

  Future<void> _logout() async {
    await AppStore.clearForAccountSwitch(clearStorage: false);
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final linked = _linked == true;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('ابدأ بربط الساس'),
          automaticallyImplyLeading: false,
          actions: [
            TextButton.icon(
              onPressed: _logout,
              icon: const Icon(Icons.logout),
              label: const Text('تسجيل الخروج'),
            ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.link, size: 56, color: Colors.indigo),
                const SizedBox(height: 12),
                const Text(
                  'لاستخدام التطبيق، اربط حساب الساس الخاص بك وزامن مشتركيك أولاً.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(
                  'خطوة واحدة لمرة واحدة فقط.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600),
                ),
                const SizedBox(height: 20),
                _statusTile(
                  key: const Key('onboarding-link-status'),
                  label: '١. ربط الساس',
                  done: linked,
                ),
                _statusTile(
                  key: const Key('onboarding-sync-status'),
                  label: '٢. مزامنة المشتركين',
                  done: _synced,
                ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  key: const Key('onboarding-link-btn'),
                  onPressed: _syncing ? null : _openSasSettings,
                  icon: const Icon(Icons.settings),
                  label: Text(linked ? 'تعديل ربط الساس' : 'ربط الساس الآن'),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  key: const Key('onboarding-sync-btn'),
                  onPressed: (!linked || _syncing) ? null : _doSync,
                  icon: _syncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync),
                  label: Text(_syncing ? 'جارٍ المزامنة…' : 'مزامنة الآن'),
                ),
                if (!linked) ...[
                  const SizedBox(height: 8),
                  Text(
                    'اربط الساس أولاً لتفعيل زر المزامنة.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    key: const Key('onboarding-error'),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: Colors.red.shade700),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(color: Colors.red.shade800),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusTile({
    required Key key,
    required String label,
    required bool done,
  }) {
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle : Icons.radio_button_unchecked,
            color: done ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(fontSize: 15)),
        ],
      ),
    );
  }

  static Future<bool> _defaultCheckLinked() async {
    try {
      if ((await SasSettings.loadAll()).isNotEmpty) return true;
    } catch (_) {}
    try {
      final ftth = await SasProjectNationalSettings.load();
      if (ftth.username.trim().isNotEmpty) return true;
    } catch (_) {}
    return false;
  }

  static Future<SyncOutcome> _defaultRunSync() async {
    // RADIUS أولاً.
    try {
      final radius = await SasSettings.loadAll();
      if (radius.isNotEmpty) {
        final r = await SasSyncService.syncAll(
          perAccount: const Duration(seconds: 25),
        );
        if (r.accounts > 0 && !r.allFailed) {
          AppStore.lastSasSync = DateTime.now();
          await AppStore.save();
          return (ok: true, message: 'تمت المزامنة — ${r.summary}');
        }
        if (r.accounts > 0) {
          return (
            ok: false,
            message: 'تعذّرت مزامنة الساس. تحقق من بيانات الربط والاتصال.',
          );
        }
      }
    } catch (e) {
      return (ok: false, message: 'تعذّرت مزامنة الساس: $e');
    }
    // FTTH إن لم يكن هناك RADIUS.
    try {
      final ftth = await SasProjectNationalSettings.load();
      if (ftth.username.trim().isNotEmpty) {
        await SasProjectNationalService.syncSaved().timeout(
          const Duration(minutes: 3),
        );
        if (AppStore.subscribers.any((s) => s.source == 'ftth')) {
          return (ok: true, message: 'تمت مزامنة مشتركي FTTH');
        }
        return (ok: false, message: 'لم تُرجع FTTH مشتركين بعد. حاول مجدداً.');
      }
    } catch (e) {
      return (ok: false, message: 'تعذّرت مزامنة FTTH: $e');
    }
    return (ok: false, message: 'اربط ساساً (RADIUS أو FTTH) أولاً ثم زامن.');
  }
}
