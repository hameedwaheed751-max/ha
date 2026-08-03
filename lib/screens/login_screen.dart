import 'package:flutter/material.dart';
import 'dashboard_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_database/firebase_database.dart';
import '../models.dart';
import '../sas_api_service.dart';
import '../sas_sync_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _obscurePassword = true;
  bool _rememberMe = false;
  bool _isLoading = false;
  @override
void initState() {
  super.initState();
  _checkRememberMe();
}

Future<void> _checkRememberMe() async {
  final prefs = await SharedPreferences.getInstance();
  final rememberMe = prefs.getBool('rememberMe') ?? false;

  if (rememberMe &&
      FirebaseAuth.instance.currentUser != null &&
      mounted) {
    // تحميل بيانات الوكيل من Firebase بعد تسجيل الدخول
    await _loadAgentData();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const DashboardScreen()),
    );
  }
}

/// تحميل بيانات الوكيل من Firebase وبدء المزامنة
Future<void> _loadAgentData() async {
  try {
    // إعادة تحميل البيانات من Firebase (إذا المستخدم مسجل)
    await AppStore.load().timeout(const Duration(seconds: 8));
    
    // بدء المزامنة اللحظية
    AppStore.startRealtimeSync();
    
    // مزامنة SAS بالخلفية
    Future<void>(() async {
      try {
        final settings = await SasSettings.load();
        if (settings.username.trim().isNotEmpty && settings.password.isNotEmpty) {
          final api = SasApiService(settings);
          await SasSyncService.sync(api).timeout(const Duration(seconds: 25));
          AppStore.lastSasSync = DateTime.now();
          await AppStore.save();
        }
      } catch (_) {
        // فشل المزامنة لا يمنع فتح التطبيق
      }
    });
  } catch (e) {
    debugPrint('Agent data load error: $e');
  }
}

/// إنشاء عقدة وكيل جديدة في Firebase RTDB
/// المعرف: uid (بدون sasUsername لأن المستخدم جديد)
static Future<void> createAgentNode(
  User user, {
  String firstName = '',
  String lastName = '',
}) async {
  final uid = user.uid;
  try {
    final ref = FirebaseDatabase.instance.ref('agents/$uid');
    final snapshot = await ref.child('profile').get().timeout(const Duration(seconds: 5));
    final normalizedEmail = (user.email ?? '').trim().toLowerCase();

    // الحساب الجديد يجب أن يبدأ ببيانات تطبيق فارغة محلياً.
    final p = await SharedPreferences.getInstance();
    const keysToClear = <String>[
      'officeName',
      'officePhone',
      'officeAddress',
      'officeLogoBase64',
      'receiptFooter',
      'balance',
      'nextReceiptNumber',
      'lastSasSync',
      'packages',
      'messageTemplates',
      'subscribers',
      'subscribers_backup',
      'sas_server_url',
      'sas_manager_username',
      'sas_manager_password',
      'sas_manager_password_sec',
      'sas_web_proxy_url',
      'web_proxy_url',
      'proxy_url',
      'render_proxy_url',
    ];
    for (final key in keysToClear) {
      await p.remove(key);
    }
    
    if (!snapshot.exists) {
      // الوكيل جديد: نُنشئ فقط بيانات تعريف أساسية، بدون إعدادات مكتملة.
      await ref.update({
        'profile': {
          'email': normalizedEmail,
          'name': [firstName.trim(), lastName.trim()].where((e) => e.isNotEmpty).join(' ').trim(),
          'firstName': firstName.trim(),
          'lastName': lastName.trim(),
          'admin': '',
          'company': '',
          'phone': '',
          'sasUsername': '',
          'emailKey': normalizedEmail,
          'agentKey': normalizedEmail,
          'currentAgentId': uid,
          'createdAt': ServerValue.timestamp,
          'status': 'pending_sas',
        },
        'sas': {
          'serverUrl': '',
          'username': '',
          'password': '',
        },
      }).timeout(const Duration(seconds: 10));
      
      debugPrint('Agent node created for uid=$uid');
    } else {
      debugPrint('Agent node already exists for uid=$uid');
    }
  } catch (e) {
    debugPrint('Agent node creation error: $e');
  }
}

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submitLogin() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isLoading = true);

