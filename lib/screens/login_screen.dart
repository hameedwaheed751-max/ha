import 'package:flutter/material.dart';
import 'dashboard_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:image_picker/image_picker.dart';
import '../models.dart';
import '../sas_api_service.dart';
import '../sas_sync_service.dart';
import '../services/subscription_request_service.dart';

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

  static const String _rememberMeKey = 'rememberMe';
  static const String _savedEmailKey = 'savedLoginEmail';
  static const String _savedPasswordKey = 'savedLoginPassword';
  static const String _lastSignedInEmailKey = 'lastSignedInEmail';

  @override
  void initState() {
    super.initState();
    _checkRememberMe();
  }

  Future<void> _checkRememberMe() async {
    final prefs = await SharedPreferences.getInstance();
    final rememberMe = prefs.getBool(_rememberMeKey) ?? false;
    final savedEmail = prefs.getString(_savedEmailKey) ?? '';
    final savedPassword = prefs.getString(_savedPasswordKey) ?? '';
    final lastSignedInEmail = prefs.getString(_lastSignedInEmailKey) ?? '';

    final preferredEmail = savedEmail.isNotEmpty ? savedEmail : lastSignedInEmail;
    if (preferredEmail.isNotEmpty) {
      _usernameController.text = preferredEmail;
    }
    if (rememberMe && savedPassword.isNotEmpty) {
      _passwordController.text = savedPassword;
      _rememberMe = true;
      if (mounted) setState(() {});
    } else if (lastSignedInEmail.isNotEmpty && savedPassword.isEmpty) {
      _rememberMe = false;
      if (mounted) setState(() {});
    }

    if (rememberMe && FirebaseAuth.instance.currentUser != null && mounted) {
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
    await AppStore.clearForAccountSwitch(clearStorage: true);

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
    
    await AppStore.initializeEmptyAgentNode(uid: uid);

    if (!snapshot.exists) {
      // الوكيل جديد: نُنشئ عقدة خاصة به تبدأ فارغة تماماً.
      final profileName = [firstName.trim(), lastName.trim()].where((e) => e.isNotEmpty).join(' ').trim();
      await ref.child('profile').update({
        'email': normalizedEmail,
        'name': profileName,
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
      }).timeout(const Duration(seconds: 10));
      await ref.child('sas').set({
        'serverUrl': '',
        'username': '',
        'password': '',
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
  final email = _usernameController.text.trim();
  final password = _passwordController.text;

  await FirebaseAuth.instance.signInWithEmailAndPassword(
    email: email,
    password: password,
  );
  final prefs = await SharedPreferences.getInstance();
  if (_rememberMe) {
    await prefs.setBool(_rememberMeKey, true);
    await prefs.setString(_savedEmailKey, email);
    await prefs.setString(_savedPasswordKey, password);
  } else {
    await prefs.setBool(_rememberMeKey, false);
    await prefs.remove(_savedEmailKey);
    await prefs.remove(_savedPasswordKey);
  }
  await prefs.setString(_lastSignedInEmailKey, email);

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
                                      onChanged: (value) {
                                        setState(() => _rememberMe = value ?? false);
                                        if (!(_rememberMe)) {
                                          SharedPreferences.getInstance().then((prefs) async {
                                            await prefs.setBool(_rememberMeKey, false);
                                            await prefs.remove(_savedEmailKey);
                                            await prefs.remove(_savedPasswordKey);
                                          });
                                        }
                                      },
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
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _isLoading = false;
  String _selectedPlan = 'trial';

  Future<void> _register() async {
    if (_firstNameController.text.trim().isEmpty ||
        _lastNameController.text.trim().isEmpty ||
        _phoneController.text.trim().isEmpty ||
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

      final now = DateTime.now();
      final startDate = now.toIso8601String();
      final endDate = SubscriptionRequestService.endDateForPlan(_selectedPlan, from: now).toIso8601String();

      await FirebaseDatabase.instance
          .ref('agents/${cred.user!.uid}/profile')
          .update({
            'phone': _phoneController.text.trim(),
            'subscriptionPlan': _selectedPlan,
            'subscriptionPlanLabel': _planLabel(_selectedPlan),
            'subscriptionPrice': _planPrice(_selectedPlan),
            'paymentMethod': 'master',
            'subscriptionStartDate': startDate,
            'subscriptionEndDate': endDate,
            'subscriptionStatus': 'active',
          }).timeout(const Duration(seconds: 10));

      AppStore.agentFirstName = _firstNameController.text.trim();
      AppStore.agentLastName = _lastNameController.text.trim();
      AppStore.officePhone = _phoneController.text.trim();
      AppStore.agentName = [
        AppStore.agentFirstName,
        AppStore.agentLastName,
      ].where((e) => e.isNotEmpty).join(' ').trim();
      AppStore.agentEmail = _emailController.text.trim().toLowerCase();
      AppStore.subscriptionPlan = _selectedPlan;
      AppStore.subscriptionPlanLabel = _planLabel(_selectedPlan);
      AppStore.subscriptionPrice = _planPrice(_selectedPlan);
      AppStore.paymentMethod = 'master';
      AppStore.subscriptionStartedAt = now;
      AppStore.subscriptionEndsAt = SubscriptionRequestService.endDateForPlan(_selectedPlan, from: now);
      AppStore.subscriptionStatus = 'active';
      await AppStore.save();

      if (!mounted) return;

      // تحميل بيانات الوكيل وإنشاء إعدادات افتراضية محلية
      await AppStore.initializeEmptyAgentNode(uid: cred.user!.uid);
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

  Future<void> _submitPaidSubscriptionRequest({
    required String transferNumber,
    XFile? receiptFile,
  }) async {
    if (_firstNameController.text.trim().isEmpty ||
        _lastNameController.text.trim().isEmpty ||
        _phoneController.text.trim().isEmpty ||
        _emailController.text.trim().isEmpty ||
        _passwordController.text.isEmpty ||
        _confirmPasswordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يرجى ملء جميع الحقول قبل إرسال الطلب')),
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
      final requestId = await SubscriptionRequestService.createRequest(
        firstName: _firstNameController.text.trim(),
        lastName: _lastNameController.text.trim(),
        phone: _phoneController.text.trim(),
        email: _emailController.text.trim().toLowerCase(),
        selectedPlan: _selectedPlan,
        amount: _planPrice(_selectedPlan),
        paymentMethod: 'Qi Card',
        transferNumber: transferNumber,
        password: _passwordController.text,
      );

      if (receiptFile != null) {
        final imageUrl = await SubscriptionRequestService.uploadReceiptImage(
          requestId: requestId,
          file: receiptFile,
        );
        await FirebaseDatabase.instance.ref('subscription_requests/$requestId').update({
          'receiptImageUrl': imageUrl ?? '',
        });
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم إرسال طلب الاشتراك بنجاح وسيتم مراجعته من الإدارة')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل إرسال الطلب: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _openMasterAccountFlow() async {
    if (_selectedPlan == 'trial') {
      await _register();
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MasterAccountScreen(
          planLabel: _planLabel(_selectedPlan),
          planPrice: _planPrice(_selectedPlan),
          onContinue: ({required String transferNumber, XFile? receiptFile}) async {
            await _submitPaidSubscriptionRequest(
              transferNumber: transferNumber,
              receiptFile: receiptFile,
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  String _planLabel(String value) {
    switch (value) {
      case 'trial':
        return 'تجريبي 15 يوم';
      case '3m':
        return '3 أشهر';
      case '6m':
        return '6 أشهر';
      case '1y':
        return 'سنة';
      default:
        return 'تجريبي 15 يوم';
    }
  }

  String _planPrice(String value) {
    switch (value) {
      case 'trial':
        return 'مجاني';
      case '3m':
        return '40000';
      case '6m':
        return '50000';
      case '1y':
        return '70000';
      default:
        return 'مجاني';
    }
  }

  Widget _planCard({required String value, required String title, required String subtitle, required String price, required bool selected}) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => setState(() => _selectedPlan = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        padding: const EdgeInsets.all(14),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: selected ? colorScheme.primary : colorScheme.outlineVariant.withValues(alpha: 0.6)),
          color: selected ? colorScheme.primaryContainer.withValues(alpha: 0.45) : colorScheme.surface,
          boxShadow: selected
              ? [BoxShadow(color: colorScheme.primary.withValues(alpha: 0.18), blurRadius: 10, offset: const Offset(0, 4))]
              : null,
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: selected ? colorScheme.primary : colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                selected ? Icons.check_circle : Icons.workspace_premium_outlined,
                color: selected ? Colors.white : colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12)),
                  const SizedBox(height: 6),
                  Text(price, style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.w800, fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F9FC),
        appBar: AppBar(
          title: const Text('إنشاء حساب جديد'),
          centerTitle: true,
          elevation: 0,
          backgroundColor: Colors.transparent,
          foregroundColor: colorScheme.onSurface,
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 500),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        gradient: LinearGradient(
                          colors: [const Color(0xFF1E88E5), const Color(0xFF43A047)],
                          begin: Alignment.topRight,
                          end: Alignment.bottomLeft,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.person_add_alt_1_rounded, color: Colors.white, size: 24),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'إنشاء حساب وكيل جديد',
                                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Colors.white),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'أدخل بياناتك الأساسية ثم اختر الباقة المناسبة لك.',
                                  style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    _sectionCard(
                      title: 'المعلومات الشخصية',
                      icon: Icons.person_outline,
                      child: Column(
                        children: [
                          _styledField(controller: _firstNameController, label: 'الاسم الأول', icon: Icons.person),
                          const SizedBox(height: 12),
                          _styledField(controller: _lastNameController, label: 'الاسم الثاني', icon: Icons.person_2_outlined),
                          const SizedBox(height: 12),
                          _styledField(
                            controller: _phoneController,
                            label: 'رقم الموبايل',
                            icon: Icons.phone_android_rounded,
                            keyboardType: TextInputType.phone,
                          ),
                          const SizedBox(height: 12),
                          _styledField(
                            controller: _emailController,
                            label: 'البريد الإلكتروني',
                            icon: Icons.email_outlined,
                            keyboardType: TextInputType.emailAddress,
                          ),
                          const SizedBox(height: 12),
                          _styledField(controller: _passwordController, label: 'كلمة المرور', icon: Icons.lock_outline, obscureText: true),
                          const SizedBox(height: 12),
                          _styledField(controller: _confirmPasswordController, label: 'تأكيد كلمة المرور', icon: Icons.lock_reset_outlined, obscureText: true),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _sectionCard(
                      title: 'الباقات المتاحة',
                      icon: Icons.workspace_premium_rounded,
                      child: Column(
                        children: [
                          _planCard(value: 'trial', title: 'الاشتراك التجريبي', subtitle: '15 يوم مجاناً', price: 'مجاني', selected: _selectedPlan == 'trial'),
                          _planCard(value: '3m', title: 'اشتراك 3 أشهر', subtitle: 'صلاحية 3 أشهر', price: '40,000 دينار', selected: _selectedPlan == '3m'),
                          _planCard(value: '6m', title: 'اشتراك 6 أشهر', subtitle: 'صلاحية 6 أشهر', price: '50,000 دينار', selected: _selectedPlan == '6m'),
                          _planCard(value: '1y', title: 'اشتراك سنة', subtitle: 'صلاحية سنة كاملة', price: '70,000 دينار', selected: _selectedPlan == '1y'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8F5E9),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFC8E6C9)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.payment_rounded, color: Color(0xFF2E7D32)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'الدفع عن طريق الماستر عند اختيار الباقة المناسبة.',
                              style: TextStyle(color: colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: FilledButton.icon(
                        onPressed: _isLoading ? null : _openMasterAccountFlow,
                        icon: _isLoading
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                            : Icon(_selectedPlan == 'trial' ? Icons.app_registration_rounded : Icons.account_balance_wallet_outlined),
                        label: Text(
                          _isLoading
                              ? 'جاري الإنشاء...'
                              : (_selectedPlan == 'trial' ? 'إنشاء الحساب' : 'فتح حساب الماستر'),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF2E7D32),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionCard({required String title, required IconData icon, required Widget child}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: colorScheme.primary, size: 20),
              ),
              const SizedBox(width: 10),
              Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: colorScheme.onSurface)),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _styledField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscureText = false,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textAlign: TextAlign.right,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        filled: true,
        fillColor: const Color(0xFFF7F9FC),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFE5EAF0)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF2E7D32), width: 1.4),
        ),
      ),
    );
  }
}

class MasterAccountScreen extends StatefulWidget {
  final String planLabel;
  final String planPrice;
  final Future<void> Function({required String transferNumber, XFile? receiptFile}) onContinue;

  const MasterAccountScreen({
    super.key,
    required this.planLabel,
    required this.planPrice,
    required this.onContinue,
  });

  @override
  State<MasterAccountScreen> createState() => _MasterAccountScreenState();
}

class _MasterAccountScreenState extends State<MasterAccountScreen> {
  final TextEditingController _transferController = TextEditingController();
  XFile? _receiptFile;
  bool _isSubmitting = false;
  final ImagePicker _picker = ImagePicker();

  @override
  void dispose() {
    _transferController.dispose();
    super.dispose();
  }

  Future<void> _pickReceipt() async {
    final file = await _picker.pickImage(source: ImageSource.gallery);
    if (file != null) {
      setState(() => _receiptFile = file);
    }
  }

  Future<void> _handleContinue() async {
    if (_transferController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('يرجى إدخال رقم التحويل')));
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      await widget.onContinue(transferNumber: _transferController.text.trim(), receiptFile: _receiptFile);
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F9FC),
        appBar: AppBar(
          title: const Text('حساب الماستر'),
          centerTitle: true,
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        gradient: LinearGradient(
                          colors: [const Color(0xFF1565C0), const Color(0xFF2E7D32)],
                          begin: Alignment.topRight,
                          end: Alignment.bottomLeft,
                        ),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 14, offset: const Offset(0, 8))],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 50,
                                height: 50,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(15),
                                ),
                                child: const Icon(Icons.account_balance_wallet_outlined, color: Colors.white, size: 25),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'إكمال الاشتراك المدفوع',
                                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'إدارة دفع الباقة من خلال حساب الماستر',
                                      style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.security_outlined, color: Colors.white, size: 18),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'سيتم توجيهك لإكمال الاشتراك عبر حساب الماستر قبل إنشاء الحساب النهائي.',
                                    style: TextStyle(color: Colors.white.withValues(alpha: 0.94), fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 4))],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('تفاصيل الباقة', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: colorScheme.onSurface)),
                          const SizedBox(height: 12),
                          _infoRow(title: 'الباقة', value: widget.planLabel),
                          _infoRow(title: 'السعر', value: widget.planPrice),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF7F9FC),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: const Color(0xFFE5EAF0)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.account_balance_wallet_rounded, color: Color(0xFF1565C0), size: 18),
                                    const SizedBox(width: 8),
                                    Text('معلومات الدفع للماستر', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: colorScheme.onSurface)),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text('الطريقة: تحويل/ماستر', style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
                                const SizedBox(height: 4),
                                Text('المبلغ المستحق: ${widget.planPrice}', style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
                                const SizedBox(height: 4),
                                Text('الحالة: في انتظار تأكيد الدفع قبل إنشاء الحساب', style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF3F8F4),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.info_outline, color: Color(0xFF2E7D32), size: 18),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'لا يتم إنشاء الحساب قبل تأكيد الدفع عبر حساب الماستر.',
                                    style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F9FC),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE5EAF0)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('معلومات الدفع', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: colorScheme.onSurface)),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _transferController,
                            textAlign: TextAlign.right,
                            decoration: const InputDecoration(
                              labelText: 'رقم التحويل',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.account_balance_wallet_outlined),
                            ),
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: _pickReceipt,
                            icon: const Icon(Icons.attach_file_rounded),
                            label: Text(_receiptFile == null ? 'إرفاق إيصال' : 'تم اختيار إيصال'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.arrow_back_ios_new_rounded),
                            label: const Text('رجوع'),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _isSubmitting ? null : _handleContinue,
                            icon: _isSubmitting
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.check_circle_outline_rounded),
                            label: Text(_isSubmitting ? 'جاري الإرسال...' : 'تأكيد الدفع'),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF2E7D32),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoRow({required String title, required String value}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(value, style: const TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}