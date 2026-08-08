import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models.dart';
import '../sas_api_service.dart';
import '../sas_sync_service.dart';
import '../services/auto_notification_service.dart';
import '../services/render_whatsapp_service.dart';
import 'add_subscriber_screen.dart';
import 'receipt_screen.dart';
import 'subscriber_details_screen.dart';


class SubscribersScreen extends StatefulWidget {
  final String filter;
  const SubscribersScreen({super.key, this.filter = 'all'});

  @override
  State<SubscribersScreen> createState() => _SubscribersScreenState();
}

class _SubscribersScreenState extends State<SubscribersScreen> {
  final ScrollController _verticalScrollController = ScrollController();
  final ScrollController _horizontalScrollController = ScrollController();

  bool operationBusy = false;
  Subscriber? selected;
  String q = '';
  bool syncing = false;
  bool _isRefreshing = false;
  String _sortBy = 'name';
  bool _sortAsc = true;
  int _rowsPerPage = 50;
  int? _sortColumnIndex;
  String _advancedStatus = 'الكل';
  String _advancedConnection = 'الكل';
  String _advancedPackage = 'الكل';
  String _advancedParent = 'الكل';
  bool _includeSubUsers = true;
  String _advancedMac = '';
  
  // العناصر الجديدة من SAS Radius
  final Map<String, bool> _columnVisibility = {
    'ip': true,
    'remainingDays': true,
    'debtDays': false,
  };

  @override
  void initState() {
    super.initState();
    _loadColumnPreferences();
    _filteredSubscribers = _buildFilteredSubscribers();
  }

