import 'dart:async';

import 'package:flutter/material.dart';
import 'dashboard_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import '../models.dart';
import '../sas_api_service.dart';
import '../sas_sync_service.dart';
import '../services/payment_request_service.dart';
import '../services/user_role_service.dart';

class LoginScreen extends StatefulWidget {
  final bool forceExpiredMode;
  final String expiredUid;
  final String expiredEmail;
  final String expiredName;
  final String expiredPhone;
  final String expiredRole;
  final String expiredGovernorate;
  final String expiredRegion;
  final String expiredAddress;

  const LoginScreen({
    super.key,
    this.forceExpiredMode = false,
    this.expiredUid = '',
    this.expiredEmail = '',
    this.expiredName = '',
    this.expiredPhone = '',
    this.expiredRole = 'agent',
    this.expiredGovernorate = '',
    this.expiredRegion = '',
    this.expiredAddress = '',
  });

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
  bool _isRenewActionBusy = false;
  ExpiredAccountData? _expiredAccount;
  Timer? _emailProbeDebounce;
  bool _pendingScreenOpening = false;

  static const String _rememberMeKey = 'rememberMe';
  static const String _savedEmailKey = 'savedLoginEmail';
  static const String _savedPasswordKey = 'savedLoginPassword';
  static const String _lastSignedInEmailKey = 'lastSignedInEmail';

