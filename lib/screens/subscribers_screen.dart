import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models.dart';
import '../sas_api_service.dart';
import '../sas_project_national_service.dart';
import '../sas_sync_service.dart';
import '../services/render_whatsapp_service.dart';
import '../services/subscriber_financial_ledger.dart';
import '../services/whatsapp_notification_dispatcher.dart';
import 'activation_payment_dialog.dart';
import 'add_subscriber_screen.dart';
import 'ftth_activation_dialog.dart';
import 'ftth_payment_screen.dart';
import 'dashboard_widgets.dart';
import 'partial_payment_flow.dart';
import 'quick_reports_screen.dart';
import 'receipt_screen.dart';
import 'settings_screen.dart';
import 'subscriber_details_screen.dart';

class SubscribersScreen extends StatefulWidget {
  final String filter;
  final String initialSearch;
  const SubscribersScreen({
    super.key,
    this.filter = 'all',
    this.initialSearch = '',
  });

  @override
  State<SubscribersScreen> createState() => _SubscribersScreenState();
}

class _SubscribersScreenState extends State<SubscribersScreen> {
  final ScrollController _verticalScrollController = ScrollController();

  bool operationBusy = false;
  Subscriber? selected;
  late String q = widget.initialSearch;
  late final TextEditingController _searchController = TextEditingController(
    text: widget.initialSearch,
  );
  bool syncing = false;
  late String _filter = widget.filter;
  bool? _cardView;
  int _visibleCards = 50;
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
    // أسماء الساسات الإضافية لبطاقات المشتركين.
    if (AppStore.subscribers.any(
      (s) => s.sasAccount.isNotEmpty || s.sasIds.isNotEmpty,
    )) {
      SasSettings.loadAll().then((_) {
        if (mounted) setState(() {});
      }, onError: (_) {});
    }
    _filteredSubscribers = _buildFilteredSubscribers();
    AppStore.subscribersChange.addListener(_onSubscribersChanged);
  }

  /// المزامنة وأجهزة الوكيل الأخرى قد تستبدل كائنات المشتركين في أي وقت.
  void _onSubscribersChanged() {
    if (!mounted) return;
    setState(() {
      final current = selected;
      selected = null;
      if (current != null) {
        for (final subscriber in AppStore.subscribers) {
          if (subscriber.subscriberId == current.subscriberId) {
            selected = subscriber;
            break;
          }
        }
      }
      _filteredSubscribers = _buildFilteredSubscribers();
    });
  }

  Future<void> _loadColumnPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _columnVisibility['ip'] = prefs.getBool('col_ip') ?? true;
      _columnVisibility['remainingDays'] =
          prefs.getBool('col_remainingDays') ?? true;
      _columnVisibility['debtDays'] = prefs.getBool('col_debtDays') ?? false;
    });
  }

  Future<void> _saveColumnPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('col_ip', _columnVisibility['ip'] ?? false);
    await prefs.setBool(
      'col_remainingDays',
      _columnVisibility['remainingDays'] ?? false,
    );
    await prefs.setBool('col_debtDays', _columnVisibility['debtDays'] ?? false);
  }

  List<Subscriber> _filteredSubscribers = [];

  List<Subscriber> _buildFilteredSubscribers() {
    final z = q.toLowerCase().trim();
    final now = DateTime.now();
    final filtered = AppStore.subscribers.where((s) {
      if (!_matchesFilter(s, _filter, now)) return false;

      final basicMatch =
          s.user.toLowerCase().contains(z) ||
          s.name.toLowerCase().contains(z) ||
          s.phone.contains(z) ||
          s.ip.contains(z) ||
          s.type.toLowerCase().contains(z) ||
          s.packageDisplay.toLowerCase().contains(z);
      if (!basicMatch) return false;

      if (_advancedStatus != 'الكل') {
        if (_advancedStatus == 'فعال' && (!s.isActive || s.disabled)) {
          return false;
        }
        if (_advancedStatus == 'منتهي الصلاحية' && !s.expired) return false;
        if (_advancedStatus == 'معطل' && !s.disabled) return false;
        if (_advancedStatus == 'ينتهي قريباً') {
          if (!s.endsWithinDays(7, now)) return false;
        }
        if (_advancedStatus == 'خلال 3 أيام') {
          if (!s.endsWithinDays(3, now)) return false;
        }
        if (_advancedStatus == 'ينتهي اشتراكهم اليوم') {
          final sameDay =
              s.endDate.year == now.year &&
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

      if (_advancedPackage != 'الكل' && s.packageDisplay != _advancedPackage) {
        return false;
      }
      if (_advancedParent != 'الكل' && _parentText(s) != _advancedParent) {
        return false;
      }
      if (_advancedMac.trim().isNotEmpty &&
          !_macText(
            s,
          ).toLowerCase().contains(_advancedMac.toLowerCase().trim())) {
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
          c = a.packageDisplay.toLowerCase().compareTo(
            b.packageDisplay.toLowerCase(),
          );
          break;
        case 'date':
          c = a.endDate.compareTo(b.endDate);
          break;
        case 'debt':
          c = a.remaining.compareTo(b.remaining);
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

  void _setStartDateAsActivationDay(Subscriber s, {DateTime? at}) {
    s.markActivationDate(at: at ?? DateTime.now());
  }

  String _parentText(Subscriber s) => _sasText(s, const [
    'parent_name',
    'parent',
    'manager_name',
    'reseller_name',
    'owner_name',
  ], '');

  String _macText(Subscriber s) => _sasText(s, const [
    'mac',
    'mac_address',
    'macAddress',
    'calling_station_id',
  ], '');

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
    if (_filter == 'active') return 'المشتركين الفعالين';
    if (_filter == 'expired') return 'المنتهي اشتراكهم';
    if (_filter == 'debts') return 'الديون';
    if (_filter == 'expiring3Days') return 'ينتهون خلال 3 أيام';
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
    String message;
    try {
      final accounts = await SasSettings.loadAll();
      if (accounts.isEmpty) {
        throw Exception('أكمل إعدادات ربط SAS أولاً');
      }
      // كل ساس يحدّث متصلي مشتركيه؛ فشل أحدها لا يُلغي نتيجة الباقي.
      int? online;
      Object? lastError;
      for (final settings in accounts) {
        try {
          final count = await SasSyncService.refreshConnections(
            SasApiService(settings),
          ).timeout(const Duration(seconds: 30));
          if (count != null) online = (online ?? 0) + count;
        } catch (e) {
          lastError = e;
        }
      }
      if (online == null && lastError != null) throw lastError;
      if (online != null) await AppStore.save();
      message = online == null
          ? 'لم يرجع SAS أي جلسة متصلة'
          : 'تم التحديث — المتصلون الآن $online';
    } catch (e) {
      message = 'تعذر تحديث المتصلين: $e';
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _syncAndRefresh() async {
    final before = AppStore.lastSasSync;
    await syncNow();
    if (AppStore.lastSasSync != before) await _refreshSubscribers();
  }

  Future<void> syncNow() async {
    if (syncing) return;
    setState(() => syncing = true);
    try {
      final result = await SasSyncService.syncAll();
      if (result.accounts == 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('أكمل إعدادات ربط SAS أولاً')),
          );
        }
        return;
      }
      if (result.allFailed) throw Exception(result.failures.values.first);
      AppStore.lastSasSync = DateTime.now();
      await AppStore.save();

      if (mounted) {
        setState(() => selected = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تمت المزامنة — ${result.summary}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذرت المزامنة: $e')));
      }
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  @override
  void dispose() {
    AppStore.subscribersChange.removeListener(_onSubscribersChanged);
    _verticalScrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  String normalizePhone(String phone) {
    var n = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (n.startsWith('0')) n = '964${n.substring(1)}';
    return n;
  }

  Future<ActivationPayment?> _confirmActivation(Subscriber subscriber) {
    subscriber.rolloverToMonth(DateTime.now());
    return showDialog<ActivationPayment>(
      context: context,
      builder: (_) => ActivationPaymentDialog(
        subscriber: subscriber,
        suggestedPrice: AppStore.suggestedActivationPrice(subscriber),
        recordedAmount: AppStore.recordedActivationAmount(subscriber),
      ),
    );
  }

  /// يسجل بيع الاشتراك والواصل بعد نجاح التفعيل في SAS.
  Future<({double collected, InvoiceRecord? invoice})> _recordActivationSale(
    Subscriber s, {
    required ActivationPayment payment,
    required double sasDeduction,
    required DateTime at,
    required String note,
  }) async {
    if (payment.alreadyRecorded) {
      final merged = AppStore.mergeRecordedSaleIntoActivation(s);
      await AppStore.addAccountingActivation(
        AccountingActivationRecord(
          subscriberUser: s.user,
          subscriberName: s.name,
          packageName: s.packageDisplay,
          saleAmount: merged,
          sasDeduction: sasDeduction,
          at: at,
          source: s.source,
        ),
        persist: false,
      );
      for (final event in DailyTaskEvent.activationSettlement(
        subscriberUser: s.user,
        subscriberName: s.name,
        at: at,
        collected: merged,
        remaining: s.remaining,
        note: note,
        addRemainingDebtEvent: false,
      )) {
        await AppStore.addDailyTaskEvent(event, persist: false);
      }
      return (collected: merged, invoice: null);
    }
    final debtAlreadyRecorded =
        s.currentMonthRemaining > 0.0001 && AppStore.hasRecordedCurrentDebt(s);
    s.chargeActivation(payment.saleAmount, at: at);
    final allocation = s.applyPayment(
      payment.collected,
      at: at,
      note: payment.settlement.label,
    );
    final collected = allocation.totalApplied;
    InvoiceRecord? invoice;
    if (collected > 0.0001) {
      final receiptNumber = await AppStore.issueReceiptNumber(persist: false);
      invoice = s.registerInvoiceFromPayment(
        receiptNumber: receiptNumber,
        amount: collected,
        at: at,
        note: 'فاتورة ${payment.settlement.label}',
      );
      s.paymentDate = fmt(at);
    }
    await AppStore.addAccountingActivation(
      AccountingActivationRecord(
        subscriberUser: s.user,
        subscriberName: s.name,
        packageName: s.packageDisplay,
        saleAmount: payment.saleAmount,
        sasDeduction: sasDeduction,
        at: at,
        source: s.source,
      ),
      persist: false,
    );
    for (final event in DailyTaskEvent.activationSettlement(
      subscriberUser: s.user,
      subscriberName: s.name,
      at: at,
      collected: collected,
      remaining: s.remaining,
      note: note,
      addRemainingDebtEvent: !debtAlreadyRecorded,
      chargedAmount: payment.saleAmount,
    )) {
      await AppStore.addDailyTaskEvent(event, persist: false);
    }
    return (collected: collected, invoice: invoice);
  }

  Future<void> _recordActivationLedger(
    Subscriber s, {
    required ActivationPayment payment,
    required ({double collected, InvoiceRecord? invoice}) sale,
    required DateTime at,
  }) async {
    // المبلغ والواصل المسجلان قبل التفعيل قُيّدا في السجل المالي وقتها.
    if (payment.alreadyRecorded) return;
    await _recordLedgerTransaction(
      subscriber: s,
      type: FinancialTransactionType.activation,
      amount: payment.saleAmount,
      date: at,
      referenceId:
          'activation:${s.subscriberId}:${at.toUtc().toIso8601String()}',
      note: s.packageDisplay,
    );
    final invoice = sale.invoice;
    if (invoice == null) return;
    await _recordLedgerTransaction(
      subscriber: s,
      type: FinancialTransactionType.payment,
      amount: sale.collected,
      date: at,
      referenceId: 'payment-receipt:${invoice.receiptNumber}',
      note: invoice.note,
    );
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

  Future<void> _recordLedgerTransaction({
    required Subscriber subscriber,
    required FinancialTransactionType type,
    required double amount,
    required DateTime date,
    required String referenceId,
    required String note,
  }) async {
    try {
      await SubscriberFinancialLedger().addTransaction(
        subscriberId: subscriber.subscriberId,
        date: date,
        type: type,
        amount: amount,
        referenceId: referenceId,
        note: note,
      );
    } catch (error) {
      debugPrint('Financial ledger write failed: $error');
    }
  }

  double _toNum(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(
          (value ?? '').toString().replaceAll(',', '').trim(),
        ) ??
        0;
  }

  double _activationReceivedAmount(dynamic response) {
    if (response is Map) {
      for (final key in const [
        '_sas_deduction_amount',
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
          '_sas_deduction_amount',
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
    final result = await WhatsAppNotificationDispatcher().sendSubscriberMessage(
      s,
      message: (message ?? defaultMessage).trim(),
      eventType: 'general_message',
      eventId: 'manual_${DateTime.now().microsecondsSinceEpoch}',
    );

    if (!mounted) return;
    if (result.success) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تم الإرسال بنجاح')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل إرسال واتساب: ${result.friendlyError}')),
      );
    }
  }

  Future<void> _sendActivationWhatsApp(
    Subscriber s, {
    double? paidAmount,
  }) async {
    final activationTemplate =
        AppStore.messageTemplates['activation'] ??
        'مرحباً {name}، تم تفعيل اشتراكك لدى {office}. الباقة: {package} وتنتهي بتاريخ {endDate}.';
    try {
      final result = await WhatsAppNotificationDispatcher()
          .notifySubscriptionActivated(
            s,
            template: activationTemplate,
            paidAmount: paidAmount,
            eventId:
                'activation_${s.subscriberId}_${s.startDate.millisecondsSinceEpoch}_${s.endDate.millisecondsSinceEpoch}_${(paidAmount ?? 0).round()}',
          );
      if (!result.success) {
        debugPrint(
          'Activation WhatsApp failed for ${s.name}: ${result.error ?? 'unknown'}',
        );
      }
    } catch (error) {
      debugPrint('Activation WhatsApp failed for ${s.name}: $error');
    }
  }

  /// المشترك يتصل بعد التفعيل بلحظات، فيظهر IP الخاص به دون مزامنة كاملة.
  void _refreshAfterActivation(SasApiService api, Subscriber s, int userId) {
    Future<void> refresh() async {
      for (final wait in const [20, 60]) {
        await Future<void>.delayed(Duration(seconds: wait));
        if (!AppStore.subscribers.any((item) => identical(item, s))) return;
        try {
          SasSyncService.applyUserSnapshot(s, await api.fetchUser(userId));
          await SasSyncService.refreshConnection(api, s);
          await AppStore.save();
        } catch (error) {
          debugPrint('Refresh after activation failed: $error');
        }
        if (s.ip.isNotEmpty && s.isOnline) return;
      }
    }

    RenderWhatsAppService.dispatchInBackground(refresh());
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تعذر فتح تطبيق الاتصال')));
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
        .replaceAll(
          '{{payment_date}}',
          s.paymentDate.isNotEmpty ? s.paymentDate : fmt(DateTime.now()),
        )
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
                  title: Text(
                    'رسائل واتساب',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
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
                        WhatsAppNotificationDispatcher().sendSubscriberMessage(
                          s,
                          message: template,
                          eventType: 'general_message',
                          eventId:
                              'saved_template_${DateTime.now().microsecondsSinceEpoch}',
                        ),
                      );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('تمت جدولة إرسال الرسالة عبر واتساب'),
                          ),
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

  /// طلب تجديد FTTH قد يخصم مالاً، فلا يُرسل طلب ثانٍ ما دام السابق لم يُحسم.
  Future<void> _activateFtthSubscriber(
    Subscriber s, {
    BuildContext? modalContext,
  }) async {
    if (modalContext != null && modalContext.mounted) {
      Navigator.pop(modalContext);
    }
    if (operationBusy) return;
    operationBusy = true;
    SasProjectNationalService? service;
    try {
      final settings = await SasProjectNationalSettings.load();
      if (settings.username.trim().isEmpty || settings.password.isEmpty) {
        throw Exception('أكمل إعدادات ساس المشروع الوطني أولاً');
      }
      service = SasProjectNationalService(settings);
      final pending = FtthPendingActivation.fromJson(
        s.sasData[SasProjectNationalService.pendingActivationKey],
      );
      if (pending != null) {
        await _resolveFtthPending(s, service, pending);
      } else {
        await _startFtthActivation(s, service);
      }
    } catch (e) {
      _showFtthMessage('❌ فشل تفعيل FTTH: $e', color: Colors.red.shade600);
    } finally {
      service?.dispose();
      operationBusy = false;
    }
  }

  ({String subscriptionId, String customerId}) _ftthIds(Subscriber s) {
    final subscriptionId = s.sasId.trim().isNotEmpty
        ? s.sasId.trim()
        : (s.sasData['subscription_id'] ?? '').toString().trim();
    final customerId = (s.sasData['customer_id'] ?? '').toString().trim();
    return (subscriptionId: subscriptionId, customerId: customerId);
  }

  Future<void> _startFtthActivation(
    Subscriber s,
    SasProjectNationalService service,
  ) async {
    final ids = _ftthIds(s);
    if (ids.subscriptionId.isEmpty) {
      throw Exception('معرّف اشتراك FTTH غير موجود في بيانات المشترك');
    }
    final choice = await showDialog<FtthActivationChoice>(
      context: context,
      builder: (_) => FtthActivationDialog(
        subscriberName: s.name,
        renewal: !s.expired,
        loadQuote: () => service.fetchActivationQuote(
          subscriptionId: ids.subscriptionId,
          customerId: ids.customerId,
        ),
        priceFor: (quote, order) =>
            service.calculatePrice(quote.detail, order: order),
        topUp: (quote, pin) => service.topUpCustomerWallet(
          customerId: quote.detail.customerId,
          cardPin: pin,
        ),
      ),
    );
    if (choice == null || !mounted) return;

    // الدفع بالمحفظة يخصم فوراً، فيُسأل عن الواصل قبل الإرسال كما في SAS.
    ActivationPayment? payment;
    if (!choice.method.waitsForPayment) {
      payment = await _confirmActivation(s);
      if (payment == null || !mounted) return;
    }

    final detail = choice.quote.detail;
    final sentAt = DateTime.now();
    FtthPendingActivation pendingWith({String url = '', String order = ''}) =>
        FtthPendingActivation(
          method: choice.method,
          price: choice.quote.price,
          previousExpiresAt: detail.expiresAt,
          createdAt: sentAt,
          paymentUrl: url,
          orderNumber: order,
        );

    final FtthActivationResult result;
    try {
      result = await _withFtthLoading(
        () => service.activateSubscription(
          detail: detail,
          price: choice.quote.price,
          method: choice.method,
          order: choice.quote.order,
        ),
      );
    } catch (e) {
      // رفض صريح من الخادم يعني أن شيئاً لم يُنفَّذ. أما الانقطاع أو المهلة
      // أو رد ناقص فقد يكون الطلب نُفّذ، فيبقى معلقاً للتحقق.
      if (e is SasProjectNationalException && (e.statusCode ?? 0) >= 400) {
        rethrow;
      }
      await _saveFtthPending(s, pendingWith());
      _showFtthMessage(
        '⚠️ لم تُعرف نتيجة طلب التفعيل. لا تعد الإرسال؛ اضغط تفعيل لاحقاً للتحقق',
        color: Colors.orange.shade800,
      );
      return;
    }

    final pending = pendingWith(
      url: result.paymentUrl,
      order: result.orderNumber,
    );
    await _saveFtthPending(s, pending);
    await _recordSubscriberActivity(
      s,
      DailyTaskEvent.activationRequestedType,
      '${detail.expired ? 'طلب تفعيل' : 'طلب تجديد'} FTTH — ${choice.method.label}',
    );

    if (choice.method.waitsForPayment) {
      if (await _payFtthInApp(s, service, pending)) return;
      if (mounted) await _resolveFtthPending(s, service, pending);
      return;
    }

    // التفعيل بالمحفظة فوري، لكن لا نعتمده قبل أن يظهر التاريخ الجديد في FTTH.
    final renewed = await _withFtthLoading(
      () => _waitForFtthRenewal(service, s, pending),
    );
    if (renewed != null) {
      await _finishFtthActivation(s, pending, renewed, payment: payment);
    } else {
      _showFtthMessage(
        '⚠️ أُرسل الطلب ولم يظهر التجديد في FTTH بعد. لا تعد الإرسال؛ اضغط تفعيل بعد قليل للتحقق',
        color: Colors.orange.shade800,
      );
    }
  }

  Future<FtthSubscriptionDetail?> _waitForFtthRenewal(
    SasProjectNationalService service,
    Subscriber s,
    FtthPendingActivation pending, {
    int attempts = 3,
  }) async {
    final ids = _ftthIds(s);
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 3));
      try {
        final detail = await service.fetchSubscription(
          subscriptionId: ids.subscriptionId,
          customerId: ids.customerId,
        );
        if (pending.confirmedBy(detail)) return detail;
      } catch (error) {
        debugPrint('FTTH renewal check failed: $error');
      }
    }
    return null;
  }

  Future<void> _resolveFtthPending(
    Subscriber s,
    SasProjectNationalService service,
    FtthPendingActivation pending,
  ) async {
    while (true) {
      if (!mounted) return;
      final action = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('طلب تفعيل FTTH بانتظار التأكيد'),
            content: Text(
              '${s.name}\n'
              'الطريقة: ${pending.method.label}\n'
              'المبلغ: ${formatIqd(pending.price)}\n'
              'أُرسل: ${fmt(pending.createdAt)}\n\n'
              '${pending.method.waitsForPayment ? 'لم يكتمل الدفع بعد. اضغط "صفحة الدفع" لإكماله، أو "تحقق" إن كنت دفعت.' : 'تحقق من ظهور التجديد في FTTH.'}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, 'close'),
                child: const Text('لاحقاً'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, 'discard'),
                child: Text(
                  pending.orderNumber.isNotEmpty
                      ? 'إلغاء الطلب'
                      : 'تجاهل الطلب',
                ),
              ),
              if (pending.paymentUrl.isNotEmpty)
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, 'open'),
                  child: const Text('صفحة الدفع'),
                ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, 'verify'),
                child: const Text('تحقق'),
              ),
            ],
          ),
        ),
      );
      if (!mounted || action == null || action == 'close') return;
      if (action == 'open') {
        if (await _payFtthInApp(s, service, pending)) return;
        continue;
      }

      // قبل الإلغاء أيضاً نتحقق، حتى لا يُلغى طلب دُفع فعلاً.
      final renewed = await _withFtthLoading(
        () => _waitForFtthRenewal(service, s, pending, attempts: 1),
      );
      if (renewed != null) {
        await _finishFtthActivation(s, pending, renewed);
        return;
      }
      if (action == 'verify') {
        _showFtthMessage(
          'لم يظهر التجديد في FTTH بعد',
          color: Colors.orange.shade800,
        );
        continue;
      }

      if (!await _confirmFtthDiscard(pending)) continue;
      if (pending.orderNumber.isNotEmpty) {
        await _withFtthLoading(() => service.cancelOrder(pending.orderNumber));
      }
      s.sasData.remove(SasProjectNationalService.pendingActivationKey);
      await AppStore.save();
      _showFtthMessage('تم إلغاء طلب التفعيل');
      return;
    }
  }

  Future<bool> _confirmFtthDiscard(FtthPendingActivation pending) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: Text(
                pending.orderNumber.isNotEmpty ? 'إلغاء الطلب' : 'تجاهل الطلب',
              ),
              content: Text(
                pending.orderNumber.isNotEmpty
                    ? 'سيُلغى طلب الدفع في FTTH. لا تلغه إن كان المشترك قد دفع.'
                    : 'تأكد من موقع FTTH أن الاشتراك لم يُجدَّد ولم يُخصم المبلغ قبل التجاهل.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('رجوع'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('تأكيد'),
                ),
              ],
            ),
          ),
        ) ??
        false;
  }

  /// يسجل البيع بعد تأكد التجديد. إن أُغلقت نافذة الواصل يبقى الطلب معلقاً
  /// حتى يُسجَّل لاحقاً، فلا يضيع المبلغ ولا يُعاد التفعيل.
  Future<void> _finishFtthActivation(
    Subscriber s,
    FtthPendingActivation pending,
    FtthSubscriptionDetail renewed, {
    ActivationPayment? payment,
  }) async {
    payment ??= await _confirmActivation(s);
    if (payment == null) {
      _showFtthMessage(
        '✅ تم التجديد في FTTH. اضغط تفعيل مرة أخرى لتسجيل المبلغ',
        color: Colors.orange.shade800,
      );
      return;
    }
    final at = DateTime.now();
    s.active = true;
    s.disabled = false;
    if (renewed.expiresAt != null) s.endDate = renewed.expiresAt!;
    _setStartDateAsActivationDay(s, at: at);
    s.sasData.remove(SasProjectNationalService.pendingActivationKey);
    final sale = await _recordActivationSale(
      s,
      payment: payment,
      // رصيد المشترك لا يُخصم من الوكيل.
      sasDeduction: pending.method == FtthPaymentMethod.customerWallet
          ? 0
          : pending.price,
      at: at,
      note: 'تفعيل FTTH — ${pending.method.label}',
    );
    await AppStore.save();
    await _recordActivationLedger(s, payment: payment, sale: sale, at: at);
    if (!mounted) return;
    setState(() {
      selected = null;
      _filteredSubscribers = _buildFilteredSubscribers();
    });
    _showFtthMessage(
      '✅ تم تفعيل FTTH حتى ${fmt(s.endDate)}',
      color: Colors.green.shade600,
    );
  }

  Future<void> _saveFtthPending(
    Subscriber s,
    FtthPendingActivation pending,
  ) async {
    s.sasData[SasProjectNationalService.pendingActivationKey] = pending
        .toJson();
    await AppStore.save();
  }

  /// يفتح الدفع داخل التطبيق، وإن انتهت صفحة البوابة يتحقق من التجديد مباشرة.
  /// يرجع true إن تأكد التجديد وسُجّل.
  Future<bool> _payFtthInApp(
    Subscriber s,
    SasProjectNationalService service,
    FtthPendingActivation pending,
  ) async {
    final uri = Uri.tryParse(pending.paymentUrl);
    if (uri == null || !mounted) return false;
    final finished = await FtthPaymentScreen.open(
      context,
      paymentUrl: uri,
      statusPageUrl: service.paymentStatusPageUrl,
    );
    if (!finished || !mounted) return false;
    final renewed = await _withFtthLoading(
      () => _waitForFtthRenewal(service, s, pending),
    );
    if (renewed == null) return false;
    await _finishFtthActivation(s, pending, renewed);
    return true;
  }

  Future<T> _withFtthLoading<T>(Future<T> Function() task) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      return await task();
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  void _showFtthMessage(String text, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: color,
        duration: const Duration(seconds: 6),
      ),
    );
  }

  /// ضغطتان متتاليتان تعنيان خصمين من رصيد SAS.
  Future<void> _activateSubscriber(
    Subscriber s, {
    BuildContext? modalContext,
  }) async {
    // مشترك FTTH يُفعَّل من FTTH، فمعرّفه لا يخص SAS وقد يطابق مشتركاً آخر فيه.
    if (s.source == 'ftth') {
      return _activateFtthSubscriber(s, modalContext: modalContext);
    }
    if (_blockFormer(s)) return;
    if (operationBusy) return;
    operationBusy = true;
    try {
      await _runActivation(s, modalContext: modalContext);
    } finally {
      operationBusy = false;
    }
  }

  Future<void> _runActivation(
    Subscriber s, {
    BuildContext? modalContext,
  }) async {
    bool loadingDialogShown = false;
    bool sasActivated = false;
    // استخراج معرف SAS بشكل آمن
    final sasId = s.sasId.trim();
    final dataId = (s.sasData['id'] ?? s.sasData['user_id'] ?? '')
        .toString()
        .trim();
    final rawId = sasId.isNotEmpty ? sasId : dataId;

    debugPrint('Activation Debug: sasId=$sasId, dataId=$dataId, rawId=$rawId');

    final userId = int.tryParse(rawId);

    if (userId == null || userId == 0) {
      if (modalContext != null && modalContext.mounted) {
        Navigator.pop(modalContext);
      }
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

    final activationPayment = await _confirmActivation(s);
    if (activationPayment == null) return;
    try {
      final settings = await SasSettings.forSubscriber(s);
      if (settings.username.trim().isEmpty || settings.password.isEmpty) {
        throw Exception('أكمل إعدادات ربط SAS أولاً');
      }

      debugPrint(
        'Attempting to activate userId=$userId for subscriber ${s.name}',
      );

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
          builder: (_) => const Center(child: CircularProgressIndicator()),
        );
      }

      // تفعيل المشترك في SAS
      final activationTemplate =
          AppStore.messageTemplates['activation'] ??
          'مرحباً {name}، تم تفعيل اشتراكك لدى {office}. الباقة: {package} وتنتهي بتاريخ {endDate}.';
      final activationMessage = _renderTemplate(activationTemplate, s);

      final activationResponse = await api
          .activateUser(
            userId,
            notifyPhone: s.phone,
            notifyMessage: activationMessage,
          )
          .timeout(
            const Duration(seconds: 60),
            onTimeout: () => throw Exception('انتهت مهلة طلب التفعيل'),
          );
      sasActivated = true;

      // جلب بيانات المشترك المحدثة من SAS
      dynamic userData;
      try {
        userData = await api
            .fetchUser(userId)
            .timeout(const Duration(seconds: 15));
      } catch (e) {
        debugPrint('Could not fetch user data: $e');
      }

      // تحديث بيانات المشترك محلياً
      s.active = true;
      s.disabled = false;
      s.points++;

      final activationAmount = _activationReceivedAmount(activationResponse);
      final activatedAt =
          SasSyncService.activationDateFromSas(userData) ??
          SasSyncService.activationDateFromSas(activationResponse) ??
          DateTime.now();
      final recordedAt = DateTime.now();
      _setStartDateAsActivationDay(s, at: activatedAt);
      SasSyncService.applyUserSnapshot(s, userData);

      final sale = await _recordActivationSale(
        s,
        payment: activationPayment,
        sasDeduction: activationAmount,
        at: recordedAt,
        note: 'تفعيل من قائمة المشتركين',
      );

      // حفظ البيانات المحلية أولاً
      await AppStore.save();
      await _recordActivationLedger(
        s,
        payment: activationPayment,
        sale: sale,
        at: recordedAt,
      );

      if (mounted) {
        if (loadingDialogShown && Navigator.of(context).canPop()) {
          Navigator.of(context).pop(); // إغلاق شاشة التحميل فقط
          loadingDialogShown = false;
        }

        RenderWhatsAppService.dispatchInBackground(
          _sendActivationWhatsApp(s, paidAmount: sale.collected),
        );
        _refreshAfterActivation(api, s, userId);

        setState(() {
          selected = null;
          _filteredSubscribers = _buildFilteredSubscribers();
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('✅ تم التفعيل وتحديث بيانات المشترك'),
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

        if (sasActivated) {
          msg =
              '⚠️ تم التفعيل في SAS لكن تعذر إكمال تسجيله. لا تعد التفعيل، وراجع مبالغ المشترك';
        } else if (errorStr.contains('نقاط المكافآت غير كافية')) {
          msg = '❌ نقاط المكافآت غير كافية - اطلب من المشترك تجميع نقاط إضافية';
        } else if (errorStr.contains('لا يوجد رصيد متاح')) {
          msg =
              '❌ لا يوجد رصيد - رصيد المشترك والمدير معاً صفر. أضف رصيد للمشترك أو المدير';
        } else if (errorStr.contains('الرصيد صفر') ||
            errorStr.contains('zero balance')) {
          msg =
              '❌ رصيد المشترك صفر - سيتم الاعتماد على رصيد المدير. تأكد من وجود رصيد لدى المدير';
        } else if (errorStr.contains('الرصيد غير كافٍ')) {
          msg = '❌ الرصيد غير كافٍ للتفعيل (المشترك والمدير)';
        } else if (errorStr.contains('تم الوصول إلى الحد الأقصى')) {
          msg =
              '⚠️ تم الوصول إلى الحد الأقصى - الحساب أو المدير وصل للحد. حاول لاحقاً';
        } else if (errorStr.contains('Failed host lookup') ||
            errorStr.contains('SocketException')) {
          msg =
              '❌ فشل الاتصال بخادم SAS - تحقق من الإنترنت أو تواصل مع دعم SAS';
        } else if (errorStr.contains('تعذر الاتصال')) {
          msg = '❌ الاتصال بخادم SAS منقطع - تحقق من الإنترنت أو اسم الخادم';
        } else if (errorStr.contains('403')) {
          msg =
              '❌ خطأ 403: تحقق من صلاحيات المستخدم أو معرف SAS (userId=$userId)';
        } else if (errorStr.contains('401')) {
          msg = '❌ خطأ 401: فشل التحقق من البيانات. تحقق من بيانات الربط';
        } else if (errorStr.contains('404')) {
          msg = '❌ خطأ 404: المشترك غير موجود في SAS (userId=$userId)';
        } else if (errorStr.contains('مهلة')) {
          msg =
              '⚠️ انتهت المهلة وقد يكون التفعيل تم. اعمل مزامنة وتأكد من تاريخ الانتهاء قبل الإعادة';
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
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
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
    // هذه العمليات تخاطب SAS فقط، ومعرف FTTH قد يطابق مشتركاً آخر فيه.
    final isSas = s.source != 'ftth' && !s.isFormer;
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
                            Text(
                              s.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 17,
                              ),
                            ),
                            Text(
                              s.user,
                              style: TextStyle(color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                _op(
                  Icons.badge_outlined,
                  Colors.indigo,
                  'تعديل بيانات المشترك',
                  () async {
                    Navigator.pop(ctx);
                    final changed = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AddSubscriberScreen(subscriber: s),
                      ),
                    );
                    if (changed == true && mounted) setState(() {});
                  },
                ),
                if (s.inSeveralSas)
                  _op(Icons.alt_route, Colors.indigo, 'الساس المرجع', () {
                    Navigator.pop(ctx);
                    _pickReferenceSas(s);
                  }),
                _op(Icons.person_add, Colors.teal, 'إضافة مشترك جديد', () {
                  Navigator.pop(ctx);
                  add();
                }),
                _op(
                  Icons.check_circle,
                  Colors.green,
                  s.source == 'ftth' && !s.expired ? 'تجديد' : 'تفعيل',
                  () async {
                    if (s.source == 'ftth') {
                      _activateFtthSubscriber(s, modalContext: ctx);
                    } else {
                      _activateSubscriber(s, modalContext: ctx);
                    }
                  },
                ),
                if (isSas)
                  _op(Icons.calendar_month, Colors.orange, 'تمديد', () {
                    Navigator.pop(ctx);
                    _extend(s);
                  }),
                if (isSas)
                  _op(Icons.swap_horiz, Colors.purple, 'تغيير الباقة', () {
                    Navigator.pop(ctx);
                    _changePackage(s);
                  }),
                if (isSas)
                  _op(Icons.block, Colors.red, 'تعطيل', () async {
                    // لا نغيّر الحالة محلياً إلا بعد نجاح التعطيل الحقيقي في SAS.
                    final rawId = s.sasId.trim().isNotEmpty
                        ? s.sasId.trim()
                        : (s.sasData['id'] ?? s.sasData['user_id'] ?? '')
                              .toString()
                              .trim();
                    final userId = int.tryParse(rawId);

                    if (userId == null || userId == 0) {
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'تعذر التعطيل: معرف SAS غير صحيح (rawId=$rawId)',
                            ),
                          ),
                        );
                      }
                      return;
                    }

                    try {
                      final settings = await SasSettings.forSubscriber(s);
                      if (settings.username.trim().isEmpty ||
                          settings.password.isEmpty) {
                        throw Exception('أكمل إعدادات ربط SAS أولاً');
                      }

                      final api = SasApiService(settings);
                      await api
                          .disableUser(userId)
                          .timeout(
                            const Duration(seconds: 30),
                            onTimeout: () =>
                                throw Exception('انتهت مهلة طلب التعطيل'),
                          );

                      s.disabled = true;
                      s.active = false;
                      await AppStore.save();
                      await _recordSubscriberActivity(
                        s,
                        DailyTaskEvent.subscriberDisabledType,
                        'تم تعطيل المشترك في SAS',
                      );

                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        setState(() {});
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('✅ تم تعطيل المشترك في SAS بنجاح'),
                          ),
                        );
                      }
                    } catch (e) {
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        final errorStr = e.toString();
                        String msg;

                        if (errorStr.contains('403')) {
                          msg =
                              '❌ خطأ 403: تحقق من صلاحيات المستخدم أو معرف SAS (userId=$userId)';
                        } else if (errorStr.contains('401')) {
                          msg =
                              '❌ خطأ 401: فشل التحقق من البيانات. تحقق من بيانات الربط';
                        } else if (errorStr.contains('404')) {
                          msg =
                              '❌ خطأ 404: المشترك غير موجود في SAS (userId=$userId)';
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
                if (isSas)
                  _op(Icons.lock_open, Colors.green, 'إلغاء التعطيل', () async {
                    // لا نغيّر الحالة محلياً إلا بعد نجاح إلغاء التعطيل الحقيقي في SAS.
                    final rawId = s.sasId.trim().isNotEmpty
                        ? s.sasId.trim()
                        : (s.sasData['id'] ?? s.sasData['user_id'] ?? '')
                              .toString()
                              .trim();
                    final userId = int.tryParse(rawId);

                    if (userId == null || userId == 0) {
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'تعذر إلغاء التعطيل: معرف SAS غير صحيح (rawId=$rawId)',
                            ),
                          ),
                        );
                      }
                      return;
                    }

                    try {
                      final settings = await SasSettings.forSubscriber(s);
                      if (settings.username.trim().isEmpty ||
                          settings.password.isEmpty) {
                        throw Exception('أكمل إعدادات ربط SAS أولاً');
                      }

                      final api = SasApiService(settings);
                      await api
                          .enableUser(userId)
                          .timeout(
                            const Duration(seconds: 30),
                            onTimeout: () =>
                                throw Exception('انتهت مهلة طلب إلغاء التعطيل'),
                          );

                      s.disabled = false;
                      s.active = true;
                      await AppStore.save();
                      await _recordSubscriberActivity(
                        s,
                        DailyTaskEvent.subscriberEnabledType,
                        'تم إلغاء تعطيل المشترك في SAS',
                      );

                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        setState(() {});
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              '✅ تم إلغاء تعطيل المشترك في SAS بنجاح',
                            ),
                          ),
                        );
                      }
                    } catch (e) {
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        final errorStr = e.toString();
                        String msg;

                        if (errorStr.contains('403')) {
                          msg =
                              '❌ خطأ 403: تحقق من صلاحيات المستخدم أو معرف SAS (userId=$userId)';
                        } else if (errorStr.contains('401')) {
                          msg =
                              '❌ خطأ 401: فشل التحقق من البيانات. تحقق من بيانات الربط';
                        } else if (errorStr.contains('404')) {
                          msg =
                              '❌ خطأ 404: المشترك غير موجود في SAS (userId=$userId)';
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
                _op(
                  Icons.account_balance_wallet,
                  Colors.brown,
                  'الديون',
                  () async {
                    Navigator.pop(ctx);
                    await _debt(s);
                  },
                ),
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
                    MaterialPageRoute(
                      builder: (_) => ReceiptScreen(subscriber: s),
                    ),
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

  Widget _op(IconData i, Color c, String t, VoidCallback f) => ListTile(
    leading: Icon(i, color: c),
    title: Text(t),
    onTap: f,
  );

  Future<void> _recordSubscriberActivity(
    Subscriber subscriber,
    String type,
    String note,
  ) async {
    try {
      await AppStore.addDailyTaskEvent(
        DailyTaskEvent(
          type: type,
          subscriberUser: subscriber.user,
          subscriberName: subscriber.name,
          at: DateTime.now(),
          remainingAfter: subscriber.remaining,
          note: note,
        ),
      );
    } catch (error) {
      debugPrint('Could not save subscriber activity: $error');
    }
  }

  String _newGuid() {
    final r = Random.secure();
    String hex(int n) =>
        List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
    // نفس نمط ch.guid() في SAS: 8-4-4-4-12 بدون فرض UUID v4.
    return '${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}';
  }

  InputDecoration _greenDropdownDecoration(String label, IconData icon) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(
        color: isDark ? const Color(0xFFE2E8F0) : colors.onSurfaceVariant,
      ),
      floatingLabelStyle: TextStyle(color: colors.primary),
      prefixIcon: Icon(
        icon,
        color: isDark ? const Color(0xFF86EFAC) : const Color(0xFF2E7D32),
      ),
      filled: true,
      fillColor: isDark
          ? const Color(0xFF1E293B)
          : colors.surfaceContainerHighest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: isDark ? const Color(0xFF475569) : Colors.green.shade200,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: isDark ? const Color(0xFF475569) : Colors.green.shade200,
          width: 1.2,
        ),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
        borderSide: BorderSide(color: Color(0xFF2E7D32), width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }

  /// يختار الوكيل الساس المرجع لمشترك موجود في أكثر من ساس؛ منه تُقرأ
  /// بياناته وإليه تُرسل عملياته من تفعيل وتجديد وغيرها.
  Future<void> _pickReferenceSas(Subscriber s) async {
    final presence = s.sasPresence.toList()
      ..sort((a, b) => a.isEmpty ? -1 : (b.isEmpty ? 1 : a.compareTo(b)));
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  '${s.name} موجود في ${presence.length} ساس. اختر الساس '
                  'الذي تُرسل إليه عمليات التفعيل والتجديد وغيرها.',
                ),
              ),
              for (final account in presence)
                ListTile(
                  leading: Icon(
                    account == s.sasAccount
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: Colors.indigo,
                  ),
                  title: Text(SasSettings.labelFor(account)),
                  subtitle: Text('المعرف: ${s.idIn(account) ?? '-'}'),
                  onTap: () => Navigator.pop(ctx, account),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || picked == s.sasAccount || !mounted) return;
    setState(() => s.useSas(picked));
    await AppStore.save();
    // بيانات المشترك تُقرأ الآن من الساس المرجع الجديد.
    try {
      final userId = int.tryParse(s.sasId.trim());
      if (userId != null) {
        final api = SasApiService(await SasSettings.forSubscriber(s));
        SasSyncService.applyUserSnapshot(s, await api.fetchUser(userId));
        await AppStore.save();
      }
    } catch (e) {
      debugPrint('Refresh after picking SAS failed: $e');
    }
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('صار ${SasSettings.labelFor(picked)} مرجع ${s.name}'),
      ),
    );
  }

  /// المشترك السابق حُذف ساسه: يبقى لديونه فقط ولا يُرسل عنه شيء للساس.
  bool _blockFormer(Subscriber s) {
    if (!s.isFormer) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'مشترك سابق من ساس محذوف: يبقى لتسديد دينه فقط. '
          'يعود تلقائياً إذا ظهر في مزامنة الساس.',
        ),
      ),
    );
    return true;
  }

  void _extend(Subscriber s) {
    if (_blockFormer(s)) return;
    int? selectedProfileId;
    String selectedMethod = 'reward_points';
    List<Map<String, dynamic>> profiles = [];
    bool loading = true;
    String? loadError;
    bool requested = false;
    bool submitting = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          Future<void> loadProfiles() async {
            try {
              final settings = await SasSettings.forSubscriber(s);
              final api = SasApiService(settings);
              final rows = await api.fetchExtendProfiles(
                int.parse(s.sasId.toString()),
              );
              if (!ctx.mounted) return;
              setLocal(() {
                profiles = rows;
                loading = false;
                loadError = null;
              });
            } catch (e) {
              if (!ctx.mounted) return;
              setLocal(() {
                loading = false;
                loadError = e.toString();
              });
            }
          }

          if (!requested) {
            requested = true;
            Future.microtask(loadProfiles);
          }

          int? idOf(Map<String, dynamic> p) =>
              int.tryParse((p['id'] ?? p['profile_id'] ?? '').toString());
          String nameOf(Map<String, dynamic> p) =>
              (p['name'] ?? p['profile_name'] ?? 'ID ${idOf(p) ?? '-'}')
                  .toString();

          return Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text('تمديد الاشتراك'),
              content: loading
                  ? const SizedBox(
                      height: 80,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : loadError != null
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('تعذر جلب الباقات: $loadError'),
                        TextButton.icon(
                          onPressed: () {
                            setLocal(() {
                              loading = true;
                              loadError = null;
                            });
                            loadProfiles();
                          },
                          icon: const Icon(Icons.refresh),
                          label: const Text('إعادة المحاولة'),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DropdownButtonFormField<int>(
                          initialValue: selectedProfileId,
                          decoration: _greenDropdownDecoration(
                            'اختر الباقة',
                            Icons.inventory_2_outlined,
                          ),
                          dropdownColor: Theme.of(
                            context,
                          ).colorScheme.surfaceContainer,
                          iconEnabledColor: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                          items: profiles
                              .where((p) => idOf(p) != null)
                              .map(
                                (p) => DropdownMenuItem<int>(
                                  value: idOf(p),
                                  child: Text(nameOf(p)),
                                ),
                              )
                              .toList(),
                          onChanged: (v) =>
                              setLocal(() => selectedProfileId = v),
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          initialValue: selectedMethod,
                          decoration: _greenDropdownDecoration(
                            'نوع التمديد',
                            Icons.autorenew,
                          ),
                          dropdownColor: Theme.of(
                            context,
                          ).colorScheme.surfaceContainer,
                          iconEnabledColor: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
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
                TextButton(
                  onPressed: submitting ? null : () => Navigator.pop(ctx),
                  child: const Text('إلغاء'),
                ),
                FilledButton(
                  onPressed: loading || submitting || selectedProfileId == null
                      ? null
                      : () async {
                          setLocal(() => submitting = true);
                          final rawUserId = s.sasId.trim().isNotEmpty
                              ? s.sasId.trim()
                              : (s.sasData['id'] ?? s.sasData['user_id'] ?? '')
                                    .toString()
                                    .trim();
                          final userId = int.tryParse(rawUserId);
                          if (userId == null) {
                            if (ctx.mounted) {
                              Navigator.pop(ctx);
                            }
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('لا يوجد SAS ID صحيح للمشترك'),
                                ),
                              );
                            }
                            return;
                          }
                          try {
                            final settings = await SasSettings.forSubscriber(s);
                            final api = SasApiService(settings);
                            final transactionId = _newGuid();

                            await api
                                .extendUser(
                                  userId: userId,
                                  profileId: selectedProfileId!,
                                  method: selectedMethod,
                                  transactionId: transactionId,
                                )
                                .timeout(
                                  const Duration(seconds: 30),
                                  onTimeout: () =>
                                      throw Exception('انتهت مهلة طلب التمديد'),
                                );
                            await _recordSubscriberActivity(
                              s,
                              DailyTaskEvent.subscriberExtendedType,
                              'تم تمديد الاشتراك إلى ${nameOf(profiles.firstWhere((profile) => idOf(profile) == selectedProfileId, orElse: () => <String, dynamic>{}))} باستخدام ${selectedMethod == 'credit' ? 'رصيد المدير' : 'النقاط التشجيعية'}',
                            );
                            if (ctx.mounted) Navigator.pop(ctx);

                            // v091: لا ننتظر مزامنة جميع المشتركين بعد التمديد.
                            // نجلب المشترك نفسه فقط، ثم نحدّث الواجهة فوراً.
                            try {
                              SasSyncService.applyUserSnapshot(
                                s,
                                await api.fetchUser(userId),
                              );
                              await AppStore.save();
                            } catch (_) {
                              // نجاح التمديد لا يُلغى إذا تعذر تحديث التفاصيل اللحظي.
                            }
                            if (mounted) setState(() {});

                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'تم تمديد المشترك في SAS بنجاح',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              );
                            }
                          } catch (e) {
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (mounted) {
                              final msg =
                                  e.toString().contains('الرصيد غير كافٍ')
                                  ? 'الرصيد غير كافٍ'
                                  : 'فشل التمديد في SAS: $e';
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    msg,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                    ),
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

  Future<void> _changePackage(Subscriber s) async {
    if (_blockFormer(s)) return;
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
      final settings = await SasSettings.forSubscriber(s);
      final api = SasApiService(settings);
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );

      final profiles = await api.fetchProfiles().timeout(
        const Duration(seconds: 30),
      );
      if (mounted) Navigator.pop(context);
      if (!mounted) return;

      int? idOf(Map<String, dynamic> p) =>
          int.tryParse((p['id'] ?? p['profile_id'] ?? '').toString());
      String nameOf(Map<String, dynamic> p) =>
          (p['name'] ?? p['profile_name'] ?? 'بدون اسم').toString();
      final usable = profiles.where((p) => idOf(p) != null).toList();

      final selected = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: Text('تغيير باقة ${s.name}'),
            content: SizedBox(
              width: 420,
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: usable.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final p = usable[i];
                  return ListTile(
                    leading: const Icon(Icons.speed_outlined),
                    title: Text(nameOf(p)),
                    subtitle: Text('ID: ${idOf(p)}'),
                    onTap: () => Navigator.pop(ctx, p),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء'),
              ),
            ],
          ),
        ),
      );
      if (selected == null || !mounted) return;

      final profileId = idOf(selected)!;
      final profileName = nameOf(selected);
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('تأكيد تغيير الباقة'),
            content: Text('تغيير باقة ${s.name} إلى $profileName الآن؟'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('تغيير'),
              ),
            ],
          ),
        ),
      );
      if (ok != true || !mounted) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );

      await api
          .changeUserProfile(
            userId: userId,
            profileId: profileId,
            changeType: 'immediate',
          )
          .timeout(const Duration(seconds: 30));

      try {
        final overview = await api.fetchUserOverview(userId);
        if (overview is Map) {
          s.sasData.addAll(Map<String, dynamic>.from(overview));
        }
      } catch (_) {}

      final previousPackage = s.packageDisplay;
      s.setPackageValue(profileName);
      await AppStore.save();
      if (previousPackage != s.packageDisplay) {
        await _recordSubscriberActivity(
          s,
          DailyTaskEvent.subscriberPackageChangedType,
          'تم تغيير الباقة من $previousPackage إلى ${s.packageDisplay}',
        );
      }
      if (mounted) Navigator.pop(context);
      if (!mounted) return;
      setState(() {});

      final isExpired = s.endDate.isBefore(DateTime.now()) || s.expired;
      if (isExpired) {
        final activate = await showDialog<bool>(
          context: context,
          builder: (ctx) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text('تم تغيير الباقة بنجاح'),
              content: const Text(
                'المشترك منتهي الاشتراك. تغيير الباقة لا يفعّله تلقائياً.\nهل تريد تفعيله الآن؟',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('لاحقاً'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('تفعيل الآن'),
                ),
              ],
            ),
          ),
        );
        final activationPayment = activate == true && mounted
            ? await _confirmActivation(s)
            : null;
        if (activationPayment != null && mounted) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (_) => const Center(child: CircularProgressIndicator()),
          );

          final activationResponse = await api
              .activateUser(userId)
              .timeout(const Duration(seconds: 30));
          s.active = true;
          s.disabled = false;
          final activatedAt =
              SasSyncService.activationDateFromSas(activationResponse) ??
              DateTime.now();
          final recordedAt = DateTime.now();
          _setStartDateAsActivationDay(s, at: activatedAt);

          // جلب بيانات المشترك المحدثة من SAS
          dynamic userData;
          try {
            userData = await api
                .fetchUser(userId)
                .timeout(const Duration(seconds: 15));
          } catch (e) {
            debugPrint('Could not fetch user data: $e');
          }

          SasSyncService.applyUserSnapshot(s, userData);

          final activationAmount = _activationReceivedAmount(
            activationResponse,
          );
          final sale = await _recordActivationSale(
            s,
            payment: activationPayment,
            sasDeduction: activationAmount,
            at: recordedAt,
            note: 'تفعيل بعد تغيير الباقة',
          );
          await AppStore.save();
          await _recordActivationLedger(
            s,
            payment: activationPayment,
            sale: sale,
            at: recordedAt,
          );
          if (mounted) Navigator.pop(context);
          RenderWhatsAppService.dispatchInBackground(
            _sendActivationWhatsApp(s, paidAmount: sale.collected),
          );
          _refreshAfterActivation(api, s, userId);
          if (!mounted) return;
          if (mounted) {
            setState(() {});
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('تم تغيير الباقة وتفعيل المشترك في SAS بنجاح'),
              ),
            );
          }
        }
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم تغيير الباقة إلى $profileName بنجاح')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('فشل تغيير الباقة: $e')));
      }
    }
  }

  Future<void> _debt(
    Subscriber s, {
    bool autoOpenReceiptAfterSave = false,
  }) async {
    if (AppStore.rolloverMonthlyBalances()) {
      await AppStore.save();
      if (!mounted) return;
    }
    final dialogBillingMonthKey = s.billingMonthKey;
    final price = TextEditingController(text: s.price.toStringAsFixed(0));
    final paid = TextEditingController(text: s.paid.toStringAsFixed(0));
    await showDialog<void>(
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
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'مبلغ الاشتراك',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: paid,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) => setLocal(() {}),
                  decoration: const InputDecoration(
                    labelText: 'واصل الشهر الحالي',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (s.carriedDebt > 0.0001)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'الدين المرحّل: ${moneyText(s.carriedDebt)} • إجمالي المتبقي: ${moneyText(s.remaining)}',
                      style: TextStyle(color: Colors.orange.shade800),
                    ),
                  ),
                const SizedBox(height: 8),
                Builder(
                  builder: (_) {
                    final priceAmount =
                        _parseAmount(price.text.trim()) ?? s.price;
                    final paidAmount = _parseAmount(paid.text.trim()) ?? s.paid;
                    final targetPaidAmount = (paidAmount).clamp(0, priceAmount);
                    final previewRemaining = (priceAmount - targetPaidAmount)
                        .clamp(0, double.infinity);
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
                          Text(
                            'مبلغ الاشتراك: ${priceAmount.toStringAsFixed(0)}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'الواصل: ${targetPaidAmount.toStringAsFixed(0)}',
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'المتبقي: ${previewRemaining.toStringAsFixed(0)}',
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () async {
                  if (s.billingMonthKey != dialogBillingMonthKey) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'بدأ شهر جديد أثناء التعديل؛ افتح شاشة الدين مجدداً',
                          ),
                        ),
                      );
                    }
                    return;
                  }
                  final oldPrice = s.price;
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
                  if (newPaidAmount == null ||
                      newPaidAmount < 0 ||
                      newPaidAmount > newPrice) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'يجب أن يكون الواصل بين صفر ومبلغ الاشتراك',
                          ),
                        ),
                      );
                    }
                    return;
                  }

                  final now = DateTime.now();
                  final adjustment = s.adjustDebtAmounts(
                    subscriptionAmount: newPrice,
                    paidAmount: newPaidAmount,
                    at: now,
                  );
                  final delta = adjustment.paymentDelta;
                  final addedDebt = adjustment.addedDebt;
                  final unpaidDebt = adjustment.unpaidAddedDebt;
                  final reducedDebt = adjustment.reducedDebt;
                  final subscriptionDelta = adjustment.subscriptionDelta;
                  if (delta.abs() <= 0.0001 &&
                      subscriptionDelta.abs() <= 0.0001) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('لا يوجد تعديل فعلي على الديون'),
                        ),
                      );
                    }
                    return;
                  }

                  InvoiceRecord? invoice;
                  if (delta > 0.0001) {
                    final receiptNumber = await AppStore.issueReceiptNumber(
                      persist: false,
                    );
                    invoice = s.registerInvoiceFromPayment(
                      receiptNumber: receiptNumber,
                      amount: delta,
                      at: now,
                      note: s.remaining <= 0.0001
                          ? 'تعديل تسديد كامل'
                          : 'تعديل تسديد جزئي',
                    );
                  }

                  final entryCollection = adjustment.appliedToCurrentCharge;
                  final debtRepayment = adjustment.appliedToCarriedDebt;
                  if (entryCollection > 0.0001) {
                    await AppStore.addDailyTaskEvent(
                      DailyTaskEvent(
                        type: DailyTaskEvent.debtEntryCollectionType,
                        subscriberUser: s.user,
                        subscriberName: s.name,
                        at: now,
                        amount: entryCollection,
                        remainingAfter: s.remaining,
                        note: 'واصل من مبلغ الاشتراك الجديد',
                      ),
                      persist: false,
                    );
                  }
                  if (debtRepayment > 0.0001) {
                    await AppStore.addDailyTaskEvent(
                      DailyTaskEvent(
                        type: 'debt_payment',
                        subscriberUser: s.user,
                        subscriberName: s.name,
                        at: now,
                        amount: debtRepayment,
                        remainingAfter: s.remaining,
                        note: s.remaining <= 0.0001
                            ? 'تسديد كامل'
                            : 'تسديد جزئي',
                      ),
                      persist: false,
                    );
                  }

                  if (unpaidDebt > 0.0001) {
                    await AppStore.addDailyTaskEvent(
                      DailyTaskEvent(
                        type: 'debt_added',
                        subscriberUser: s.user,
                        subscriberName: s.name,
                        at: now,
                        amount: unpaidDebt,
                        remainingAfter: s.remaining,
                        note: 'المتبقي من مبلغ الاشتراك',
                      ),
                      persist: false,
                    );
                  }
                  if (reducedDebt > 0.0001) {
                    await AppStore.addDailyTaskEvent(
                      DailyTaskEvent(
                        type: DailyTaskEvent.debtRemovedType,
                        subscriberUser: s.user,
                        subscriberName: s.name,
                        at: now,
                        amount: reducedDebt,
                        remainingAfter: s.remaining,
                        note: 'تخفيض مبلغ الاشتراك',
                      ),
                      persist: false,
                    );
                  }

                  if (delta > 0.0001) s.paymentDate = fmt(now);
                  if (s.paid <= 0 && delta <= 0.0001) s.paymentDate = '';
                  if ((oldPrice - s.price).abs() > 0.0001 ||
                      (oldPaid - s.paid).abs() > 0.0001 ||
                      (oldRemaining - s.remaining).abs() > 0.0001) {
                    final operationDate = fmt(now);
                    final editDetails = <String>[];
                    if (unpaidDebt > 0.0001) {
                      editDetails.add(
                        'بتاريخ $operationDate تم إضافة مبلغ دين ${moneyText(unpaidDebt)}',
                      );
                    }
                    if (reducedDebt > 0.0001) {
                      editDetails.add(
                        'بتاريخ $operationDate تم تخفيض مبلغ الاشتراك ${moneyText(reducedDebt)}',
                      );
                    }
                    if (delta > 0.0001) {
                      editDetails.add(
                        'بتاريخ $operationDate تم تسديد مبلغ ${moneyText(delta)}',
                      );
                    } else if (delta < -0.0001) {
                      editDetails.add(
                        'بتاريخ $operationDate تم تخفيض الواصل بمبلغ ${moneyText(delta.abs())}',
                      );
                    }
                    if (editDetails.isEmpty) {
                      editDetails.add(
                        'بتاريخ $operationDate تم تعديل مبلغ الاشتراك إلى ${moneyText(s.price)}',
                      );
                    }
                    await AppStore.addDailyTaskEvent(
                      DailyTaskEvent(
                        type: DailyTaskEvent.debtEditType,
                        subscriberUser: s.user,
                        subscriberName: s.name,
                        at: now,
                        amount: subscriptionDelta,
                        remainingAfter: s.remaining,
                        note: editDetails.join(' | '),
                      ),
                      persist: false,
                    );
                  }
                  await AppStore.save();
                  if (delta > 0.0001) {
                    await _recordLedgerTransaction(
                      subscriber: s,
                      type: FinancialTransactionType.payment,
                      amount: delta,
                      date: now,
                      referenceId: 'payment-receipt:${invoice!.receiptNumber}',
                      note: invoice.note,
                    );
                  } else if (delta < -0.0001) {
                    await _recordLedgerTransaction(
                      subscriber: s,
                      type: FinancialTransactionType.adjustment,
                      amount: delta,
                      date: now,
                      referenceId:
                          'payment-correction:${s.subscriberId}:${now.toUtc().toIso8601String()}',
                      note: 'تصحيح تخفيض الواصل',
                    );
                  }
                  if (addedDebt > 0.0001) {
                    await _recordLedgerTransaction(
                      subscriber: s,
                      type: FinancialTransactionType.debt,
                      amount: addedDebt,
                      date: now,
                      referenceId:
                          'debt-edit:${s.subscriberId}:${now.toUtc().toIso8601String()}',
                      note: 'إضافة مبلغ من شاشة ديون المشترك',
                    );
                  }
                  if (reducedDebt > 0.0001) {
                    await _recordLedgerTransaction(
                      subscriber: s,
                      type: FinancialTransactionType.adjustment,
                      amount: -reducedDebt,
                      date: now,
                      referenceId:
                          'debt-reduction:${s.subscriberId}:${now.toUtc().toIso8601String()}',
                      note: 'تخفيض مبلغ الاشتراك',
                    );
                  }

                  if (ctx.mounted) Navigator.pop(ctx);

                  if (autoOpenReceiptAfterSave && mounted) {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            ReceiptScreen(subscriber: s, invoice: invoice),
                      ),
                    );
                  }

                  if (mounted) {
                    setState(() {});
                    final syncWarning = AppStore.lastSaveSyncError == null
                        ? ''
                        : ' | حُفظ محلياً وتعذرت المزامنة';
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'تم الحفظ: الاشتراك ${newPrice.toStringAsFixed(0)} | الواصل ${oldPaid.toStringAsFixed(0)} -> ${s.paid.toStringAsFixed(0)} | '
                          'المتبقي ${oldRemaining.toStringAsFixed(0)} -> ${s.remaining.toStringAsFixed(0)}$syncWarning',
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
                    setLocal(
                      () => _columnVisibility['remainingDays'] = v ?? false,
                    );
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
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  await AppStore.deleteSubscriber(s);
                  await _recordSubscriberActivity(
                    s,
                    DailyTaskEvent.subscriberDeletedType,
                    'تم حذف المشترك',
                  );
                  selected = null;
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (mounted) setState(() {});
                } catch (error) {
                  if (!ctx.mounted) return;
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(
                      content: Text('تعذر حذف المشترك من Firebase: $error'),
                    ),
                  );
                }
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
      if (v != null && v.toString().trim().isNotEmpty) {
        return v.toString().trim();
      }
    }
    return fallback;
  }

  Future<void> _showAdvancedSearch() async {
    final packages =
        AppStore.subscribers
            .map((e) => e.packageDisplay.trim())
            .where((e) => e.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final parents =
        AppStore.subscribers
            .map(_parentText)
            .where((e) => e.isNotEmpty)
            .toSet()
            .toList()
          ..sort();

    var status = _advancedStatus;
    var package = packages.contains(_advancedPackage)
        ? _advancedPackage
        : 'الكل';
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
            title: const Row(
              children: [
                Icon(Icons.filter_alt_outlined),
                SizedBox(width: 8),
                Text('البحث المتقدم'),
              ],
            ),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: status,
                      decoration: _greenDropdownDecoration(
                        'الحالة',
                        Icons.info_outline,
                      ),
                      dropdownColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainer,
                      iconEnabledColor: const Color(0xFF2E7D32),
                      style: const TextStyle(
                        color: Color(0xFF2E7D32),
                        fontWeight: FontWeight.w600,
                      ),
                      items:
                          const [
                                'الكل',
                                'فعال',
                                'منتهي الصلاحية',
                                'معطل',
                                'ينتهي قريباً',
                                'خلال 3 أيام',
                                'ينتهي اشتراكهم اليوم',
                              ]
                              .map(
                                (e) =>
                                    DropdownMenuItem(value: e, child: Text(e)),
                              )
                              .toList(),
                      onChanged: (v) => setLocal(() => status = v ?? 'الكل'),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: connection,
                      decoration: _greenDropdownDecoration(
                        'الاتصال',
                        Icons.wifi_outlined,
                      ),
                      dropdownColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainer,
                      iconEnabledColor: const Color(0xFF2E7D32),
                      style: const TextStyle(
                        color: Color(0xFF2E7D32),
                        fontWeight: FontWeight.w600,
                      ),
                      items: const ['الكل', 'متصل', 'غير متصل']
                          .map(
                            (e) => DropdownMenuItem(value: e, child: Text(e)),
                          )
                          .toList(),
                      onChanged: (v) =>
                          setLocal(() => connection = v ?? 'الكل'),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: package,
                      decoration: _greenDropdownDecoration(
                        'الباقة',
                        Icons.inventory_2_outlined,
                      ),
                      dropdownColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainer,
                      iconEnabledColor: const Color(0xFF2E7D32),
                      style: const TextStyle(
                        color: Color(0xFF2E7D32),
                        fontWeight: FontWeight.w600,
                      ),
                      items: ['الكل', ...packages]
                          .map(
                            (e) => DropdownMenuItem(value: e, child: Text(e)),
                          )
                          .toList(),
                      onChanged: (v) => setLocal(() => package = v ?? 'الكل'),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: parent,
                      decoration: _greenDropdownDecoration(
                        'تابع إلى',
                        Icons.person_outline,
                      ),
                      dropdownColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainer,
                      iconEnabledColor: const Color(0xFF2E7D32),
                      style: const TextStyle(
                        color: Color(0xFF2E7D32),
                        fontWeight: FontWeight.w600,
                      ),
                      items: ['الكل', ...parents]
                          .map(
                            (e) => DropdownMenuItem(value: e, child: Text(e)),
                          )
                          .toList(),
                      onChanged: (v) => setLocal(() => parent = v ?? 'الكل'),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('المشتركين الفرعيين'),
                      subtitle: const Text(
                        'تضمين المشتركين الفرعيين في النتائج',
                      ),
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

  bool _matchesFilter(Subscriber s, String filter, DateTime now) {
    switch (filter) {
      case 'active':
        return s.isActive;
      case 'expired':
        return s.expired;
      case 'debts':
        return s.remaining > 0;
      case 'expiring3Days':
        if (s.disabled || s.expired) return false;
        return s.endsWithinDays(3, now);
      default:
        return true;
    }
  }

  int _countOf(String filter) {
    final now = DateTime.now();
    return AppStore.subscribers
        .where((s) => _matchesFilter(s, filter, now))
        .length;
  }

  void _setFilter(String filter) {
    setState(() {
      _filter = filter;
      selected = null;
      _visibleCards = 50;
      _filteredSubscribers = _buildFilteredSubscribers();
    });
  }

  void _onBottomNavigation(int index) {
    switch (index) {
      case 0:
        Navigator.of(context).popUntil((route) => route.isFirst);
      case DashboardBottomBar.addIndex:
        add();
      case 3:
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const QuickReportsScreen()),
        );
      case 4:
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const SettingsScreen()),
        );
    }
  }

  String get _sortLabel => switch (_sortBy) {
    'date' => 'تاريخ الانتهاء',
    'debt' => 'الدين',
    'user' => 'اسم المستخدم',
    'package' => 'الباقة',
    'status' => 'الحالة',
    _ => 'الاسم',
  };

  Widget _filterChip(String value, String label) {
    const green = Color(0xFF0E6B39);
    final colors = Theme.of(context).colorScheme;
    final active = _filter == value;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 6),
      child: Material(
        color: active ? green : colors.surface,
        shape: StadiumBorder(
          side: BorderSide(color: active ? green : colors.outlineVariant),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => _setFilter(value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            child: Text(
              '$label (${_countOf(value)})',
              style: TextStyle(
                color: active ? Colors.white : colors.onSurface,
                fontSize: 12,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _viewButton(bool cards, IconData icon, String tooltip, bool active) {
    const green = Color(0xFF0E6B39);
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: () => setState(() {
        _cardView = cards;
        selected = null;
      }),
      style: IconButton.styleFrom(
        backgroundColor: active ? green : Colors.transparent,
        foregroundColor: active
            ? Colors.white
            : Theme.of(context).colorScheme.onSurfaceVariant,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      icon: Icon(icon, size: 20),
    );
  }

  Widget _listHeader({required bool useCards, required int shownCount}) {
    const green = Color(0xFF0E6B39);
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final stats = <(String, String, String, Color)>[
      ('الإجمالي', 'all', 'subscribers_count', const Color(0xFF1565C0)),
      ('نشط', 'active', 'active_subscribers', const Color(0xFF1B8A4B)),
      (
        'قرب الانتهاء',
        'expiring3Days',
        'expiring_3_days',
        const Color(0xFFE67E00),
      ),
      ('ديون', 'debts', 'debts', const Color(0xFFD32F2F)),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.groups_rounded, color: green, size: 26),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'قائمة المشتركين',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: green.withValues(alpha: 0.28)),
                ),
                child: Text(
                  '$shownCount مشترك',
                  style: TextStyle(
                    color: isDark ? const Color(0xFF7BE0A0) : green,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < stats.length; i++) ...[
                  if (i > 0) const SizedBox(width: 7),
                  Expanded(
                    child: DashboardStatCard(
                      label: stats[i].$1,
                      value: '${_countOf(stats[i].$2)}',
                      assetName: 'assets/dashboard/${stats[i].$3}.png',
                      color: stats[i].$4,
                      iconSize: 34,
                      onTap: () => _setFilter(stats[i].$2),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _searchController,
            onChanged: (v) {
              q = v;
              selected = null;
              _visibleCards = 50;
              _reloadSubscribers();
            },
            decoration: InputDecoration(
              hintText: 'ابحث بالاسم أو اسم المستخدم أو IP...',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: q.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () {
                        q = '';
                        _searchController.clear();
                        selected = null;
                        _reloadSubscribers();
                      },
                      icon: const Icon(Icons.clear_rounded),
                    ),
              filled: true,
              fillColor: colors.surface,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(26),
                borderSide: BorderSide(color: colors.outlineVariant),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(26),
                borderSide: BorderSide(color: colors.outlineVariant),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(26),
                borderSide: const BorderSide(color: green, width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _filterChip('all', 'الكل'),
                      _filterChip('active', 'النشط'),
                      _filterChip('expiring3Days', 'قرب الانتهاء'),
                      _filterChip('expired', 'المنتهي'),
                      _filterChip('debts', 'الديون'),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton.outlined(
                tooltip: 'تصفية متقدمة',
                visualDensity: VisualDensity.compact,
                onPressed: _showAdvancedSearch,
                icon: const Icon(Icons.filter_alt_outlined, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              PopupMenuButton<String>(
                tooltip: 'ترتيب',
                onSelected: _sort,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'name', child: Text('الاسم')),
                  PopupMenuItem(value: 'date', child: Text('تاريخ الانتهاء')),
                  PopupMenuItem(value: 'debt', child: Text('الدين')),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: colors.outlineVariant),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'ترتيب: $_sortLabel',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        _sortAsc
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded,
                        size: 15,
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              _viewButton(
                false,
                Icons.table_rows_rounded,
                'عرض الجدول',
                !useCards,
              ),
              const SizedBox(width: 4),
              _viewButton(
                true,
                Icons.view_agenda_rounded,
                'عرض البطاقات',
                useCards,
              ),
            ],
          ),
          if (!useCards) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: selected == null ? null : operations,
                    icon: const Icon(Icons.settings_outlined, size: 18),
                    label: const Text('عمليات سريعة'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _showColumnSelector,
                  icon: const Icon(Icons.view_column_outlined, size: 18),
                  label: const Text('المزيد'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _filteredSubscribers;
    final useCards = _cardView ?? MediaQuery.sizeOf(context).width < 520;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final greenSoft = const Color(0xFFD8F3DC);
    final dataSource = _SubscribersDataSource(
      context: context,
      data: data,
      selectedSubscriber: selected,
      onSelect: (s) => setState(() => selected = s),
      onNameTap: (s) async {
        setState(() => selected = s);
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SubscriberDetailsScreen(
              subscriber: s,
              onEditDebt: (subscriber) => _debt(subscriber),
              onAddDebtAmount: (subscriber) => _debt(subscriber),
              onPartialDebtPayment: (subscriber) =>
                  recordPartialPayment(context, subscriber),
            ),
          ),
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
              MaterialPageRoute(
                builder: (_) => AddSubscriberScreen(subscriber: s),
              ),
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
            if (_blockFormer(s)) break;
            final rawId = s.sasId.trim().isNotEmpty
                ? s.sasId.trim()
                : (s.sasData['id'] ?? s.sasData['user_id'] ?? '')
                      .toString()
                      .trim();
            final userId = int.tryParse(rawId);
            if (userId == null) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('تعذر التعطيل: لا يوجد SAS ID صحيح للمشترك'),
                  ),
                );
              }
              break;
            }
            try {
              final settings = await SasSettings.forSubscriber(s);
              if (settings.username.trim().isEmpty ||
                  settings.password.isEmpty) {
                throw Exception('أكمل إعدادات ربط SAS أولاً');
              }
              final api = SasApiService(settings);
              await api
                  .disableUser(userId)
                  .timeout(
                    const Duration(seconds: 30),
                    onTimeout: () => throw Exception('انتهت مهلة طلب التعطيل'),
                  );
              s.disabled = true;
              s.active = false;
              await AppStore.save();
              await _recordSubscriberActivity(
                s,
                DailyTaskEvent.subscriberDisabledType,
                'تم تعطيل المشترك في SAS',
              );
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
            if (_blockFormer(s)) break;
            final rawId = s.sasId.trim().isNotEmpty
                ? s.sasId.trim()
                : (s.sasData['id'] ?? s.sasData['user_id'] ?? '')
                      .toString()
                      .trim();
            final userId = int.tryParse(rawId);
            if (userId == null) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'تعذر إلغاء التعطيل: لا يوجد SAS ID صحيح للمشترك',
                    ),
                  ),
                );
              }
              break;
            }
            try {
              final settings = await SasSettings.forSubscriber(s);
              if (settings.username.trim().isEmpty ||
                  settings.password.isEmpty) {
                throw Exception('أكمل إعدادات ربط SAS أولاً');
              }
              final api = SasApiService(settings);
              await api
                  .enableUser(userId)
                  .timeout(
                    const Duration(seconds: 30),
                    onTimeout: () =>
                        throw Exception('انتهت مهلة طلب إلغاء التعطيل'),
                  );
              s.disabled = false;
              s.active = true;
              await AppStore.save();
              await _recordSubscriberActivity(
                s,
                DailyTaskEvent.subscriberEnabledType,
                'تم إلغاء تعطيل المشترك في SAS',
              );
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
            await _debt(s);
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
              MaterialPageRoute(
                builder: (_) => SubscriberDetailsScreen(
                  subscriber: s,
                  onEditDebt: (subscriber) => _debt(subscriber),
                  onAddDebtAmount: (subscriber) => _debt(subscriber),
                  onPartialDebtPayment: (subscriber) =>
                      recordPartialPayment(context, subscriber),
                ),
              ),
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
        backgroundColor: isDark
            ? const Color(0xFF0F172A)
            : const Color(0xFFF1F8F3),
        bottomNavigationBar: DashboardBottomBar(
          selectedIndex: 1,
          onSelected: _onBottomNavigation,
        ),
        appBar: AppBar(
          title: Text(pageTitle),
          centerTitle: true,
          backgroundColor: const Color(0xFF0B5D2E),
          foregroundColor: Colors.white,
          elevation: 0,
          clipBehavior: Clip.antiAlias,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(22)),
          ),
          flexibleSpace: SizedBox.expand(
            child: Image.asset(
              dashboardReferenceAssetPath('assets/dashboard/waves.jpg'),
              fit: BoxFit.cover,
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'مزامنة SAS وتحديث المتصلين',
              onPressed: syncing || _isRefreshing ? null : _syncAndRefresh,
              icon: syncing || _isRefreshing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
            ),
          ],
        ),
        body: Scrollbar(
          controller: _verticalScrollController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _verticalScrollController,
            child: Column(
              children: [
                _listHeader(useCards: useCards, shownCount: data.length),
                const SizedBox(height: 8),
                if (data.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.people_outline,
                          size: 64,
                          color: Colors.grey.shade300,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          AppStore.subscribers.isEmpty
                              ? 'لا يوجد مشتركين مسجلين'
                              : 'لا توجد نتائج مطابقة للبحث أو التصفية',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  )
                else if (useCards)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final s in data.take(_visibleCards))
                        _SubscriberCard(
                          subscriber: s,
                          selected: identical(selected, s),
                          onOpen: () => dataSource.onNameTap(s),
                          onActivate: () => _activateSubscriber(s),
                          onPay: () async {
                            await recordPartialPayment(context, s);
                            if (mounted) setState(() {});
                          },
                          onMore: () {
                            setState(() => selected = s);
                            operations();
                          },
                          onPickSas: () => _pickReferenceSas(s),
                        ),
                      if (data.length > _visibleCards)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          child: OutlinedButton(
                            onPressed: () =>
                                setState(() => _visibleCards += 50),
                            child: Text(
                              'عرض المزيد (${data.length - _visibleCards})',
                            ),
                          ),
                        ),
                    ],
                  )
                else
                  SizedBox(
                    width: double.infinity,
                    child: Card(
                      margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 2,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Theme(
                          data: Theme.of(context).copyWith(
                            dataTableTheme: DataTableThemeData(
                              headingRowColor: WidgetStateProperty.all(
                                isDark
                                    ? const Color(0xFF263449)
                                    : greenSoft.withValues(alpha: 0.85),
                              ),
                              headingRowHeight: 56,
                              dataRowMinHeight: 64,
                              dataRowMaxHeight: 64,
                              dividerThickness: 1,
                              headingTextStyle: TextStyle(
                                color: isDark
                                    ? const Color(0xFF86D18F)
                                    : const Color(0xFF2E7D32),
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
                              if (value != null) {
                                setState(() => _rowsPerPage = value);
                              }
                            },
                            sortColumnIndex: _sortColumnIndex,
                            sortAscending: _sortAsc,
                            columns: [
                              const DataColumn(
                                label: Text(
                                  'م',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ),
                              DataColumn(
                                label: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  textDirection: TextDirection.rtl,
                                  children: [
                                    const Icon(Icons.info_outline, size: 18),
                                    const SizedBox(width: 8),
                                    const Text(
                                      'الحالة',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    if (_sortBy == 'status')
                                      Icon(
                                        _sortAsc
                                            ? Icons.arrow_upward
                                            : Icons.arrow_downward,
                                        size: 14,
                                      ),
                                  ],
                                ),
                                onSort: (index, ascending) =>
                                    _sort('status', index),
                              ),
                              DataColumn(
                                label: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  textDirection: TextDirection.rtl,
                                  children: [
                                    const Icon(Icons.person_outline, size: 18),
                                    const SizedBox(width: 6),
                                    const Text(
                                      'اسم المشترك',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    if (_sortBy == 'name')
                                      Icon(
                                        _sortAsc
                                            ? Icons.arrow_upward
                                            : Icons.arrow_downward,
                                        size: 14,
                                      ),
                                  ],
                                ),
                                onSort: (index, ascending) =>
                                    _sort('name', index),
                              ),
                              DataColumn(
                                label: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  textDirection: TextDirection.rtl,
                                  children: [
                                    const Icon(
                                      Icons.account_circle_outlined,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 8),
                                    const Text(
                                      'اسم المستخدم',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    if (_sortBy == 'user')
                                      Icon(
                                        _sortAsc
                                            ? Icons.arrow_upward
                                            : Icons.arrow_downward,
                                        size: 14,
                                      ),
                                  ],
                                ),
                                onSort: (index, ascending) =>
                                    _sort('user', index),
                              ),
                              DataColumn(
                                label: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  textDirection: TextDirection.rtl,
                                  children: [
                                    const Icon(
                                      Icons.inventory_2_outlined,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 8),
                                    const Text(
                                      'الباقة',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    if (_sortBy == 'package')
                                      Icon(
                                        _sortAsc
                                            ? Icons.arrow_upward
                                            : Icons.arrow_downward,
                                        size: 14,
                                      ),
                                  ],
                                ),
                                onSort: (index, ascending) =>
                                    _sort('package', index),
                              ),
                              DataColumn(
                                label: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  textDirection: TextDirection.rtl,
                                  children: [
                                    const Icon(Icons.event_outlined, size: 18),
                                    const SizedBox(width: 8),
                                    const Text(
                                      'تاريخ الانتهاء',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    if (_sortBy == 'date')
                                      Icon(
                                        _sortAsc
                                            ? Icons.arrow_upward
                                            : Icons.arrow_downward,
                                        size: 14,
                                      ),
                                  ],
                                ),
                                onSort: (index, ascending) =>
                                    _sort('date', index),
                              ),
                              // Connection column removed
                              DataColumn(
                                label: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  textDirection: TextDirection.rtl,
                                  children: [
                                    const Icon(
                                      Icons.account_balance_wallet_outlined,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 8),
                                    const Text(
                                      'الديون',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    if (_sortBy == 'debt')
                                      Icon(
                                        _sortAsc
                                            ? Icons.arrow_upward
                                            : Icons.arrow_downward,
                                        size: 14,
                                      ),
                                  ],
                                ),
                                onSort: (index, ascending) =>
                                    _sort('debt', index),
                              ),
                              DataColumn(
                                label: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  textDirection: TextDirection.rtl,
                                  children: [
                                    const Icon(Icons.language, size: 18),
                                    const SizedBox(width: 8),
                                    const Text(
                                      'IP',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              DataColumn(
                                label: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  textDirection: TextDirection.rtl,
                                  children: [
                                    const Icon(
                                      Icons.schedule_outlined,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 8),
                                    const Text(
                                      'الأيام',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SubscriberCard extends StatelessWidget {
  const _SubscriberCard({
    required this.subscriber,
    required this.selected,
    required this.onOpen,
    required this.onActivate,
    required this.onPay,
    required this.onMore,
    this.onPickSas,
  });

  static const _green = Color(0xFF1B8A4B);
  static const _amber = Color(0xFFE67E00);
  static const _red = Color(0xFFD32F2F);

  final Subscriber subscriber;
  final bool selected;
  final VoidCallback onOpen;
  final VoidCallback onActivate;
  final VoidCallback onPay;
  final VoidCallback onMore;
  final VoidCallback? onPickSas;

  (String, Color, IconData) get _status {
    final s = subscriber;
    if (s.isFormer) {
      return ('مشترك سابق', Colors.blueGrey, Icons.history_rounded);
    }
    if (s.awaitingActivation) {
      return ('غير مفعّل', Colors.blueGrey, Icons.hourglass_empty_rounded);
    }
    if (s.disabled) {
      return ('معطل', _amber, Icons.pause_circle_rounded);
    }
    if (s.expired) return ('منتهي', _red, Icons.cancel_rounded);
    if (s.endsWithinDays(3)) {
      return ('قرب الانتهاء', _amber, Icons.warning_amber_rounded);
    }
    if (s.isActive) return ('نشط', _green, Icons.check_circle_rounded);
    return ('غير فعال', Colors.blueGrey, Icons.radio_button_unchecked_rounded);
  }

  Widget _pill(String text, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  static final _arabicText = RegExp(r'[\u0600-\u06FF]');

  /// اليوزر والباقة لاتينيان غالباً، فيجب ألا يعيد السياق العربي ترتيب أجزائهما.
  TextDirection _textDirectionOf(String text) =>
      _arabicText.hasMatch(text) ? TextDirection.rtl : TextDirection.ltr;

  Future<void> _copyIp(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: subscriber.ip.trim()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('تم نسخ عنوان IP')));
  }

  @override
  Widget build(BuildContext context) {
    final s = subscriber;
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasDebt = s.remaining > 0.0001;
    final hasIp = s.ip.trim().isNotEmpty;
    final status = _status;
    final title = s.name.trim().isEmpty ? s.user : s.name;
    final end =
        '${s.endDate.day.toString().padLeft(2, '0')}/${s.endDate.month.toString().padLeft(2, '0')}/${s.endDate.year}';
    final radius = BorderRadius.circular(16);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: radius,
        border: Border.all(
          color: selected
              ? _green
              : colors.outlineVariant.withValues(alpha: 0.6),
          width: selected ? 1.5 : 1,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x120B5D2E),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onOpen,
          borderRadius: radius,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            status.$2.withValues(alpha: 0.55),
                            status.$2,
                          ],
                        ),
                      ),
                      child: const Icon(
                        Icons.person_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textDirection: _textDirectionOf(title),
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Flexible(
                                flex: 3,
                                child: Text(
                                  s.user,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textDirection: _textDirectionOf(s.user),
                                  style: TextStyle(
                                    color: colors.onSurface,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Text(
                                ' • ',
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                  fontSize: 11.5,
                                ),
                              ),
                              Flexible(
                                flex: 2,
                                child: Text(
                                  s.packageDisplay,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textDirection: _textDirectionOf(
                                    s.packageDisplay,
                                  ),
                                  style: TextStyle(
                                    color: colors.onSurfaceVariant,
                                    fontSize: 11.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _pill(status.$1, status.$3, status.$2),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              s.isOnline
                                  ? Icons.wifi_rounded
                                  : Icons.wifi_off_rounded,
                              size: 14,
                              color: s.isOnline
                                  ? const Color(0xFF1E88E5)
                                  : colors.onSurfaceVariant,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              s.isOnline ? 'متصل' : 'غير متصل',
                              style: TextStyle(
                                color: s.isOnline
                                    ? const Color(0xFF1E88E5)
                                    : colors.onSurfaceVariant,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    // الموجود في أكثر من ساس: الضغط يختار الساس المرجع.
                    if (s.inSeveralSas)
                      InkWell(
                        key: ValueKey('pick-sas-${s.subscriberId}'),
                        onTap: onPickSas,
                        borderRadius: BorderRadius.circular(14),
                        child: _pill(
                          '${SasSettings.labelFor(s.sasAccount)} ▾ (${s.sasPresence.length} ساس)',
                          Icons.alt_route_rounded,
                          Colors.indigo,
                        ),
                      )
                    else if (s.sasAccount.isNotEmpty)
                      _pill(
                        SasSettings.labelFor(s.sasAccount),
                        Icons.dns_rounded,
                        Colors.indigo,
                      ),
                    if (hasDebt)
                      _pill(
                        'دين: ${moneyText(s.remaining)}',
                        Icons.payments_rounded,
                        _red,
                      ),
                    if (!s.expired)
                      _pill(
                        remainingTimeText(s.endDate),
                        Icons.hourglass_bottom_rounded,
                        s.endsWithinDays(7) ? _amber : _green,
                      ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.event_rounded,
                          size: 14,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 3),
                        Text(end, style: const TextStyle(fontSize: 11.5)),
                      ],
                    ),
                  ],
                ),
                Divider(
                  height: 13,
                  color: colors.outlineVariant.withValues(alpha: 0.5),
                ),
                Row(
                  children: [
                    if (!hasDebt) ...[
                      const Icon(
                        Icons.check_circle_outline_rounded,
                        size: 15,
                        color: _green,
                      ),
                      const SizedBox(width: 3),
                      const Text(
                        'مسدد',
                        style: TextStyle(
                          color: _green,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              hasIp ? 'IP ${s.ip.trim()}' : 'IP —',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textDirection: TextDirection.ltr,
                              style: const TextStyle(
                                color: Color(0xFF1E88E5),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (hasIp)
                            IconButton(
                              tooltip: 'نسخ IP',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 30,
                                minHeight: 30,
                              ),
                              onPressed: () => _copyIp(context),
                              icon: const Icon(Icons.copy_rounded, size: 15),
                            ),
                        ],
                      ),
                    ),
                    if (hasDebt)
                      TextButton(
                        onPressed: onPay,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 34),
                        ),
                        child: const Text('تسديد'),
                      ),
                    FilledButton.icon(
                      onPressed: onActivate,
                      icon: Icon(
                        s.expired
                            ? Icons.play_arrow_rounded
                            : Icons.bolt_rounded,
                        size: 16,
                      ),
                      label: Text(
                        s.expired ? 'تفعيل' : 'تجديد',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF12873F),
                        foregroundColor: Colors.white,
                        visualDensity: VisualDensity.compact,
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 11),
                      ),
                    ),
                    IconButton(
                      tooltip: 'عمليات سريعة',
                      visualDensity: VisualDensity.compact,
                      onPressed: onMore,
                      icon: const Icon(Icons.more_horiz_rounded),
                    ),
                  ],
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

  String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  static Color _statusColor(Subscriber s) {
    // Disabled users keep the orange highlight.
    if (s.disabled) return Colors.orange;

    final online = s.isOnline;
    if (s.expired) {
      return online ? Colors.red : Colors.orange;
    }
    return online ? Colors.blue : Colors.green;
  }

  static String _statusLabel(Subscriber s) {
    if (s.disabled) return 'معطل';
    if (s.expired) return 'منتهي';
    if (s.isOnline) return 'متصل';
    if (s.isActive) return 'فعال';
    return 'غير فعال';
  }

  static IconData _statusIcon(Subscriber s) {
    if (s.disabled) return Icons.pause_circle_outline_rounded;
    if (s.expired) return Icons.event_busy_outlined;
    if (s.isOnline) return Icons.wifi_rounded;
    if (s.isActive) return Icons.check_circle_outline_rounded;
    return Icons.radio_button_unchecked_rounded;
  }

  @override
  DataRow? getRow(int index) {
    if (index >= data.length) return null;
    final s = data[index];
    // One-time debug: dump sasData for a specific subscriber to inspect online fields
    final selected = identical(selectedSubscriber, s);
    final remainingDays = s.endDate.difference(DateTime.now()).inHours / 24;
    final statusColor = _statusColor(s);
    final cells = [
      DataCell(
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 48),
          child: Text('${index + 1}', textAlign: TextAlign.center),
        ),
      ),
      DataCell(
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 110),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: statusColor.withValues(alpha: 0.35)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(_statusIcon(s), size: 14, color: statusColor),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      _statusLabel(s),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
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
      DataCell(
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 200),
          child: Text(s.user, overflow: TextOverflow.ellipsis),
        ),
      ),
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
      DataCell(
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 160),
          child: Text(_fmt(s.endDate), overflow: TextOverflow.ellipsis),
        ),
      ),
      DataCell(
        Tooltip(
          message: s.remaining > 0.0001
              ? 'اضغط لعرض أو تعديل ديون ${s.name}'
              : 'لا يوجد مبلغ متبقٍ على ${s.name}',
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () async => onActionSelected(s, 'debts'),
            child: Container(
              constraints: const BoxConstraints(minWidth: 96, maxWidth: 150),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: s.remaining > 0.0001
                    ? const Color(0xFFFFEBEE)
                    : const Color(0xFFE8F5E9),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: s.remaining > 0.0001
                      ? const Color(0xFFEF9A9A)
                      : const Color(0xFFA5D6A7),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    s.remaining > 0.0001
                        ? Icons.payments_outlined
                        : Icons.check_circle_outline_rounded,
                    size: 16,
                    color: s.remaining > 0.0001
                        ? const Color(0xFFC62828)
                        : const Color(0xFF2E7D32),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      s.remaining > 0.0001
                          ? '${moneyText(s.remaining)}'
                          : 'مسدد',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                        color: s.remaining > 0.0001
                            ? const Color(0xFFC62828)
                            : const Color(0xFF2E7D32),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
                      await launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      );
                    } catch (_) {}
                  },
                  child: Tooltip(
                    message: s.isOnline ? 'متصل الآن' : 'آخر IP معروف',
                    child: Text(
                      s.ip.isEmpty ? '—' : s.ip,
                      style: TextStyle(
                        fontWeight: s.isOnline
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: s.isOnline
                            ? Colors.blue.shade700
                            : Colors.grey.shade500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: remainingDays < 0
                        ? Colors.red.withValues(alpha: 0.15)
                        : remainingDays < 7
                        ? Colors.orange.withValues(alpha: 0.15)
                        : Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    s.expired ? 'منتهي' : remainingTimeText(s.endDate),
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