try {
  await FirebaseAuth.instance.signInWithEmailAndPassword(
    email: _usernameController.text.trim(),
    password: _passwordController.text,
  );
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('rememberMe', _rememberMe);

  // تحميل بيانات الوكيل بعد تسجيل الدخول
  await _loadAgentData();

  if (!mounted) return;

  Navigator.pushReplacement(
    context,
    MaterialPageRoute(
      builder: (context) => const DashboardScreen(),
    ),
  );
} on FirebaseAuthException catch (e) {
  if (!mounted) return;

  String message = 'فشل تسجيل الدخول';

  if (e.code == 'invalid-credential' ||
      e.code == 'user-not-found' ||
      e.code == 'wrong-password') {
    message = 'البريد الإلكتروني أو كلمة المرور غير صحيحة';
  } else if (e.code == 'invalid-email') {
    message = 'صيغة البريد الإلكتروني غير صحيحة';
  }

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
} finally {
  if (mounted) {
    setState(() => _isLoading = false);
  }
}
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                const Color(0xFFE8F5E9).withValues(alpha: 0.85),
                colorScheme.surface,
              ],
            ),
          ),
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 430),
                  child: Card(
                    elevation: 0,
                    color: colorScheme.surface,
                    surfaceTintColor: colorScheme.surfaceTint,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 86,
                              height: 86,
                              decoration: BoxDecoration(
                                color: const Color(0xFFD8F3DC),
                                borderRadius: BorderRadius.circular(28),
                              ),
                              child: Icon(
                                Icons.router_outlined,
                                size: 40,
                                color: const Color(0xFF2E7D32),
                              ),
                            ),
                            const SizedBox(height: 18),
                            Text(
                              'وكيل نت',
                              style: textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'إدارة مشتركي الإنترنت',
                              style: textTheme.bodyLarge?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 28),
                            TextFormField(
                              controller: _usernameController,
                              textAlign: TextAlign.right,
                              textDirection: TextDirection.rtl,
                              decoration: InputDecoration(
                                labelText: 'اسم المستخدم',
                                hintText: 'أدخل اسم المستخدم',
                                prefixIcon: const Icon(Icons.person_outline),
                                filled: true,
                                fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  borderSide: BorderSide(color: colorScheme.outlineVariant),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  borderSide: BorderSide(color: colorScheme.primary, width: 1.6),
                                ),
                              ),
                              validator: (value) {
                                if (value == null || value.trim().isEmpty) {
                                  return 'يرجى إدخال اسم المستخدم';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _passwordController,
                              obscureText: _obscurePassword,
                              textAlign: TextAlign.right,
                              textDirection: TextDirection.rtl,
                              decoration: InputDecoration(
                                labelText: 'كلمة المرور',
                                hintText: 'أدخل كلمة المرور',
                                prefixIcon: const Icon(Icons.lock_outline),
                                suffixIcon: IconButton(
                                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                                  icon: Icon(
                                    _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                                  ),
                                ),
                                filled: true,
                                fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  borderSide: BorderSide(color: colorScheme.outlineVariant),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  borderSide: BorderSide(color: colorScheme.primary, width: 1.6),
                                ),
                              ),
                              validator: (value) {
                                if (value == null || value.isEmpty) {
                                  return 'يرجى إدخال كلمة المرور';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Checkbox(
                                      value: _rememberMe,
                                      onChanged: (value) => setState(() => _rememberMe = value ?? false),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    Text(
                                      'تذكرني',
                                      style: textTheme.bodyMedium,
                                    ),
                                  ],
                                ),
                                TextButton(
                                  onPressed: () {},
                                  child: const Text('نسيت كلمة المرور؟'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            SizedBox(
                              width: double.infinity,
                              height: 56,
                              child: FilledButton(
                                onPressed: _isLoading ? null : _submitLogin,
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFF2E7D32),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                child: _isLoading
                                    ? const SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Text(
                                        'دخول',
                                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                                      ),
                              ),
                            ),
                            const SizedBox(height: 10),
TextButton(
  onPressed: () {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const RegisterScreen(),
      ),
    );
  },
  child: const Text('إنشاء حساب جديد'),
),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;

  Future<void> _register() async {
    if (_firstNameController.text.trim().isEmpty ||
        _lastNameController.text.trim().isEmpty ||
        _emailController.text.trim().isEmpty ||
        _passwordController.text.isEmpty ||
        _confirmPasswordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يرجى ملء جميع الحقول')),
      );
      return;
    }

    if (_passwordController.text != _confirmPasswordController.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('كلمتا المرور غير متطابقتين')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );

      await _LoginScreenState.createAgentNode(
        cred.user!,
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
      );

      AppStore.agentFirstName = _firstNameController.text.trim();
      AppStore.agentLastName = _lastNameController.text.trim();
      AppStore.agentName = [
        AppStore.agentFirstName,
        AppStore.agentLastName,
      ].where((e) => e.isNotEmpty).join(' ').trim();
      AppStore.agentEmail = _emailController.text.trim().toLowerCase();

      if (!mounted) return;

      // تحميل بيانات الوكيل وإنشاء إعدادات افتراضية محلية
      await AppStore.load().timeout(const Duration(seconds: 5));
      AppStore.startRealtimeSync();

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => const DashboardScreen(),
        ),
      );
    } on FirebaseAuthException catch (e) {
      String message = 'حدث خطأ أثناء إنشاء الحساب';

      if (e.code == 'email-already-in-use') {
        message = 'هذا البريد الإلكتروني مسجل مسبقاً';
      } else if (e.code == 'weak-password') {
        message = 'كلمة المرور ضعيفة';
      } else if (e.code == 'invalid-email') {
        message = 'صيغة البريد الإلكتروني غير صحيحة';
      }

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('إنشاء حساب جديد'),
        ),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                children: [
                  TextField(
                    controller: _firstNameController,
                    decoration: const InputDecoration(
                      labelText: 'الاسم الأول',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _lastNameController,
                    decoration: const InputDecoration(
                      labelText: 'الاسم الثاني',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'البريد الإلكتروني',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'كلمة المرور',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _confirmPasswordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'تأكيد كلمة المرور',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton(
                      onPressed: _isLoading ? null : _register,
                      child: _isLoading
                          ? const CircularProgressIndicator()
                          : const Text('إنشاء الحساب'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}