  @override
  void initState() {
    super.initState();
    _usernameController.addListener(_onEmailChanged);
    if (widget.forceExpiredMode && widget.expiredUid.trim().isNotEmpty) {
      _expiredAccount = ExpiredAccountData(
        uid: widget.expiredUid.trim(),
        email: widget.expiredEmail.trim().toLowerCase(),
        name: widget.expiredName.trim(),
        phone: widget.expiredPhone.trim(),
        role: widget.expiredRole.trim().isEmpty ? 'agent' : widget.expiredRole.trim(),
        governorate: widget.expiredGovernorate.trim(),
        region: widget.expiredRegion.trim(),
        address: widget.expiredAddress.trim(),
      );
      if (_expiredAccount!.email.isNotEmpty) {
        _usernameController.text = _expiredAccount!.email;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_expiredAccount != null) {
          _openPendingRenewalIfExists(account: _expiredAccount!);
        }
      });
    }
    _checkRememberMe();
  }

  void _onEmailChanged() {
    final email = _usernameController.text.trim().toLowerCase();
    if (_expiredAccount != null && email != _expiredAccount!.email) {
      if (mounted) setState(() => _expiredAccount = null);
    }
    _emailProbeDebounce?.cancel();
    if (email.isEmpty || !email.contains('@')) return;
    _emailProbeDebounce = Timer(const Duration(milliseconds: 450), () async {
      final info = await _findExpiredAccountByEmail(email);
      if (!mounted) return;
      final currentEmail = _usernameController.text.trim().toLowerCase();
      if (currentEmail != email) return;
      if (info != null) {
        setState(() => _expiredAccount = info);
      }
    });
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
      await _openHomeForCurrentUser();
      return;
    }

    if (preferredEmail.isNotEmpty && mounted) {
      final account = await _findExpiredAccountByEmail(preferredEmail);
      if (account != null && mounted) {
        setState(() => _expiredAccount = account);
        await _openPendingRenewalIfExists(account: account);
      }
    }
  }

  Future<void> _openHomeForCurrentUser() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final role = await UserRoleService.resolveRole(uid: uid);
    AppStore.refreshSubscriptionStatus();
    if (role == UserRoleService.agentRole && AppStore.subscriptionStatus == 'expired') {
      await _enforceExpiredAccessForCurrentSession();
      return;
    }
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => DashboardScreen(isAgentMode: role == UserRoleService.agentRole),
      ),
    );
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

  @override
  void dispose() {
    _emailProbeDebounce?.cancel();
    _usernameController.removeListener(_onEmailChanged);
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<ExpiredAccountData?> _findExpiredAccountByEmail(String email) async {
    final normalized = email.trim().toLowerCase();
    if (normalized.isEmpty) return null;

    final snapshot = await FirebaseDatabase.instance.ref('agents').get();
    final root = snapshot.value;
    if (root is! Map) return null;

    for (final entry in root.entries) {
      if (entry.value is! Map) continue;
      final node = Map<String, dynamic>.from(entry.value as Map);
      final profile = node['profile'] is Map
          ? Map<String, dynamic>.from(node['profile'] as Map)
          : <String, dynamic>{};

      final emailValue = (profile['email'] ?? '').toString().trim().toLowerCase();
      if (emailValue != normalized) continue;

      final subscription = node['subscription'] is Map
          ? Map<String, dynamic>.from(node['subscription'] as Map)
          : <String, dynamic>{};
      final status = (subscription['status'] ?? '').toString().trim().toLowerCase();
      final endDateRaw = (subscription['endDate'] ?? '').toString().trim();
      final endDate = endDateRaw.isNotEmpty ? DateTime.tryParse(endDateRaw)?.toUtc() : null;
      final now = DateTime.now().toUtc();
      final isExpired = status == 'expired' || (endDate != null && !endDate.isAfter(now));
      if (!isExpired) return null;

      return ExpiredAccountData(
        uid: entry.key.toString(),
        email: emailValue,
        name: (profile['name'] ?? '').toString().trim(),
        phone: (profile['phone'] ?? '').toString().trim(),
        role: (profile['role'] ?? 'agent').toString().trim(),
        governorate: (profile['governorate'] ?? '').toString().trim(),
        region: (profile['region'] ?? '').toString().trim(),
        address: (profile['address'] ?? '').toString().trim(),
      );
    }
    return null;
  }

  Future<void> _enforceExpiredAccessForCurrentSession() async {
    final user = FirebaseAuth.instance.currentUser;
    final fallbackEmail = _usernameController.text.trim().toLowerCase();
    final expired = await _findExpiredAccountByEmail((user?.email ?? fallbackEmail).trim().toLowerCase());
    await AppStore.clearForAccountSwitch(clearStorage: false);
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _expiredAccount = expired;
      if (_expiredAccount != null && _expiredAccount!.email.isNotEmpty) {
        _usernameController.text = _expiredAccount!.email;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('انتهى اشتراكك، يرجى تجديد الاشتراك.')),
    );
    if (_expiredAccount != null) {
      await _openPendingRenewalIfExists(account: _expiredAccount!);
    }
  }

  Future<void> _openPendingRenewalIfExists({required ExpiredAccountData account}) async {
    if (!mounted || _pendingScreenOpening) return;
    _pendingScreenOpening = true;
    try {
      final latest = await PaymentRequestService.findLatestRenewalRequestForAccount(
        uid: account.uid,
        email: account.email,
      );
      if (!mounted || latest == null || !latest.isPending) return;
      _navigateToRenewalStatusScreen(
        account: account,
        successNotice: 'تم إرسال طلب تجديد الاشتراك بنجاح.\nيرجى انتظار موافقة الإدارة.',
      );
    } finally {
      _pendingScreenOpening = false;
    }
  }

  void _navigateToRenewalStatusScreen({
    required ExpiredAccountData account,
    String? successNotice,
  }) {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => RenewalRequestStatusScreen(
          account: account,
          successNotice: successNotice,
        ),
      ),
      (route) => false,
    );
  }

  Future<void> _submitRenewalRequest({
    required ExpiredAccountData account,
    required String selectedPlan,
    required String transferNumber,
    required XFile? receiptFile,
  }) async {
    final pending = await PaymentRequestService.findLatestRenewalRequestForAccount(
      uid: account.uid,
      email: account.email,
    );
    if (pending != null && pending.isPending) {
      _navigateToRenewalStatusScreen(
        account: account,
        successNotice: 'طلب التجديد الحالي قيد المراجعة.\nيرجى انتظار موافقة الإدارة.',
      );
      return;
    }

    final requestId = await PaymentRequestService.createRequest(
      uid: account.uid,
      userType: account.role.isEmpty ? 'agent' : account.role,
      phone: account.phone,
      email: account.email,
      agentName: account.name,
      governorate: account.governorate,
      region: account.region,
      address: account.address,
      selectedPlan: selectedPlan,
      amount: PaymentPlanCatalog.amount(selectedPlan),
      paymentMethod: 'Qi Card',
      transferNumber: transferNumber,
      password: '',
      isRenewal: true,
      renewalForUid: account.uid,
    );

    if (receiptFile != null) {
      final receipt = receiptFile;
      unawaited(() async {
        try {
          final imageUrl = await PaymentRequestService.uploadReceiptImage(
            requestId: requestId,
            file: receipt,
          ).timeout(const Duration(seconds: 30));
          await PaymentRequestService.markRequestAsPendingReview(
            requestId: requestId,
            patch: {'receiptImage': imageUrl ?? ''},
          ).timeout(const Duration(seconds: 15));
        } catch (e) {
          debugPrint('Renewal receipt upload/update failed for request $requestId: $e');
        }
      }());
    }

    _navigateToRenewalStatusScreen(
      account: account,
      successNotice: 'تم إرسال طلب تجديد الاشتراك بنجاح.\nيرجى انتظار موافقة الإدارة.',
    );
  }

  Future<void> _openRenewSubscriptionFlow() async {
    final email = _usernameController.text.trim().toLowerCase();
    var account = _expiredAccount;
    if (account == null) {
      account = await _findExpiredAccountByEmail(email);
      if (account != null && mounted) {
        setState(() => _expiredAccount = account);
      }
    }
    if (account == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('هذا الحساب غير منتهي أو غير موجود.')),
      );
      return;
    }

    final pending = await PaymentRequestService.findLatestRenewalRequestForAccount(
      uid: account.uid,
      email: account.email,
    );
    if (pending != null && pending.isPending) {
      _navigateToRenewalStatusScreen(
        account: account,
        successNotice: 'طلب التجديد الحالي قيد المراجعة.\nيرجى انتظار موافقة الإدارة.',
      );
      return;
    }

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SubscriptionPlansScreen(
          renewalAccount: account,
          onRenewSubmit: (plan, transferNumber, receiptFile) async {
            await _submitRenewalRequest(
              account: account!,
              selectedPlan: plan,
              transferNumber: transferNumber,
              receiptFile: receiptFile,
            );
          },
        ),
      ),
    );
  }

  Future<void> _submitLogin() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isLoading = true);

