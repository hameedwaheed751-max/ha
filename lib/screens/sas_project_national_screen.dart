import 'package:flutter/material.dart';

import '../sas_project_national_service.dart';

class SasProjectNationalScreen extends StatefulWidget {
  const SasProjectNationalScreen({super.key});

  @override
  State<SasProjectNationalScreen> createState() =>
      _SasProjectNationalScreenState();
}

class _SasProjectNationalScreenState extends State<SasProjectNationalScreen> {
  final _serverController = TextEditingController(
    text: 'https://admin.ftth.iq',
  );
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _loading = false;
  bool _hidePassword = true;
  bool _settingsLoading = true;
  String? _result;
  SasProjectNationalData? _data;

  @override
  void initState() {
    super.initState();
    _loadSavedSettings();
  }

  Future<void> _loadSavedSettings() async {
    try {
      final settings = await SasProjectNationalSettings.load();
      if (!mounted) return;
      _serverController.text = settings.baseUrl;
      _usernameController.text = settings.username;
      _passwordController.text = settings.password;
    } finally {
      if (mounted) setState(() => _settingsLoading = false);
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _sync() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _result = 'أدخل اسم المستخدم وكلمة المرور أولاً');
      return;
    }

    setState(() {
      _loading = true;
      _result = null;
    });

    final service = SasProjectNationalService(
      SasProjectNationalSettings(
        baseUrl: _serverController.text,
        username: username,
        password: password,
      ),
    );
    try {
      await service.settings.save();
      final data = await service.fetchSubscriberData();
      final sync = await service.syncSubscribers(data: data);
      if (!mounted) return;
      setState(() {
        _data = data;
        _result =
            'تمت المزامنة. المقروءة: ${sync.read} | المضافة: ${sync.added} | المحدثة: ${sync.updated}';
      });
    } catch (error) {
      debugPrint('[FTTH SAS] sync failed: $error');
      if (!mounted) return;
      setState(() => _result = 'فشلت المزامنة: $error');
    } finally {
      service.dispose();
      if (mounted) setState(() => _loading = false);
    }
  }

  InputDecoration _decoration(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      border: const OutlineInputBorder(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('ساس المشروع الوطني'),
          centerTitle: true,
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _serverController,
              decoration: _decoration('رابط FTTH', Icons.link),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _usernameController,
              decoration: _decoration('اسم المستخدم', Icons.person_outline),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: _hidePassword,
              decoration: _decoration('كلمة المرور', Icons.lock_outline)
                  .copyWith(
                suffixIcon: IconButton(
                  tooltip: _hidePassword ? 'إظهار كلمة المرور' : 'إخفاء كلمة المرور',
                  icon: Icon(
                    _hidePassword ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => setState(() => _hidePassword = !_hidePassword),
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loading || _settingsLoading ? null : _sync,
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              label: Text(_loading ? 'جارِ المزامنة...' : 'مزامنة بيانات المشتركين'),
            ),
            if (_result != null) ...[
              const SizedBox(height: 16),
              Text(
                _result!,
                style: TextStyle(
                  color: _data == null
                      ? Theme.of(context).colorScheme.error
                      : Colors.green.shade700,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (_data != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.people_outline),
                      title: const Text('العملاء'),
                      trailing: Text('${_data!.customers.length}'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.card_membership_outlined),
                      title: const Text('الاشتراكات'),
                      trailing: Text('${_data!.subscriptions.length}'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.wifi_tethering),
                      title: const Text('الجلسات'),
                      trailing: Text('${_data!.sessions.length}'),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