  Future<void> _loadColumnPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _columnVisibility['ip'] = prefs.getBool('col_ip') ?? true;
      _columnVisibility['remainingDays'] = prefs.getBool('col_remainingDays') ?? true;
      _columnVisibility['debtDays'] = prefs.getBool('col_debtDays') ?? false;
    });
  }

  Future<void> _saveColumnPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('col_ip', _columnVisibility['ip'] ?? false);
    await prefs.setBool('col_remainingDays', _columnVisibility['remainingDays'] ?? false);
    await prefs.setBool('col_debtDays', _columnVisibility['debtDays'] ?? false);
  }

  List<Subscriber> _filteredSubscribers = [];

  List<Subscriber> _buildFilteredSubscribers() {
    final z = q.toLowerCase().trim();
    final now = DateTime.now();
    final filtered = AppStore.subscribers.where((s) {
      if (widget.filter == 'active' && !s.isActive) return false;
      if (widget.filter == 'expired' && !s.expired) return false;
      if (widget.filter == 'debts' && s.remaining <= 0) return false;
      if (widget.filter == 'expiring3Days') {
        if (s.disabled || s.expired) return false;
        final days = s.endDate.difference(now).inDays;
        if (days < 0 || days > 3) return false;
      }

      final basicMatch = s.user.toLowerCase().contains(z) ||
          s.name.toLowerCase().contains(z) ||
          s.phone.contains(z) ||
          s.type.toLowerCase().contains(z) ||
          s.packageDisplay.toLowerCase().contains(z);
      if (!basicMatch) return false;

      if (_advancedStatus != 'الكل') {
        if (_advancedStatus == 'فعال' && (!s.isActive || s.disabled)) return false;
        if (_advancedStatus == 'منتهي الصلاحية' && !s.expired) return false;
        if (_advancedStatus == 'معطل' && !s.disabled) return false;
        if (_advancedStatus == 'ينتهي قريباً') {
          final days = s.endDate.difference(now).inDays;
          if (days < 0 || days > 7) return false;
        }
        if (_advancedStatus == 'خلال 3 أيام') {
          final days = s.endDate.difference(now).inDays;
          if (days < 0 || days > 3) return false;
        }
        if (_advancedStatus == 'ينتهي اشتراكهم اليوم') {
          final sameDay = s.endDate.year == now.year &&
              s.endDate.month == now.month &&
              s.endDate.day == now.day;
          if (!sameDay) return false;
        }
      }

      if (_advancedConnection != 'الكل') {
        final online = s.isOnline;
        if (_advancedConnection == 'متصل' && !online) return false;
        if (_advancedConnection == 'غير متصل' && online) return false;
      }

      if (_advancedPackage != 'الكل' && s.packageDisplay != _advancedPackage) return false;
      if (_advancedParent != 'الكل' && _parentText(s) != _advancedParent) return false;
      if (_advancedMac.trim().isNotEmpty &&
          !_macText(s).toLowerCase().contains(_advancedMac.toLowerCase().trim())) {
        return false;
      }
      return true;
    }).toList();

    filtered.sort((a, b) {
      int c = 0;
      switch (_sortBy) {
        case 'name':
          c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          break;
        case 'user':
          c = a.user.toLowerCase().compareTo(b.user.toLowerCase());
          break;
        case 'package':
          c = a.packageDisplay.toLowerCase().compareTo(b.packageDisplay.toLowerCase());
          break;
        case 'date':
          c = a.endDate.compareTo(b.endDate);
          break;
        case 'status':
          c = _statusOrder(a).compareTo(_statusOrder(b));
          break;
        default:
          c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
      return _sortAsc ? c : -c;
    });
    return filtered;
  }

  void _reloadSubscribers() {
    setState(() {
      _filteredSubscribers = _buildFilteredSubscribers();
    });
  }

  String fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  void _setStartDateAsActivationDay(Subscriber s, {DateTime? at}) {
    s.markActivationDate(at: at ?? DateTime.now());
  }

  String _parentText(Subscriber s) => _sasText(
    s, const ['parent_name', 'parent', 'manager_name', 'reseller_name', 'owner_name'], ''
  );

  String _macText(Subscriber s) => _sasText(
    s, const ['mac', 'mac_address', 'macAddress', 'calling_station_id'], ''
  );

  void _sort(String field, [int? columnIndex]) {
    setState(() {
      if (_sortBy == field) {
        _sortAsc = !_sortAsc;
      } else {
        _sortBy = field;
        _sortAsc = true;
      }
      _sortColumnIndex = columnIndex;
      selected = null;
      _filteredSubscribers = _buildFilteredSubscribers();
    });
  }

  int _statusOrder(Subscriber s) {
    if (s.disabled) return 2;
    if (s.expired) return 1;
    return 0;
  }

  String get pageTitle {
    if (widget.filter == 'active') return 'المشتركين الفعالين';
    if (widget.filter == 'expired') return 'المنتهي اشتراكهم';
    if (widget.filter == 'debts') return 'الديون';
    if (widget.filter == 'expiring3Days') return 'ينتهون خلال 3 أيام';
    return 'المشتركين';
  }

  Future<void> add() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const AddSubscriberScreen()),
    );
    if (changed == true && mounted) setState(() => selected = null);
  }

  Future<void> _refreshSubscribers() async {
    if (syncing || _isRefreshing) return;
    setState(() => _isRefreshing = true);
    try {
      await syncNow();
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  Future<void> syncNow() async {
    if (syncing) return;
    setState(() => syncing = true);
    try {
      final settings = await SasSettings.load();
      if (settings.username.trim().isEmpty || settings.password.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('أكمل إعدادات ربط SAS أولاً')),
          );
        }
        return;
      }

      final api = SasApiService(settings);
      final result = await SasSyncService.sync(api).timeout(
        const Duration(minutes: 2),
        onTimeout: () => throw Exception('انتهت مهلة المزامنة بعد دقيقتين'),
      );
      AppStore.lastSasSync = DateTime.now();
      await AppStore.save();

      if (mounted) {
        setState(() => selected = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'تمت المزامنة — جديد ${result.added}، محدث ${result.updated}، مقروء ${result.read}',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذرت المزامنة: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  @override
  void dispose() {
    _verticalScrollController.dispose();
    _horizontalScrollController.dispose();
    super.dispose();
  }

  String normalizePhone(String phone) {
    var n = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (n.startsWith('0')) n = '964${n.substring(1)}';
    return n;
  }

  double? _parseAmount(String raw) {
    final normalized = raw
        .trim()
        .replaceAll(',', '')
        .replaceAll(' ', '')
        .replaceAll('٠', '0')
        .replaceAll('١', '1')
        .replaceAll('٢', '2')
        .replaceAll('٣', '3')
        .replaceAll('٤', '4')
        .replaceAll('٥', '5')
        .replaceAll('٦', '6')
        .replaceAll('٧', '7')
        .replaceAll('٨', '8')
        .replaceAll('٩', '9')
        .replaceAll('٫', '.')
        .replaceAll('٬', '');
    if (normalized.isEmpty) return null;
    return double.tryParse(normalized);
  }

  double _toNum(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse((value ?? '').toString().replaceAll(',', '').trim()) ?? 0;
  }

  double _activationReceivedAmount(dynamic response) {
    if (response is! Map) return 0;
    for (final key in const [
      'money_collected',
      'required_amount',
      'amount',
      'user_price',
      'price',
      'total',
    ]) {
      final v = _toNum(response[key]);
      if (v > 0) return v;
    }
    final data = response['data'];
    if (data is Map) {
      for (final key in const [
        'money_collected',
        'required_amount',
        'amount',
        'user_price',
        'price',
        'total',
      ]) {
        final v = _toNum(data[key]);
        if (v > 0) return v;
      }
    }
    return 0;
  }

  Future<void> whatsapp(Subscriber s, {String? message}) async {
    final n = RenderWhatsAppService.normalizePhone(s.phone);
    if (n.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا يوجد رقم هاتف لهذا المشترك')),
        );
      }
      return;
    }

    final defaultMessage =
        'مرحباً ${s.name}، تحية من ${AppStore.officeName}. تاريخ انتهاء اشتراكك ${fmt(s.endDate)}.';
    final result = await RenderWhatsAppService.notifyGeneralMessageToSubscriber(
      s,
      message: (message ?? defaultMessage).trim(),
      template: '{message}',
    );

    if (!mounted) return;
    if (result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم إرسال الرسالة عبر واتساب بنجاح')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل إرسال واتساب: ${result.error ?? 'خطأ غير معروف'}')),
      );
    }
  }

  Future<void> _sendActivationWhatsApp(Subscriber s) async {
    final activationTemplate = AppStore.messageTemplates['activation'] ??
        'مرحباً {name}، تم تفعيل اشتراكك لدى {office}. الباقة: {package} وتنتهي بتاريخ {endDate}.';

    final result = await RenderWhatsAppService.notifySubscriptionActivated(
      s,
      template: activationTemplate,
    );

    if (!result.success) {
      debugPrint(
        'Activation WhatsApp failed for ${s.name}: ${result.error ?? 'unknown'}',
      );
    }
  }


  Future<void> phoneCall(Subscriber s) async {
    final phone = s.phone.trim();
    if (phone.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا يوجد رقم هاتف لهذا المشترك')),
        );
      }
      return;
    }
    final uri = Uri(scheme: 'tel', path: phone);
    if (!await launchUrl(uri) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر فتح تطبيق الاتصال')),
      );
    }
  }

  String _renderTemplate(String template, Subscriber s) {
    final paid = s.paid.toStringAsFixed(0);
    final remaining = s.remaining.toStringAsFixed(0);
    final startDate = fmt(s.startDate);
    final endDate = fmt(s.endDate);
    final agentName = AppStore.officeName;
    final whatsappNumber = AppStore.officePhone.trim();
    return template
        .replaceAll('{name}', s.name)
        .replaceAll('{{customer_name}}', s.name)
      .replaceAll('{{الاسم المشترك}}', s.name)
        .replaceAll('{office}', AppStore.officeName)
      .replaceAll('{{agent_name}}', agentName)
      .replaceAll('{{اسم الوكيل}}', AppStore.officeName)
        .replaceAll('{package}', s.packageDisplay)
      .replaceAll('{{package_name}}', s.packageDisplay)
      .replaceAll('{{اسم الباقة}}', s.packageDisplay)
      .replaceAll('{{subscription_start}}', startDate)
      .replaceAll('{{subscription_end}}', endDate)
      .replaceAll('{{subscription_start_date}}', startDate)
      .replaceAll('{{subscription_end_date}}', endDate)
      .replaceAll('{{whatsapp_number}}', whatsappNumber)
      .replaceAll('{{payment_date}}', s.paymentDate.isNotEmpty ? s.paymentDate : fmt(DateTime.now()))
      .replaceAll('{{paid_amount}}', paid)
      .replaceAll('{{remaining_amount}}', remaining)
      .replaceAll('{{تاريخ البدء}}', startDate)
        .replaceAll('{endDate}', fmt(s.endDate))
      .replaceAll('{{تاريخ الانتهاء}}', endDate)
      .replaceAll('{price}', s.price.toStringAsFixed(0))
      .replaceAll('{{مبلغ الاشتراك}}', s.price.toStringAsFixed(0))
      .replaceAll('{{المبلغ}}', remaining)
      .replaceAll('{paid}', paid)
      .replaceAll('{{الواصل}}', 'الواصل: $paid')
      .replaceAll('{remaining}', remaining)
      .replaceAll('{{المتبقي}}', 'المتبقي: $remaining');
  }

  void messageTemplates(Subscriber s) {
    const titles = <String, String>{
      'activation': 'رسالة تفعيل',
      'extension': 'رسالة تمديد',
      'nearExpiry': 'قرب انتهاء الاشتراك',
      'expired': 'انتهاء الاشتراك',
      'debt': 'تذكير بالدين',
      'debtPaid': 'استلام دين سابق',
    };

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(
                  leading: Icon(Icons.chat, color: Colors.green),
                  title: Text('رسائل واتساب', style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('تستخدم النماذج المحفوظة من قائمة الداشبورد'),
                ),
                const Divider(height: 1),
                ...titles.entries.map((entry) {
                  final template = AppStore.messageTemplates[entry.key] ?? '';
                  return ListTile(
                    leading: const Icon(Icons.send_outlined),
                    title: Text(entry.value),
                    onTap: () {
                      Navigator.pop(ctx);
                      RenderWhatsAppService.dispatchInBackground(
                        RenderWhatsAppService.notifyGeneralMessageToSubscriber(
                          s,
                          message: '',
                          template: template,
                        ),
                      );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('تمت جدولة إرسال الرسالة عبر واتساب')),
                        );
                      }
                    },
                  );
                }),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _activateSubscriber(Subscriber s, {BuildContext? modalContext}) async {
    bool loadingDialogShown = false;
    // استخراج معرف SAS بشكل آمن
    final sasId = s.sasId.trim();
    final dataId = (s.sasData['id'] ?? s.sasData['user_id'] ?? '').toString().trim();
    final rawId = sasId.isNotEmpty ? sasId : dataId;

    debugPrint('Activation Debug: sasId=$sasId, dataId=$dataId, rawId=$rawId');

    final userId = int.tryParse(rawId);

    if (userId == null || userId == 0) {
      if (modalContext != null && modalContext.mounted) Navigator.pop(modalContext);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ تعذر التفعيل: معرف SAS غير صحيح (rawId=$rawId)'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
      return;
    }

    try {
      final settings = await SasSettings.load();
      if (settings.username.trim().isEmpty || settings.password.isEmpty) {
        throw Exception('أكمل إعدادات ربط SAS أولاً');
      }

      debugPrint('Attempting to activate userId=$userId for subscriber ${s.name}');

      final api = SasApiService(settings);
      
      // عرض شاشة التحميل
      if (modalContext != null && modalContext.mounted) {
        Navigator.pop(modalContext);
      }
      if (mounted) {
        loadingDialogShown = true;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const Center(
            child: CircularProgressIndicator(),
          ),
        );
      }

      // تفعيل المشترك في SAS
      final activationTemplate = AppStore.messageTemplates['activation'] ??
          'مرحباً {name}، تم تفعيل اشتراكك لدى {office}. الباقة: {package} وتنتهي بتاريخ {endDate}.';
      final activationMessage = _renderTemplate(activationTemplate, s);

      final activationResponse = await api.activateUser(
        userId,
        notifyPhone: s.phone,
        notifyMessage: activationMessage,
      ).timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw Exception('انتهت مهلة طلب التفعيل'),
      );

      debugPrint('Activation API Response: $activationResponse');

      // جلب بيانات المشترك المحدثة من SAS
      dynamic userOverview;
      try {
        userOverview = await api.fetchUserOverview(userId).timeout(
          const Duration(seconds: 15),
        );
        debugPrint('User Overview: $userOverview');
      } catch (e) {
        debugPrint('Could not fetch user overview: $e');
      }

      // تحديث بيانات المشترك محلياً
      s.active = true;
      s.disabled = false;
      s.points++;
      _setStartDateAsActivationDay(s);

      final activationAmount = _activationReceivedAmount(activationResponse);
      await AppStore.addDailyTaskEvent(
        DailyTaskEvent(
          type: 'activation',
          subscriberUser: s.user,
          subscriberName: s.name,
          at: DateTime.now(),
          amount: activationAmount,
          remainingAfter: s.remaining,
          note: 'تفعيل من قائمة المشتركين',
        ),
        persist: false,
      );

      // تحديث بيانات SAS إذا تم جلبها
      if (userOverview is Map) {
        s.sasData.addAll(Map<String, dynamic>.from(userOverview));
        
        // تحديث الحالة
        final isActive = userOverview['is_active'] ?? userOverview['active'] ?? true;
        final isDisabled = userOverview['disabled'] ?? userOverview['is_disabled'] ?? false;
        
        s.active = isActive == true || isActive == 1;
        s.disabled = isDisabled == true || isDisabled == 1;
      }

      // حفظ البيانات المحلية أولاً
      await AppStore.save();

      // بعد نجاح التفعيل: مزامنة SAS تلقائياً حتى تظهر الحالة الجديدة
      // مباشرةً بدون حاجة المستخدم للضغط على زر المزامنة.
      try {
        final syncResult = await SasSyncService.sync(api).timeout(
          const Duration(seconds: 45),
          onTimeout: () => throw Exception('انتهت مهلة المزامنة التلقائية'),
        );
        _setStartDateAsActivationDay(s);
        AppStore.lastSasSync = DateTime.now();
        await AppStore.save();
        debugPrint(
          'Auto sync after activation: '
          'added=${syncResult.added}, updated=${syncResult.updated}, read=${syncResult.read}',
        );
      } catch (e) {
        // التفعيل نفسه نجح؛ فشل التحديث لا يحوّل العملية إلى فشل تفعيل.
        debugPrint('Auto sync after activation failed: $e');
      }

      if (mounted) {
        if (loadingDialogShown && Navigator.of(context).canPop()) {
          Navigator.of(context).pop(); // إغلاق شاشة التحميل فقط
          loadingDialogShown = false;
        }

        // إرسال إشعار تفعيل واتساب من التطبيق لضمان وصول رسالة
        // تاريخ البداية وتاريخ الانتهاء حتى لو تعذر إشعار SAS الداخلي.
        await _sendActivationWhatsApp(s);
        if (!mounted) return;

        setState(() {
          selected = null;
          _filteredSubscribers = _buildFilteredSubscribers();
        });

        _debt(s, autoOpenReceiptAfterSave: true);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('✅ تم التفعيل وتحديث حالة المشترك تلقائياً'),
            backgroundColor: Colors.green.shade600,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        // إغلاق شاشة التحميل فقط إن كانت ما تزال ظاهرة
        if (loadingDialogShown && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
          loadingDialogShown = false;
        }
      }

      if (mounted) {
        final errorStr = e.toString();
        String msg;

        if (errorStr.contains('نقاط المكافآت غير كافية')) {
          msg = '❌ نقاط المكافآت غير كافية - اطلب من المشترك تجميع نقاط إضافية';
        } else if (errorStr.contains('لا يوجد رصيد متاح')) {
          msg = '❌ لا يوجد رصيد - رصيد المشترك والمدير معاً صفر. أضف رصيد للمشترك أو المدير';
        } else if (errorStr.contains('الرصيد صفر') || errorStr.contains('zero balance')) {
          msg = '❌ رصيد المشترك صفر - سيتم الاعتماد على رصيد المدير. تأكد من وجود رصيد لدى المدير';
        } else if (errorStr.contains('الرصيد غير كافٍ')) {
          msg = '❌ الرصيد غير كافٍ للتفعيل (المشترك والمدير)';
        } else if (errorStr.contains('تم الوصول إلى الحد الأقصى')) {
          msg = '⚠️ تم الوصول إلى الحد الأقصى - الحساب أو المدير وصل للحد. حاول لاحقاً';
        } else if (errorStr.contains('Failed host lookup') || errorStr.contains('SocketException')) {
          msg = '❌ فشل الاتصال بخادم SAS - تحقق من الإنترنت أو تواصل مع دعم SAS';
        } else if (errorStr.contains('تعذر الاتصال')) {
          msg = '❌ الاتصال بخادم SAS منقطع - تحقق من الإنترنت أو اسم الخادم';
        } else if (errorStr.contains('403')) {
          msg = '❌ خطأ 403: تحقق من صلاحيات المستخدم أو معرف SAS (userId=$userId)';
        } else if (errorStr.contains('401')) {
          msg = '❌ خطأ 401: فشل التحقق من البيانات. تحقق من بيانات الربط';
        } else if (errorStr.contains('404')) {
          msg = '❌ خطأ 404: المشترك غير موجود في SAS (userId=$userId)';
        } else if (errorStr.contains('مهلة')) {
          msg = '❌ انتهت المهلة الزمنية للتفعيل. تحقق من الاتصال بـ SAS';
        } else if (errorStr.contains('رفض SAS')) {
          msg = '❌ رفضت SAS عملية التفعيل. جرب لاحقاً';
        } else {
          msg = '❌ فشل التفعيل في SAS: $errorStr';
        }

        debugPrint('Activation failed: $msg');

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              msg,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
            backgroundColor: Colors.red.shade600,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  void operations() {
    final s = selected;
    if (s == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      const CircleAvatar(child: Icon(Icons.person)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(s.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                            Text(s.user, style: TextStyle(color: Colors.grey.shade600)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                _op(Icons.check_circle, Colors.green, 'تفعيل', () {
                  _activateSubscriber(s, modalContext: ctx);
                }),
                _op(Icons.edit, Colors.blue, 'تعديل الديون والحسابات', () {
                  Navigator.pop(ctx);
                  _debt(s);
                }),
                _op(Icons.badge_outlined, Colors.indigo, 'تعديل بيانات المشترك', () async {
                  Navigator.pop(ctx);
                  final changed = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(builder: (_) => AddSubscriberScreen(subscriber: s)),
                  );
                  if (changed == true && mounted) setState(() {});
                }),
                _op(Icons.person_add, Colors.teal, 'إضافة', () {
                  Navigator.pop(ctx);
                  add();
                }),
                _op(Icons.calendar_month, Colors.orange, 'تمديد', () {
                  Navigator.pop(ctx);
                  _extend(s);
                }),
                _op(Icons.swap_horiz, Colors.purple, 'تغيير الباقة', () {
                  Navigator.pop(ctx);
                  _changePackage(s);
                }),
                _op(Icons.block, Colors.red, 'تعطيل', () async {
                  // لا نغيّر الحالة محلياً إلا بعد نجاح التعطيل الحقيقي في SAS.
                  final rawId = s.sasId.trim().isNotEmpty
                      ? s.sasId.trim()
                      : (s.sasData['id'] ?? s.sasData['user_id'] ?? '').toString().trim();
                  final userId = int.tryParse(rawId);

                  if (userId == null || userId == 0) {
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('تعذر التعطيل: معرف SAS غير صحيح (rawId=$rawId)')),
                      );
                    }
                    return;
                  }

                  try {
                    final settings = await SasSettings.load();
                    if (settings.username.trim().isEmpty || settings.password.isEmpty) {
                      throw Exception('أكمل إعدادات ربط SAS أولاً');
                    }

                    final api = SasApiService(settings);
                    await api.disableUser(userId).timeout(
                      const Duration(seconds: 30),
                      onTimeout: () => throw Exception('انتهت مهلة طلب التعطيل'),
                    );

                    s.disabled = true;
                    s.active = false;
                    await AppStore.save();

                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) {
                      setState(() {});
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('✅ تم تعطيل المشترك في SAS بنجاح')),
                      );
                    }
                  } catch (e) {
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) {
                      final errorStr = e.toString();
                      String msg;

                      if (errorStr.contains('403')) {
                        msg = '❌ خطأ 403: تحقق من صلاحيات المستخدم أو معرف SAS (userId=$userId)';
                      } else if (errorStr.contains('401')) {
                        msg = '❌ خطأ 401: فشل التحقق من البيانات. تحقق من بيانات الربط';
                      } else if (errorStr.contains('404')) {
                        msg = '❌ خطأ 404: المشترك غير موجود في SAS (userId=$userId)';
                      } else {
                        msg = '❌ فشل تعطيل المشترك في SAS: $errorStr';
                      }

                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(msg),
                          duration: const Duration(seconds: 5),
                        ),
                      );
                    }
                  }
                }),
                _op(Icons.lock_open, Colors.green, 'إلغاء التعطيل', () async {
                  // لا نغيّر الحالة محلياً إلا بعد نجاح إلغاء التعطيل الحقيقي في SAS.
                  final rawId = s.sasId.trim().isNotEmpty
                      ? s.sasId.trim()
                      : (s.sasData['id'] ?? s.sasData['user_id'] ?? '').toString().trim();
                  final userId = int.tryParse(rawId);

                  if (userId == null || userId == 0) {
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('تعذر إلغاء التعطيل: معرف SAS غير صحيح (rawId=$rawId)')),
                      );
                    }
                    return;
                  }

                  try {
                    final settings = await SasSettings.load();
                    if (settings.username.trim().isEmpty || settings.password.isEmpty) {
                      throw Exception('أكمل إعدادات ربط SAS أولاً');
                    }

                    final api = SasApiService(settings);
                    await api.enableUser(userId).timeout(
                      const Duration(seconds: 30),
                      onTimeout: () => throw Exception('انتهت مهلة طلب إلغاء التعطيل'),
                    );

                    s.disabled = false;
                    s.active = true;
                    await AppStore.save();

                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) {
                      setState(() {});
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('✅ تم إلغاء تعطيل المشترك في SAS بنجاح')),
                      );
                    }
                  } catch (e) {
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (mounted) {
                      final errorStr = e.toString();
                      String msg;

                      if (errorStr.contains('403')) {
                        msg = '❌ خطأ 403: تحقق من صلاحيات المستخدم أو معرف SAS (userId=$userId)';
                      } else if (errorStr.contains('401')) {
                        msg = '❌ خطأ 401: فشل التحقق من البيانات. تحقق من بيانات الربط';
                      } else if (errorStr.contains('404')) {
                        msg = '❌ خطأ 404: المشترك غير موجود في SAS (userId=$userId)';
                      } else {
                        msg = '❌ فشل إلغاء التعطيل في SAS: $errorStr';
                      }

                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(msg),
                          duration: const Duration(seconds: 5),
                        ),
                      );
                    }
                  }
                }),
                _op(Icons.account_balance_wallet, Colors.brown, 'الديون', () {
                  Navigator.pop(ctx);
                  _debt(s);
                }),
                _op(Icons.phone, Colors.blue, 'اتصال مباشر', () {
                  Navigator.pop(ctx);
                  phoneCall(s);
                }),
                _op(Icons.chat, const Color(0xFF2E7D32), 'رسائل واتساب', () {
                  Navigator.pop(ctx);
                  messageTemplates(s);
                }),
                _op(Icons.receipt_long, Colors.blue, 'طباعة الوصل', () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => ReceiptScreen(subscriber: s)),
                  );
                }),
                _op(Icons.delete_outline, Colors.red, 'حذف المشترك', () {
                  Navigator.pop(ctx);
                  _delete(s);
                }),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _op(IconData i, Color c, String t, VoidCallback f) =>
      ListTile(leading: Icon(i, color: c), title: Text(t), onTap: f);

  String _newGuid() {
    final r = Random.secure();
    String hex(int n) =>
        List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
    // نفس نمط ch.guid() في SAS: 8-4-4-4-12 بدون فرض UUID v4.
    return '${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}';
  }

  InputDecoration _greenDropdownDecoration(String label, IconData icon) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.black87),
        floatingLabelStyle: const TextStyle(color: Colors.black87),
        prefixIcon: Icon(icon, color: Colors.black87),
        filled: true,
        fillColor: const Color(0xFFF8FFF9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.grey.shade300, width: 1.2),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
          borderSide: BorderSide(color: Color(0xFF2E7D32), width: 2),
        ),
      );

  void _extend(Subscriber s) {
    int? selectedProfileId;
    String selectedMethod = 'reward_points';
    List<Map<String, dynamic>> profiles = [];
    bool loading = true;
    String? loadError;
    bool requested = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          Future<void> loadProfiles() async {
            try {
              final settings = await SasSettings.load();
              final api = SasApiService(settings);
              final rows = await api.fetchExtendProfiles(int.parse(s.sasId.toString()));
              if (!ctx.mounted) return;
              setLocal(() { profiles = rows; loading = false; loadError = null; });
            } catch (e) {
              if (!ctx.mounted) return;
              setLocal(() { loading = false; loadError = e.toString(); });
            }
          }

          if (!requested) {
            requested = true;
            Future.microtask(loadProfiles);
          }

          int? idOf(Map<String, dynamic> p) =>
              int.tryParse((p['id'] ?? p['profile_id'] ?? '').toString());
          String nameOf(Map<String, dynamic> p) =>
              (p['name'] ?? p['profile_name'] ?? 'ID ${idOf(p) ?? '-'}').toString();

          return Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text('تمديد الاشتراك'),
              content: loading
                  ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()))
                  : loadError != null
                      ? Column(mainAxisSize: MainAxisSize.min, children: [
                          Text('تعذر جلب الباقات: $loadError'),
                          TextButton.icon(
                            onPressed: () {
                              setLocal(() { loading = true; loadError = null; });
                              loadProfiles();
                            },
                            icon: const Icon(Icons.refresh),
                            label: const Text('إعادة المحاولة'),
                          ),
                        ])
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DropdownButtonFormField<int>(
                              initialValue: selectedProfileId,
                              decoration: _greenDropdownDecoration('اختر الباقة', Icons.inventory_2_outlined),
                              dropdownColor: const Color(0xFFF8FFF9),
                              iconEnabledColor: Colors.black87,
                              style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w600),
                              items: profiles.where((p) => idOf(p) != null).map((p) =>
                                DropdownMenuItem<int>(
                                  value: idOf(p),
                                  child: Text(nameOf(p)),
                                )
                              ).toList(),
                              onChanged: (v) => setLocal(() => selectedProfileId = v),
                            ),
                            const SizedBox(height: 16),
                            DropdownButtonFormField<String>(
                              initialValue: selectedMethod,
                              decoration: _greenDropdownDecoration('نوع التمديد', Icons.autorenew),
                              dropdownColor: const Color(0xFFF8FFF9),
                              iconEnabledColor: Colors.black87,
                              style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w600),
                              items: const [
                                DropdownMenuItem(
                                  value: 'credit',
                                  child: Text('رصيد المدير'),
                                ),
                                DropdownMenuItem(
                                  value: 'reward_points',
                                  child: Text('النقاط التشجيعية'),
                                ),
                              ],
                              onChanged: (v) {
                                if (v != null) setLocal(() => selectedMethod = v);
                              },
                            ),
                          ],
                        ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
                FilledButton(
                  onPressed: loading || selectedProfileId == null ? null : () async {
                    final rawUserId = s.sasId.trim().isNotEmpty
                        ? s.sasId.trim()
                        : (s.sasData['id'] ?? s.sasData['user_id'] ?? '').toString().trim();
                    final userId = int.tryParse(rawUserId);
                    if (userId == null) {
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                      }
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('لا يوجد SAS ID صحيح للمشترك')),
                        );
                      }
                      return;
                    }
                    try {
                      final settings = await SasSettings.load();
                      final api = SasApiService(settings);
                      final transactionId = _newGuid();

                      await api.extendUser(
                        userId: userId,
                        profileId: selectedProfileId!,
                        method: selectedMethod,
                        transactionId: transactionId,
                      ).timeout(const Duration(seconds: 30),
                        onTimeout: () => throw Exception('انتهت مهلة طلب التمديد'));
                      if (ctx.mounted) Navigator.pop(ctx);

                      // v091: لا ننتظر مزامنة جميع المشتركين بعد التمديد.
                      // نجلب المشترك نفسه فقط، ثم نحدّث الواجهة فوراً.
                      try {
                        final fresh = await api.fetchUser(userId);
                        if (fresh is Map) {
                          s.sasData = Map<String, dynamic>.from(fresh);
                          final endRaw = fresh['expiration'] ??
                              fresh['expiration_date'] ??
                              fresh['expires_at'] ??
                              fresh['end_date'];
                          final parsedEnd = DateTime.tryParse((endRaw ?? '').toString());
                          if (parsedEnd != null) s.endDate = parsedEnd;
                          await AppStore.save();
                        }
                      } catch (_) {
                        // نجاح التمديد لا يُلغى إذا تعذر تحديث التفاصيل اللحظي.
                      }
                      if (mounted) setState(() {});

                      // Keep renewal success independent from WhatsApp availability.
                      RenderWhatsAppService.dispatchInBackground(
                        _sendRenewalWhatsAppMessage(s),
                      );

                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'تم تمديد المشترك في SAS بنجاح',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                            ),
                          ),
                        );
                      }
                    } catch (e) {
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        final msg = e.toString().contains('الرصيد غير كافٍ')
                            ? 'الرصيد غير كافٍ' : 'فشل التمديد في SAS: $e';
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              msg,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                            ),
                            duration: const Duration(seconds: 4),
                          ),
                        );
                      }
                    }
                  },
                  child: const Text('تمديد'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _sendRenewalWhatsAppMessage(Subscriber s) async {
    final result = await RenderWhatsAppService.notifySubscriptionRenewed(
      s,
      template: AppStore.messageTemplates['extension'],
    );

    if (!result.success) {
      debugPrint('Renewal WhatsApp send failed: ${result.error ?? 'unknown'}');
    }
  }

  Future<void> _changePackage(Subscriber s) async {
    final rawId = s.sasId.trim().isNotEmpty
        ? s.sasId.trim()
        : (s.sasData['id'] ?? s.sasData['user_id'] ?? '').toString().trim();
    final userId = int.tryParse(rawId);
    if (userId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا يوجد SAS ID صحيح للمشترك')),
      );
      return;
    }

    try {
      final settings = await SasSettings.load();
      final api = SasApiService(settings);
      if (!mounted) return;
      showDialog(context: context, barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()));

      final profiles = await api.fetchProfiles().timeout(const Duration(seconds: 30));
      if (mounted) Navigator.pop(context);
      if (!mounted) return;

      int? idOf(Map<String,dynamic> p) =>
          int.tryParse((p['id'] ?? p['profile_id'] ?? '').toString());
      String nameOf(Map<String,dynamic> p) =>
          (p['name'] ?? p['profile_name'] ?? 'بدون اسم').toString();
      final usable = profiles.where((p) => idOf(p) != null).toList();

      final selected = await showDialog<Map<String,dynamic>>(
        context: context,
        builder: (ctx) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: Text('تغيير باقة ${s.name}'),
            content: SizedBox(width: 420, child: ListView.separated(
              shrinkWrap: true,
              itemCount: usable.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_,i) {
                final p=usable[i];
                return ListTile(
                  leading: const Icon(Icons.speed_outlined),
                  title: Text(nameOf(p)),
                  subtitle: Text('ID: ${idOf(p)}'),
                  onTap: () => Navigator.pop(ctx,p),
                );
              },
            )),
            actions: [TextButton(onPressed: ()=>Navigator.pop(ctx), child: const Text('إلغاء'))],
          ),
        ),
      );
      if (selected == null || !mounted) return;

      final profileId=idOf(selected)!;
      final profileName=nameOf(selected);
      final ok=await showDialog<bool>(
        context: context,
        builder:(ctx)=>Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('تأكيد تغيير الباقة'),
            content: Text('تغيير باقة ${s.name} إلى $profileName الآن؟'),
            actions:[
              TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),
              FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('تغيير')),
            ],
          ),
        ),
      );
      if(ok!=true || !mounted) return;

      showDialog(context: context, barrierDismissible:false,
        builder:(_)=>const Center(child:CircularProgressIndicator()));

      await api.changeUserProfile(
        userId:userId, profileId:profileId, changeType:'immediate'
      ).timeout(const Duration(seconds:30));

      try {
        final overview=await api.fetchUserOverview(userId);
        if(overview is Map) s.sasData.addAll(Map<String,dynamic>.from(overview));
      } catch(_) {}

      s.setPackageValue(profileName);
      await AppStore.save();
      if(mounted) Navigator.pop(context);
      if(!mounted) return;
      setState((){});

      final isExpired=s.endDate.isBefore(DateTime.now()) || s.expired;
      if(isExpired){
        final activate=await showDialog<bool>(
          context:context,
          builder:(ctx)=>Directionality(
            textDirection:TextDirection.rtl,
            child:AlertDialog(
              title:const Text('تم تغيير الباقة بنجاح'),
              content:const Text('المشترك منتهي الاشتراك. تغيير الباقة لا يفعّله تلقائياً.\nهل تريد تفعيله الآن؟'),
              actions:[
                TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('لاحقاً')),
                FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('تفعيل الآن')),
              ],
            ),
          ),
        );
        if(activate==true && mounted){
          showDialog(context:context,barrierDismissible:false,
            builder:(_)=>const Center(child:CircularProgressIndicator()));
          final activationResponse = await api.activateUser(userId)
              .timeout(const Duration(seconds:30));
          s.active=true; s.disabled=false;
          _setStartDateAsActivationDay(s);
          await AppStore.addDailyTaskEvent(
            DailyTaskEvent(
              type: 'activation',
              subscriberUser: s.user,
              subscriberName: s.name,
              at: DateTime.now(),
              amount: _activationReceivedAmount(activationResponse),
              remainingAfter: s.remaining,
              note: 'تفعيل بعد تغيير الباقة',
            ),
            persist: false,
          );
          await AppStore.save();
          if(mounted) Navigator.pop(context);
          await _sendActivationWhatsApp(s);
          if (!mounted) return;
          if(mounted){
            setState((){});
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content:Text('تم تغيير الباقة وتفعيل المشترك في SAS بنجاح')));
          }
        }
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content:Text('تم تغيير الباقة إلى $profileName بنجاح')),
        );
      }
    } catch(e) {
      if(mounted){
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content:Text('فشل تغيير الباقة: $e')));
      }
    }
  }

  void _debt(Subscriber s, {bool autoOpenReceiptAfterSave = false}) {
    final price = TextEditingController(text: s.price.toStringAsFixed(0));
    final paid = TextEditingController(text: s.paid.toStringAsFixed(0));
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: Text('ديون ${s.name}'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: price,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'مبلغ الاشتراك', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: price,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'مبلغ الاشتراك', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: paid,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setLocal(() {}),
                  decoration: const InputDecoration(labelText: 'الواصل', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                Builder(builder: (_) {
                  final priceAmount = _parseAmount(price.text.trim()) ?? s.price;
                  final paidAmount = _parseAmount(paid.text.trim()) ?? s.paid;
                  final targetPaidAmount = (paidAmount).clamp(0, priceAmount);
                  final previewRemaining = (priceAmount - targetPaidAmount).clamp(0, double.infinity);
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('مبلغ الاشتراك: ${priceAmount.toStringAsFixed(0)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 6),
                        Text('الواصل: ${targetPaidAmount.toStringAsFixed(0)}'),
                        const SizedBox(height: 6),
                        Text('المتبقي: ${previewRemaining.toStringAsFixed(0)}'),
                      ],
                    ),
                  );
                }),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
              FilledButton(
                onPressed: () async {
                  final oldPaid = s.paid;
                  final oldRemaining = s.remaining;
                  final newPrice = _parseAmount(price.text.trim());
                  final newPaidAmount = _parseAmount(paid.text.trim());
                  if (newPrice == null || newPrice < 0) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('أدخل مبلغ اشتراك صحيح')),
                      );
                    }
                    return;
                  }
                  if (newPaidAmount == null) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('أدخل قيمة الواصل')),
                      );
                    }
                    return;
                  }

                  s.price = newPrice;
                  s.normalizeDebtFields();

                  final now = DateTime.now();
                  final targetPaidAmount = newPaidAmount.clamp(0, newPrice).toDouble();
                  final delta = s.adjustPaidToTarget(
                    targetPaidAmount,
                    at: now,
                    increaseNote: 'تعديل الواصل من شاشة الديون',
                    decreaseNote: 'تخفيض الواصل من شاشة الديون',
                  );
                  if (delta.abs() <= 0.0001) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('لا يوجد تعديل فعلي على الديون')),
                      );
                    }
                    return;
                  }

                  final receiptNumber = await AppStore.issueReceiptNumber(persist: false);
                  final invoice = s.registerInvoiceFromPayment(
                    receiptNumber: receiptNumber,
                    amount: delta.abs(),
                    at: now,
                    note: s.remaining <= 0.0001
                        ? 'تعديل تسديد كامل'
                        : 'تعديل تسديد جزئي',
                  );

                  if (delta > 0) {
                    await AppStore.addDailyTaskEvent(
                      DailyTaskEvent(
                        type: 'debt_payment',
                        subscriberUser: s.user,
                        subscriberName: s.name,
                        at: now,
                        amount: delta.abs(),
                        remainingAfter: s.remaining,
                        note: s.remaining <= 0.0001
                            ? 'تسديد كامل'
                            : 'تسديد جزئي',
                      ),
                      persist: false,
                    );
                  }

                  s.paymentDate = fmt(now);
                  await AppStore.save();

                  if (ctx.mounted) Navigator.pop(ctx);

                  if (autoOpenReceiptAfterSave && mounted) {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ReceiptScreen(
                          subscriber: s,
                          invoice: invoice,
                        ),
                      ),
                    );
                  }

                  if (s.remaining > 0) {
                    await RenderWhatsAppService.notifyDebtAdded(
                      s,
                      amountAdded: delta.abs(),
                      remainingBalance: s.remaining,
                      template: AppStore.messageTemplates['debt'],
                    );
                  }

                  await AutoNotificationService.notifyDebtSettledIfNeeded(
                    subscriber: s,
                    oldRemaining: oldRemaining,
                    newRemaining: s.remaining,
                  );
                  if (mounted) {
                    setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'تم الحفظ: الاشتراك ${newPrice.toStringAsFixed(0)} | الواصل ${oldPaid.toStringAsFixed(0)} -> ${s.paid.toStringAsFixed(0)} | '
                          'المتبقي ${oldRemaining.toStringAsFixed(0)} -> ${s.remaining.toStringAsFixed(0)}',
                        ),
                      ),
                    );
                  }
                },
                child: const Text('حفظ'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showColumnSelector() {
    showDialog(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.view_column_outlined),
              SizedBox(width: 8),
              Text('إظهار/إخفاء الأعمدة'),
            ],
          ),
          content: StatefulBuilder(
            builder: (ctx, setLocal) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CheckboxListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 0),
                  controlAffinity: ListTileControlAffinity.trailing,
                  dense: true,
                  title: const Text('IP'),
                  subtitle: const Text('عرض عنوان IP للمشترك'),
                  value: _columnVisibility['ip'] == true,
                  onChanged: (v) {
                    setLocal(() => _columnVisibility['ip'] = v ?? false);
                    setState(() {});
                    _saveColumnPreferences();
                  },
                ),
                CheckboxListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 0),
                  controlAffinity: ListTileControlAffinity.trailing,
                  dense: true,
                  title: const Text('الأيام المتبقية'),
                  subtitle: const Text('عرض عدد الأيام المتبقية للاشتراك'),
                  value: _columnVisibility['remainingDays'] == true,
                  onChanged: (v) {
                    setLocal(() => _columnVisibility['remainingDays'] = v ?? false);
                    setState(() {});
                    _saveColumnPreferences();
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      ),
    );
  }

  void _delete(Subscriber s) {
    showDialog(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف المشترك'),
          content: Text('هل تريد حذف ${s.name}؟'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () async {
                AppStore.subscribers.remove(s);
                selected = null;
                await AppStore.save();
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) setState(() {});
              },
              child: const Text('حذف'),
            ),
          ],
        ),
      ),
    );
  }

  String _sasText(Subscriber s, List<String> keys, [String fallback = '—']) {
    for (final key in keys) {
      final v = s.sasData[key];
      if (v != null && v.toString().trim().isNotEmpty) return v.toString().trim();
    }
    return fallback;
  }

  Future<void> _showAdvancedSearch() async {
    final packages = AppStore.subscribers.map((e) => e.packageDisplay.trim())
        .where((e) => e.isNotEmpty).toSet().toList()..sort();
    final parents = AppStore.subscribers.map(_parentText)
        .where((e) => e.isNotEmpty).toSet().toList()..sort();

    var status = _advancedStatus;
    var package = packages.contains(_advancedPackage) ? _advancedPackage : 'الكل';
    var parent = parents.contains(_advancedParent) ? _advancedParent : 'الكل';
    var connection = _advancedConnection;
    var includeSubs = _includeSubUsers;
    final macC = TextEditingController(text: _advancedMac);
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Row(children: [
              Icon(Icons.filter_alt_outlined),
              SizedBox(width: 8),
              Text('البحث المتقدم'),
            ]),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: status,
                      decoration: _greenDropdownDecoration('الحالة', Icons.info_outline),
                      dropdownColor: const Color(0xFFF8FFF9),
                      iconEnabledColor: const Color(0xFF2E7D32),
                      style: const TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.w600),
                        items: const ['الكل','فعال','منتهي الصلاحية','معطل','ينتهي قريباً','خلال 3 أيام','ينتهي اشتراكهم اليوم']
                          .map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                      onChanged: (v) => setLocal(() => status = v ?? 'الكل'),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: connection,
                      decoration: _greenDropdownDecoration('الاتصال', Icons.wifi_outlined),
                      dropdownColor: const Color(0xFFF8FFF9),
                      iconEnabledColor: const Color(0xFF2E7D32),
                      style: const TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.w600),
                      items: const ['الكل', 'متصل', 'غير متصل']
                          .map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                      onChanged: (v) => setLocal(() => connection = v ?? 'الكل'),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: package,
                      decoration: _greenDropdownDecoration('الباقة', Icons.inventory_2_outlined),
                      dropdownColor: const Color(0xFFF8FFF9),
                      iconEnabledColor: const Color(0xFF2E7D32),
                      style: const TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.w600),
                      items: ['الكل', ...packages]
                          .map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                      onChanged: (v) => setLocal(() => package = v ?? 'الكل'),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: parent,
                      decoration: _greenDropdownDecoration('تابع إلى', Icons.person_outline),
                      dropdownColor: const Color(0xFFF8FFF9),
                      iconEnabledColor: const Color(0xFF2E7D32),
                      style: const TextStyle(color: Color(0xFF2E7D32), fontWeight: FontWeight.w600),
                      items: ['الكل', ...parents]
                          .map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                      onChanged: (v) => setLocal(() => parent = v ?? 'الكل'),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('المشتركين الفرعيين'),
                      subtitle: const Text('تضمين المشتركين الفرعيين في النتائج'),
                      value: includeSubs,
                      onChanged: (v) => setLocal(() => includeSubs = v),
                    ),
                    TextField(
                      controller: macC,
                      decoration: InputDecoration(
                        labelText: 'MAC Address',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.router_outlined),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  setState(() {
                    _advancedStatus = 'الكل';
                    _advancedConnection = 'الكل';
                    _advancedPackage = 'الكل';
                    _advancedParent = 'الكل';
                    _includeSubUsers = true;
                    _advancedMac = '';
                    selected = null;
                    _filteredSubscribers = _buildFilteredSubscribers();
                  });
                  Navigator.pop(ctx);
                },
                child: const Text('مسح الفلاتر'),
              ),
              FilledButton.icon(
                onPressed: () {
                  setState(() {
                    _advancedStatus = status;
                    _advancedConnection = connection;
                    _advancedPackage = package;
                    _advancedParent = parent;
                    _includeSubUsers = includeSubs;
                    _advancedMac = macC.text.trim();
                    selected = null;
                    _filteredSubscribers = _buildFilteredSubscribers();
                  });
                  Navigator.pop(ctx);
                },
                icon: const Icon(Icons.search),
                label: const Text('بحث'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summaryChip({required IconData icon, required String label, required String value, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _filteredSubscribers;
    final tableWidth = max(946.0, MediaQuery.of(context).size.width - 48);
    final green = const Color(0xFF2E7D32);
    final greenSoft = const Color(0xFFD8F3DC);
    final activeCount = data.where((s) => s.isActive && !s.disabled && !s.expired).length;
    final expiringSoonCount = data.where((s) {
      if (s.disabled || s.expired) return false;
      final days = s.endDate.difference(DateTime.now()).inDays;
      return days == 3;
    }).length;
    final debtCount = data.where((s) => s.remaining > 0).length;
    final dataSource = _SubscribersDataSource(
      context: context,
      data: data,
      selectedSubscriber: selected,
      onSelect: (s) => setState(() => selected = s),
      onNameTap: (s) async {
        setState(() => selected = s);
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => SubscriberDetailsScreen(subscriber: s)),
        );
        if (mounted) setState(() {});
      },
      onActionSelected: (s, action) async {
        switch (action) {
          case 'activate':
            await _activateSubscriber(s);
            break;
          case 'renew':
            _extend(s);
            break;
          case 'receipt':
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ReceiptScreen(subscriber: s)),
            );
            break;
          case 'edit':
            final changed = await Navigator.push<bool>(
              context,
              MaterialPageRoute(builder: (_) => AddSubscriberScreen(subscriber: s)),
            );
            if (changed == true && mounted) setState(() {});
            break;
          case 'add':
            await add();
            break;
          case 'change_package':
            await _changePackage(s);
            break;
          case 'disable':
            final rawId = s.sasId.trim().isNotEmpty
                ? s.sasId.trim()
                : (s.sasData['id'] ?? s.sasData['user_id'] ?? '').toString().trim();
            final userId = int.tryParse(rawId);
            if (userId == null) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('تعذر التعطيل: لا يوجد SAS ID صحيح للمشترك')),
                );
              }
              break;
            }
            try {
              final settings = await SasSettings.load();
              if (settings.username.trim().isEmpty || settings.password.isEmpty) {
                throw Exception('أكمل إعدادات ربط SAS أولاً');
              }
              final api = SasApiService(settings);
              await api.disableUser(userId).timeout(
                const Duration(seconds: 30),
                onTimeout: () => throw Exception('انتهت مهلة طلب التعطيل'),
              );
              s.disabled = true;
              s.active = false;
              await AppStore.save();
              if (mounted) setState(() {});
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('فشل تعطيل المشترك في SAS: $e')),
                );
              }
            }
            break;
          case 'enable':
            final rawId = s.sasId.trim().isNotEmpty
                ? s.sasId.trim()
                : (s.sasData['id'] ?? s.sasData['user_id'] ?? '').toString().trim();
            final userId = int.tryParse(rawId);
            if (userId == null) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('تعذر إلغاء التعطيل: لا يوجد SAS ID صحيح للمشترك')),
                );
              }
              break;
            }
            try {
              final settings = await SasSettings.load();
              if (settings.username.trim().isEmpty || settings.password.isEmpty) {
                throw Exception('أكمل إعدادات ربط SAS أولاً');
              }
              final api = SasApiService(settings);
              await api.enableUser(userId).timeout(
                const Duration(seconds: 30),
                onTimeout: () => throw Exception('انتهت مهلة طلب إلغاء التعطيل'),
              );
              s.disabled = false;
              s.active = true;
              await AppStore.save();
              if (mounted) setState(() {});
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('فشل إلغاء التعطيل في SAS: $e')),
                );
              }
            }
            break;
          case 'debts':
            _debt(s);
            break;
          case 'notifications':
            messageTemplates(s);
            break;
          case 'call':
            await phoneCall(s);
            break;
          case 'whatsapp':
            await whatsapp(s);
            break;
          case 'delete':
            _delete(s);
            break;
          case 'details':
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => SubscriberDetailsScreen(subscriber: s)),
            );
            if (mounted) setState(() {});
            break;
          default:
            break;
        }
      },
      columnVisibility: _columnVisibility,
    );

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(pageTitle),
          centerTitle: true,
          actions: [
            IconButton(
              tooltip: 'تحديث',
              onPressed: syncing || _isRefreshing ? null : _refreshSubscribers,
              icon: syncing || _isRefreshing
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: 'مزامنة SAS الآن',
              onPressed: syncing || _isRefreshing ? null : syncNow,
              icon: syncing || _isRefreshing
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: add,
          backgroundColor: green,
          foregroundColor: Colors.white,
          child: const Icon(Icons.person_add),
        ),
        body: Scrollbar(
          controller: _verticalScrollController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _verticalScrollController,
            child: Column(
              children: [
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        greenSoft.withValues(alpha: 0.9),
                        Theme.of(context).colorScheme.surface,
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                    border: Border(bottom: BorderSide(color: Colors.grey.shade200, width: 1)),
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'قائمة المشتركين',
                                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'إدارة وتنظيم المشتركين',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey.shade600),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                              color: greenSoft.withValues(alpha: 0.85),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: green.withValues(alpha: 0.3)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.people_alt_outlined, size: 18, color: green),
                                const SizedBox(width: 6),
                                Text(
                                  '${data.length}',
                                  style: TextStyle(fontWeight: FontWeight.bold, color: green),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _summaryChip(
                            icon: Icons.check_circle_outline,
                            label: 'نشط',
                            value: activeCount.toString(),
                            color: green,
                          ),
                          _summaryChip(
                            icon: Icons.warning_amber_rounded,
                            label: 'خلال 3 أيام',
                            value: expiringSoonCount.toString(),
                            color: const Color(0xFFB8860B),
                          ),
                          _summaryChip(
                            icon: Icons.account_balance_wallet_outlined,
                            label: 'ديون',
                            value: debtCount.toString(),
                            color: const Color(0xFFC62828),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        onChanged: (v) {
                          q = v;
                          selected = null;
                          _reloadSubscribers();
                        },
                        decoration: InputDecoration(
                          hintText: 'ابحث عن مشترك...',
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: q.isEmpty
                              ? null
                              : IconButton(
                                  onPressed: () {
                                    q = '';
                                    selected = null;
                                    _reloadSubscribers();
                                  },
                                  icon: const Icon(Icons.clear_rounded),
                                ),
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.grey.shade300),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.grey.shade300),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: green, width: 2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: FilledButton.icon(
                              onPressed: selected == null ? null : operations,
                              icon: const Icon(Icons.settings_outlined, size: 18),
                              label: const Text('عمليات سريعة'),
                              style: FilledButton.styleFrom(
                                backgroundColor: green,
                                foregroundColor: Colors.white,
                                minimumSize: const Size(0, 48),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: OutlinedButton.icon(
                              onPressed: _showAdvancedSearch,
                              icon: const Icon(Icons.filter_alt_outlined, size: 18),
                              label: const Text('تصفية'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: green,
                                side: BorderSide(color: green.withValues(alpha: 0.35)),
                                backgroundColor: greenSoft.withValues(alpha: 0.2),
                                minimumSize: const Size(0, 48),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _showColumnSelector,
                              icon: const Icon(Icons.view_column_outlined, size: 18),
                              label: const Text('المزيد'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: green,
                                side: BorderSide(color: green.withValues(alpha: 0.35)),
                                backgroundColor: greenSoft.withValues(alpha: 0.2),
                                minimumSize: const Size(0, 48),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                if (data.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.people_outline, size: 64, color: Colors.grey.shade300),
                        const SizedBox(height: 16),
                        Text(
                          'لا توجد مشتركين',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  )
                else
                  Card(
                    margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    elevation: 2,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Scrollbar(
                        controller: _horizontalScrollController,
                        thumbVisibility: true,
                          child: SingleChildScrollView(
                          controller: _horizontalScrollController,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: tableWidth,
                            child: Theme(
                              data: Theme.of(context).copyWith(
                                dataTableTheme: DataTableThemeData(
                                  headingRowColor: WidgetStateProperty.all(
                                    greenSoft.withValues(alpha: 0.85),
                                  ),
                                  headingRowHeight: 56,
                                  dataRowMinHeight: 64,
                                  dataRowMaxHeight: 64,
                                  dividerThickness: 1,
                                  headingTextStyle: const TextStyle(
                                    color: Color(0xFF2E7D32),
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              child: PaginatedDataTable(
                                showCheckboxColumn: false,
                                horizontalMargin: 8,
                                columnSpacing: 8,
                                rowsPerPage: _rowsPerPage,
                                availableRowsPerPage: const [10, 50, 500],
                                onRowsPerPageChanged: (value) {
                                  if (value != null) setState(() => _rowsPerPage = value);
                                },
                                sortColumnIndex: _sortColumnIndex,
                                sortAscending: _sortAsc,
                                columns: [
                                  const DataColumn(label: Text('م', style: TextStyle(fontWeight: FontWeight.bold))),
                                  DataColumn(
                                    label: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment: CrossAxisAlignment.center,
                                      textDirection: TextDirection.rtl,
                                      children: [
                                        const Icon(Icons.info_outline, size: 18),
                                        const SizedBox(width: 8),
                                        const Text('الحالة', style: TextStyle(fontWeight: FontWeight.bold)),
                                        if (_sortBy == 'status')
                                          Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 14),
                                      ],
                                    ),
                                    onSort: (index, ascending) => _sort('status', index),
                                  ),
                                  DataColumn(
                                    label: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment: CrossAxisAlignment.center,
                                      textDirection: TextDirection.rtl,
                                      children: [
                                        const Icon(Icons.person_outline, size: 18),
                                        const SizedBox(width: 6),
                                        const Text('اسم المشترك', style: TextStyle(fontWeight: FontWeight.bold)),
                                        if (_sortBy == 'name')
                                          Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 14),
                                      ],
                                    ),
                                    onSort: (index, ascending) => _sort('name', index),
                                  ),
                                  DataColumn(
                                    label: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment: CrossAxisAlignment.center,
                                      textDirection: TextDirection.rtl,
                                      children: [
                                        const Icon(Icons.account_circle_outlined, size: 18),
                                        const SizedBox(width: 8),
                                        const Text('اسم المستخدم', style: TextStyle(fontWeight: FontWeight.bold)),
                                        if (_sortBy == 'user')
                                          Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 14),
                                      ],
                                    ),
                                    onSort: (index, ascending) => _sort('user', index),
                                  ),
                                  DataColumn(
                                    label: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment: CrossAxisAlignment.center,
                                      textDirection: TextDirection.rtl,
                                      children: [
                                        const Icon(Icons.inventory_2_outlined, size: 18),
                                        const SizedBox(width: 8),
                                        const Text('الباقة', style: TextStyle(fontWeight: FontWeight.bold)),
                                        if (_sortBy == 'package')
                                          Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 14),
                                      ],
                                    ),
                                    onSort: (index, ascending) => _sort('package', index),
                                  ),
                                  DataColumn(
                                    label: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment: CrossAxisAlignment.center,
                                      textDirection: TextDirection.rtl,
                                      children: [
                                        const Icon(Icons.event_outlined, size: 18),
                                        const SizedBox(width: 8),
                                        const Text('تاريخ الانتهاء', style: TextStyle(fontWeight: FontWeight.bold)),
                                        if (_sortBy == 'date')
                                          Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward, size: 14),
                                      ],
                                    ),
                                    onSort: (index, ascending) => _sort('date', index),
                                  ),
                                  // Connection column removed
                                  DataColumn(
                                    label: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment: CrossAxisAlignment.center,
                                      textDirection: TextDirection.rtl,
                                      children: [
                                        const Icon(Icons.language, size: 18),
                                        const SizedBox(width: 8),
                                        const Text('IP', style: TextStyle(fontWeight: FontWeight.bold)),
                                      ],
                                    ),
                                  ),
                                  DataColumn(
                                    label: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment: CrossAxisAlignment.center,
                                      textDirection: TextDirection.rtl,
                                      children: [
                                        const Icon(Icons.schedule_outlined, size: 18),
                                        const SizedBox(width: 8),
                                        const Text('الأيام', style: TextStyle(fontWeight: FontWeight.bold)),
                                      ],
                                    ),
                                  ),
                                ],
                                source: dataSource,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SubscribersDataSource extends DataTableSource {
  _SubscribersDataSource({
    required this.context,
    required this.data,
    required this.selectedSubscriber,
    required this.onSelect,
    required this.onNameTap,
    required this.onActionSelected,
    required this.columnVisibility,
  });

  final BuildContext context;
  final List<Subscriber> data;
  final Subscriber? selectedSubscriber;
  final ValueChanged<Subscriber> onSelect;
  final Future<void> Function(Subscriber) onNameTap;
  final Future<void> Function(Subscriber, String) onActionSelected;
  final Map<String, bool> columnVisibility;

  String _fmt(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  Color _statusColor(Subscriber s) {
    // Disabled users keep the orange highlight.
    if (s.disabled) return Colors.orange;

    final online = s.isOnline;
    if (s.expired) {
      return online ? Colors.red : Colors.orange;
    }
    return online ? Colors.blue : Colors.green;
  }

  @override
  DataRow? getRow(int index) {
    if (index >= data.length) return null;
    final s = data[index];
    // One-time debug: dump sasData for a specific subscriber to inspect online fields
    final selected = identical(selectedSubscriber, s);
    final remainingDays = DateTime.now().difference(s.endDate).inDays * -1;
    final cells = [
      DataCell(ConstrainedBox(constraints: const BoxConstraints(maxWidth: 48), child: Text('${index + 1}', textAlign: TextAlign.center))),
      DataCell(
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 64),
          child: Center(
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: _statusColor(s),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: _statusColor(s).withValues(alpha: 0.5),
                    blurRadius: 4,
                    spreadRadius: 0,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      DataCell(
        InkWell(
          onTap: () async {
            onSelect(s);
            await onNameTap(s);
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Text(
              s.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.blue.shade700,
              ),
            ),
          ),
        ),
      ),
      DataCell(ConstrainedBox(constraints: const BoxConstraints(maxWidth: 200), child: Text(s.user, overflow: TextOverflow.ellipsis))),
      DataCell(
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 160),
          child: Text(
            s.packageDisplay,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.blue.shade700,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      DataCell(ConstrainedBox(constraints: const BoxConstraints(maxWidth: 160), child: Text(_fmt(s.endDate), overflow: TextOverflow.ellipsis))),
      // Connection column removed
      // عمود IP (دائماً)
      DataCell(
        columnVisibility['ip'] == true
            ? ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: InkWell(
                  onTap: () async {
                    final ip = s.ip.trim();
                    if (ip.isEmpty) return;
                    String url;
                    if (ip.contains(':') && !ip.startsWith('[')) {
                      url = 'http://[$ip]';
                    } else {
                      url = 'http://$ip';
                    }
                    final uri = Uri.parse(url);
                    try {
                      await launchUrl(uri, mode: LaunchMode.externalApplication);
                    } catch (_) {}
                  },
                  child: Text(
                    s.ip.isEmpty ? '—' : s.ip,
                    style: TextStyle(fontWeight: FontWeight.w600, color: Colors.blue.shade700),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
            : const SizedBox.shrink(),
      ),
      // عمود الأيام (دائماً)
      DataCell(
        columnVisibility['remainingDays'] == true
            ? ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: remainingDays < 0
                      ? Colors.red.withValues(alpha: 0.15)
                        : remainingDays < 7
                        ? Colors.orange.withValues(alpha: 0.15)
                        : Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    remainingDays < 0 ? 'منتهي' : '$remainingDays يوم',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: remainingDays < 0
                          ? Colors.red
                          : remainingDays < 7
                              ? Colors.orange
                              : Colors.green,
                    ),
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
            : const SizedBox.shrink(),
      ),
    ];

    return DataRow(
      selected: selected,
      onSelectChanged: (_) => onSelect(s),
      cells: cells,
    );
  }

  @override
  int get rowCount => data.length;

  @override
  bool get isRowCountApproximate => false;

  @override
  int get selectedRowCount => 0;
}