try {
  final email = _usernameController.text.trim();
  final password = _passwordController.text;

  final expired = await _findExpiredAccountByEmail(email);
  if (expired != null) {
    if (mounted) {
      setState(() {
        _expiredAccount = expired;
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('انتهى اشتراكك، يرجى تجديد الاشتراك.')),
      );
    }
    return;
  }

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
  await _openHomeForCurrentUser();
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
                            if (_expiredAccount != null) ...[
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFEBEE),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: const Color(0xFFEF9A9A)),
                                ),
                                child: const Text(
                                  'انتهى اشتراكك، يرجى تجديد الاشتراك.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Color(0xFFC62828), fontWeight: FontWeight.w700),
                                ),
                              ),
                              const SizedBox(height: 10),
                              SizedBox(
                                width: double.infinity,
                                height: 56,
                                child: FilledButton.icon(
                                  onPressed: _isRenewActionBusy
                                      ? null
                                      : () async {
                                          setState(() => _isRenewActionBusy = true);
                                          try {
                                            await _openRenewSubscriptionFlow();
                                          } finally {
                                            if (mounted) setState(() => _isRenewActionBusy = false);
                                          }
                                        },
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFF1565C0),
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                  ),
                                  icon: _isRenewActionBusy
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                        )
                                      : const Icon(Icons.restart_alt),
                                  label: Text(
                                    _isRenewActionBusy ? 'يرجى الانتظار...' : 'تجديد الاشتراك',
                                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ),
                            ] else
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
                                    builder: (context) => const SubscriptionPlansScreen(),
                                  ),
                                );
                              },
                              child: const Text('الاشتراك وإنشاء الحساب'),
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
  final String selectedPlan;
  final String transferNumber;
  final XFile? receiptFile;
  const RegisterScreen({
    super.key,
    required this.selectedPlan,
    required this.transferNumber,
    this.receiptFile,
  });

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _fullNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _governorateController = TextEditingController();
  final _regionController = TextEditingController();
  final _addressController = TextEditingController();
  bool _isLoading = false;
  late String _selectedPlan;
  late String _transferNumber;
  XFile? _receiptFile;

  @override
  void initState() {
    super.initState();
    _selectedPlan = PaymentPlanCatalog.normalize(widget.selectedPlan);
    _transferNumber = widget.transferNumber;
    _receiptFile = widget.receiptFile;
  }

  Future<void> _submitPaidSubscriptionRequest() async {
    if (_fullNameController.text.trim().isEmpty ||
        _phoneController.text.trim().isEmpty ||
        _emailController.text.trim().isEmpty ||
        _governorateController.text.trim().isEmpty ||
        _regionController.text.trim().isEmpty ||
        _addressController.text.trim().isEmpty ||
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
      final requestId = await PaymentRequestService.createRequest(
        uid: '',
        userType: 'agent',
        phone: _phoneController.text.trim(),
        email: _emailController.text.trim().toLowerCase(),
        agentName: _fullNameController.text.trim(),
        governorate: _governorateController.text.trim(),
        region: _regionController.text.trim(),
        address: _addressController.text.trim(),
        selectedPlan: _selectedPlan,
        amount: PaymentPlanCatalog.amount(_selectedPlan),
        paymentMethod: 'Qi Card',
        transferNumber: _transferNumber,
        password: _passwordController.text,
      );

      if (!mounted) return;
      setState(() => _isLoading = false);

      if (_receiptFile != null) {
        final receipt = _receiptFile!;
        unawaited(() async {
          try {
            final imageUrl = await PaymentRequestService.uploadReceiptImage(
              requestId: requestId,
              file: receipt,
            ).timeout(const Duration(seconds: 30));
            await PaymentRequestService.markRequestAsPendingReview(
              requestId: requestId,
              patch: {'receiptImage': imageUrl ?? ''},
            ).timeout(const Duration(seconds: 15));
          } catch (e) {
            debugPrint('Receipt upload/update failed for request $requestId: $e');
          }
        }());
      }

      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            content: const Text('تم إرسال طلب الاشتراك بنجاح، وهو الآن بانتظار موافقة الإدارة.'),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('موافق'),
              ),
            ],
          ),
        ),
      );

      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل إرسال الطلب: $e')),
      );
    } finally {
      if (mounted && _isLoading) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    _fullNameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _governorateController.dispose();
    _regionController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  String _planLabel(String value) {
    switch (value.trim()) {
      case 'trial':
      case 'free_15_days':
        return 'تجريبي 15 يوم';
      case '3m':
      case 'three_months':
        return '3 أشهر';
      case '6m':
      case 'six_months':
        return '6 أشهر';
      case '1y':
      case 'one_year':
        return 'سنة';
      default:
        return 'تجريبي 15 يوم';
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
          title: const Text('إنشاء حساب الاشتراك'),
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
                                  'إنشاء حساب الاشتراك',
                                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Colors.white),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'بعد اختيار الباقة، أدخل بياناتك ثم أرسل طلب الاشتراك للمراجعة.',
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
                          _styledField(controller: _fullNameController, label: 'الاسم الكامل', icon: Icons.person),
                          const SizedBox(height: 12),
                          _styledField(controller: _governorateController, label: 'المحافظة', icon: Icons.location_city_outlined),
                          const SizedBox(height: 12),
                          _styledField(controller: _regionController, label: 'المنطقة', icon: Icons.map_outlined),
                          const SizedBox(height: 12),
                          _styledField(controller: _addressController, label: 'العنوان', icon: Icons.home_outlined),
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
                              'الباقة المختارة: ${_planLabel(_selectedPlan)}',
                              style: TextStyle(color: colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () {
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(builder: (_) => const SubscriptionPlansScreen()),
                        );
                      },
                      child: const Text('تغيير الباقة'),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: FilledButton.icon(
                        onPressed: _isLoading ? null : _submitPaidSubscriptionRequest,
                        icon: _isLoading
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                            : const Icon(Icons.send_outlined),
                        label: Text(
                          _isLoading
                              ? 'جاري الإرسال...'
                              : 'إرسال طلب الاشتراك',
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

class ExpiredAccountData {
  ExpiredAccountData({
    required this.uid,
    required this.email,
    required this.name,
    required this.phone,
    required this.role,
    required this.governorate,
    required this.region,
    required this.address,
  });

  final String uid;
  final String email;
  final String name;
  final String phone;
  final String role;
  final String governorate;
  final String region;
  final String address;
}

class RenewalRequestStatusScreen extends StatefulWidget {
  const RenewalRequestStatusScreen({
    super.key,
    required this.account,
    this.successNotice,
  });

  final ExpiredAccountData account;
  final String? successNotice;

  @override
  State<RenewalRequestStatusScreen> createState() => _RenewalRequestStatusScreenState();
}

class _RenewalRequestStatusScreenState extends State<RenewalRequestStatusScreen> {
  bool _navigatedAfterApproval = false;
  bool _isSubmittingNew = false;

  Future<void> _submitNewRenewalRequest({
    required String selectedPlan,
    required String transferNumber,
    required XFile? receiptFile,
  }) async {
    final pending = await PaymentRequestService.findLatestRenewalRequestForAccount(
      uid: widget.account.uid,
      email: widget.account.email,
    );
    if (pending != null && pending.isPending) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يوجد طلب تجديد قيد المراجعة بالفعل.')),
      );
      return;
    }

    final requestId = await PaymentRequestService.createRequest(
      uid: widget.account.uid,
      userType: widget.account.role.isEmpty ? 'agent' : widget.account.role,
      phone: widget.account.phone,
      email: widget.account.email,
      agentName: widget.account.name,
      governorate: widget.account.governorate,
      region: widget.account.region,
      address: widget.account.address,
      selectedPlan: selectedPlan,
      amount: PaymentPlanCatalog.amount(selectedPlan),
      paymentMethod: 'Qi Card',
      transferNumber: transferNumber,
      password: '',
      isRenewal: true,
      renewalForUid: widget.account.uid,
    );

    if (receiptFile != null) {
      final receipt = receiptFile;
      unawaited(() async {
        try {
          final imageUrl = await PaymentRequestService.uploadReceiptImage(
            requestId: requestId,
            file: receipt,
          ).timeout(const Duration(seconds: 30));
          await PaymentRequestService.markRequestAsPendingReview(
            requestId: requestId,
            patch: {'receiptImage': imageUrl ?? ''},
          ).timeout(const Duration(seconds: 15));
        } catch (e) {
          debugPrint('Renewal receipt upload/update failed for request $requestId: $e');
        }
      }());
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم إرسال طلب تجديد الاشتراك بنجاح. يرجى انتظار موافقة الإدارة.')),
    );
    setState(() {});
  }

  void _openNewRenewalFlow() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SubscriptionPlansScreen(
          renewalAccount: widget.account,
          onRenewSubmit: (plan, transferNumber, receiptFile) async {
            await _submitNewRenewalRequest(
              selectedPlan: plan,
              transferNumber: transferNumber,
              receiptFile: receiptFile,
            );
            if (mounted) {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
    );
  }

  void _handleApprovedOnce() {
    if (_navigatedAfterApproval || !mounted) return;
    _navigatedAfterApproval = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تمت الموافقة على تجديد اشتراكك. يمكنك تسجيل الدخول الآن.')),
      );
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('حالة طلب التجديد'),
          centerTitle: true,
        ),
        body: StreamBuilder<RenewalRequestState?>(
          stream: PaymentRequestService.watchLatestRenewalRequestForAccount(
            uid: widget.account.uid,
            email: widget.account.email,
          ),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            final state = snapshot.data;
            final isPending = state?.isPending ?? false;
            final isRejected = state?.isRejected ?? false;
            final rejectedReason = (state?.rejectionReason ?? '').trim();
            if (state?.isApproved == true) {
              _handleApprovedOnce();
            }

            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Icon(
                            isPending ? Icons.hourglass_top_rounded : (isRejected ? Icons.cancel_rounded : Icons.info_outline),
                            size: 58,
                            color: isPending ? const Color(0xFF1565C0) : (isRejected ? const Color(0xFFC62828) : colorScheme.primary),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            isPending
                                ? 'تم إرسال طلب تجديد الاشتراك بنجاح.'
                                : (isRejected ? 'تم رفض طلب التجديد.' : 'لا يوجد طلب تجديد قيد المراجعة حالياً.'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            isPending
                                ? 'يرجى انتظار موافقة الإدارة.'
                                : (isRejected
                                    ? (rejectedReason.isEmpty ? 'يمكنك إرسال طلب جديد.' : 'سبب الرفض: $rejectedReason')
                                    : 'يمكنك إرسال طلب تجديد جديد.'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 14, color: Colors.black87),
                          ),
                          if (widget.successNotice != null && widget.successNotice!.trim().isNotEmpty && isPending) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE8F5E9),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: const Color(0xFFA5D6A7)),
                              ),
                              child: Text(
                                widget.successNotice!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF2E7D32)),
                              ),
                            ),
                          ],
                          const SizedBox(height: 18),
                          FilledButton.icon(
                            onPressed: isPending || _isSubmittingNew
                                ? null
                                : () async {
                                    setState(() => _isSubmittingNew = true);
                                    try {
                                      _openNewRenewalFlow();
                                    } finally {
                                      if (mounted) setState(() => _isSubmittingNew = false);
                                    }
                                  },
                            icon: _isSubmittingNew
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : const Icon(Icons.restart_alt),
                            label: Text(isPending ? 'بانتظار الموافقة' : 'إرسال طلب جديد'),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: () {
                              Navigator.of(context).pushAndRemoveUntil(
                                MaterialPageRoute(
                                  builder: (_) => LoginScreen(
                                    forceExpiredMode: true,
                                    expiredUid: widget.account.uid,
                                    expiredEmail: widget.account.email,
                                    expiredName: widget.account.name,
                                    expiredPhone: widget.account.phone,
                                    expiredRole: widget.account.role,
                                    expiredGovernorate: widget.account.governorate,
                                    expiredRegion: widget.account.region,
                                    expiredAddress: widget.account.address,
                                  ),
                                ),
                                (route) => false,
                              );
                            },
                            child: const Text('العودة إلى تسجيل الدخول'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class SubscriptionPlansScreen extends StatelessWidget {
  final ExpiredAccountData? renewalAccount;
  final Future<void> Function(String plan, String transferNumber, XFile? receiptFile)? onRenewSubmit;

  const SubscriptionPlansScreen({
    super.key,
    this.renewalAccount,
    this.onRenewSubmit,
  });

  String _planLabel(String value) {
    switch (PaymentPlanCatalog.normalize(value)) {
      case PaymentPlanCatalog.free15Days:
        return 'مجاني 15 يوم';
      case PaymentPlanCatalog.threeMonths:
        return '3 أشهر';
      case PaymentPlanCatalog.sixMonths:
        return '6 أشهر';
      case PaymentPlanCatalog.oneYear:
        return 'سنة';
      default:
        return 'مجاني 15 يوم';
    }
  }

  String _planPrice(String value) {
    final amount = PaymentPlanCatalog.amount(value);
    if (amount == 'مجاني') return amount;
    return '$amount دينار';
  }

  void _openRegistration(BuildContext context, String plan) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MasterAccountScreen(
          planLabel: _planLabel(plan),
          planPrice: _planPrice(plan),
          onContinue: ({required String transferNumber, XFile? receiptFile}) async {
            if (renewalAccount != null && onRenewSubmit != null) {
              await onRenewSubmit!(plan, transferNumber, receiptFile);
              return;
            }
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (_) => RegisterScreen(
                  selectedPlan: plan,
                  transferNumber: transferNumber,
                  receiptFile: receiptFile,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _planTile(BuildContext context, {required String plan, required String title, required String subtitle, required String price, required Color accent}) {
    return InkWell(
      onTap: () => _openRegistration(context, plan),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: accent.withValues(alpha: 0.25)),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 12, offset: const Offset(0, 4))],
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(Icons.workspace_premium_outlined, color: accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: const TextStyle(fontSize: 12, color: Colors.black54)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(price, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: accent)),
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
          title: const Text('الاشتراكات'),
          centerTitle: true,
          elevation: 0,
          backgroundColor: Colors.transparent,
          foregroundColor: colorScheme.onSurface,
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 500),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        gradient: const LinearGradient(
                          colors: [Color(0xFF1E88E5), Color(0xFF43A047)],
                          begin: Alignment.topRight,
                          end: Alignment.bottomLeft,
                        ),
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('اختر الباقة المناسبة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white)),
                          SizedBox(height: 4),
                          Text('بعد اختيار الباقة تنتقل مباشرة إلى صفحة إنشاء الحساب.', style: TextStyle(color: Colors.white70, fontSize: 13)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    _planTile(context, plan: PaymentPlanCatalog.free15Days, title: 'مجاني 15 يوم', subtitle: 'تجربة أولية', price: 'مجاني', accent: const Color(0xFF2E7D32)),
                    _planTile(context, plan: PaymentPlanCatalog.threeMonths, title: '3 أشهر', subtitle: 'اشتراك مدفوع', price: '40,000 دينار', accent: const Color(0xFF1565C0)),
                    _planTile(context, plan: PaymentPlanCatalog.sixMonths, title: '6 أشهر', subtitle: 'اشتراك مدفوع', price: '50,000 دينار', accent: const Color(0xFF00897B)),
                    _planTile(context, plan: PaymentPlanCatalog.oneYear, title: 'سنة', subtitle: 'اشتراك مدفوع', price: '70,000 دينار', accent: const Color(0xFF8E24AA)),
                  ],
                ),
              ),
            ),
          ),
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
    if (_receiptFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('يرجى إرفاق صورة وصل الدفع')));
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      await widget.onContinue(transferNumber: _transferController.text.trim(), receiptFile: _receiptFile);
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
                                      'إرسال بيانات الدفع لمراجعة الإدارة',
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
                                    'لن يتم إنشاء الحساب أو تفعيل الاشتراك إلا بعد موافقة المدير.',
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
                                Text('الحالة: pending حتى موافقة المدير', style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
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
                                    'سيتم إنشاء الحساب لأول مرة عند الموافقة فقط.',
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