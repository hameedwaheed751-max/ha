import 'package:flutter/material.dart';
import '../models.dart';
import '../sas_api_service.dart';
import '../sas_sync_service.dart';

class SasSettingsScreen extends StatefulWidget {
  const SasSettingsScreen({super.key});
  @override
  State<SasSettingsScreen> createState() => _SasSettingsScreenState();
}

class _SasSettingsScreenState extends State<SasSettingsScreen> {
  final server = TextEditingController();
  final user = TextEditingController();
  final pass = TextEditingController();
  String _proxyUrl = 'https://ha-0cs7.onrender.com';
  bool loading = true, testing = false, hide = true;
  String? result;

  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final s = await SasSettings.load();
    server.text = s.serverUrl; user.text = s.username; pass.text = s.password;
    if (s.webProxyUrl.trim().isNotEmpty) _proxyUrl = s.webProxyUrl.trim();
    if (mounted) setState(() => loading = false);
  }
  @override
  void dispose() { server.dispose(); user.dispose(); pass.dispose(); super.dispose(); }

  SasSettings get value => SasSettings(
        serverUrl: server.text,
        username: user.text,
        password: pass.text,
        webProxyUrl: _proxyUrl,
      );
  InputDecoration dec(String x, IconData i) => InputDecoration(labelText: x, prefixIcon: Icon(i), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)));

  Future<void> _save() async {
    await value.save();
    AppStore.sasUsername = user.text.trim();
    await AppStore.save();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ إعدادات SAS')));
  }

  Future<void> _test() async {
    if (server.text.trim().isEmpty || user.text.trim().isEmpty || pass.text.isEmpty) {
      setState(() => result = 'أدخل رابط SAS واليوزر والباسورد'); return;
    }
    setState(() { testing = true; result = null; });
    try {
      await value.save();
      AppStore.sasUsername = user.text.trim();
      await AppStore.save();
      final api = SasApiService(value);
      await api.login().timeout(const Duration(seconds: 20));
      final sync = await SasSyncService.sync(api).timeout(const Duration(seconds: 30));
      if (mounted) setState(() => result = 'نجح الاتصال والمزامنة. المقروءة: ${sync.read} | المضافة: ${sync.added} | المحدثة: ${sync.updated}');
    } catch (e) {
      if (mounted) setState(() => result = 'فشل الاتصال: $e');
    } finally { if (mounted) setState(() => testing = false); }
  }

  Future<void> _confirmDelete(bool all) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(all ? 'حذف جميع المشتركين؟' : 'حذف مشتركي SAS؟'),
        content: Text(all
            ? 'سيتم حذف جميع المشتركين المحليين وSAS من التطبيق. لا يمكن التراجع.'
            : 'سيتم حذف المشتركين القادمين من SAS فقط، وتبقى البيانات المحلية.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (all) {
      await AppStore.deleteAllSubscribers();
    } else {
      await AppStore.deleteSasSubscribersOnly();
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(all ? 'تم حذف جميع المشتركين' : 'تم حذف مشتركي SAS')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Directionality(
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
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // عنوان الوكيل
                    Card(
                      color: Colors.blue.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            const Icon(Icons.person, color: Colors.blue),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('الوكيل الحالي', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                                  const SizedBox(height: 4),
                                  Text(
                                    AppStore.sasUsername.isNotEmpty
                                        ? AppStore.sasUsername
                                        : 'لم يتم ربط SAS بعد',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: AppStore.sasUsername.isNotEmpty
                                          ? Colors.blue.shade800
                                          : Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // إعدادات الاتصال
                    Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      const Text('إعدادات الاتصال', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      const Text('أدخل رابط SAS الخاص بالشركة وحساب المدير المخول للـ API.'),
                      const SizedBox(height: 16),
                      TextField(controller: server, keyboardType: TextInputType.url, decoration: dec('رابط SAS', Icons.dns_outlined)),
                      const SizedBox(height: 12),
                      TextField(controller: user, decoration: dec('اسم المستخدم', Icons.person_outline)),
                      const SizedBox(height: 12),
                      TextField(controller: pass, obscureText: hide, decoration: dec('كلمة المرور', Icons.lock_outline).copyWith(suffixIcon: IconButton(onPressed: () => setState(() => hide = !hide), icon: Icon(hide ? Icons.visibility : Icons.visibility_off)))),
                    ]))),
                    const SizedBox(height: 14),
                    if (result != null) Card(color: result!.startsWith('نجح') ? Colors.green.shade50 : Colors.red.shade50, child: Padding(padding: const EdgeInsets.all(14), child: Text(result!, style: const TextStyle(fontWeight: FontWeight.w600)))),
                    const SizedBox(height: 10),
                    SizedBox(height: 52, child: FilledButton.icon(onPressed: testing ? null : _test, icon: testing ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.cable), label: const Text('اتصال ومزامنة المشتركين'))),
                    const SizedBox(height: 10),
                    SizedBox(height: 48, child: OutlinedButton.icon(onPressed: _save, icon: const Icon(Icons.save_outlined), label: const Text('حفظ إعدادات SAS'))),
                    const SizedBox(height: 22),
                    const Divider(),
                    const SizedBox(height: 10),
                    const Text(
                      'تنظيف المشتركين عند تغيير SAS',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    const Text('اختر حذف مشتركي SAS فقط أو حذف كل المشتركين من التطبيق.'),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed: testing ? null : () => _confirmDelete(false),
                        icon: const Icon(Icons.cloud_off, color: Colors.deepOrange),
                        label: const Text('حذف مشتركي SAS فقط'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: Colors.red),
                        onPressed: testing ? null : () => _confirmDelete(true),
                        icon: const Icon(Icons.delete_forever),
                        label: const Text('حذف جميع المشتركين'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    ),
  );
}