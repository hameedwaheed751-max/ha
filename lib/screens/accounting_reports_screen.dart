import 'dart:typed_data';

import 'package:excel/excel.dart' as xls;
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';

import '../models.dart';
import '../sas_api_service.dart';
import '../sas_project_national_service.dart';
import '../services/sas_wallets.dart';
import 'subscriber_details_screen.dart';

export '../services/sas_wallets.dart' show parseSasAmount;

/// تفعيل لمشترك FTTH. السجلات القديمة بلا مصدر تُعرف من المشترك نفسه.
bool isFtthActivation(AccountingActivationRecord record) {
  if (record.source.isNotEmpty) return record.source == 'ftth';
  final user = record.subscriberUser.trim().toLowerCase();
  if (user.isEmpty) return false;
  return AppStore.subscribers.any(
    (s) => s.source == 'ftth' && s.user.trim().toLowerCase() == user,
  );
}

/// هل سُجل في التطبيق تفعيل لهذا اليوزر خلال يوم من وقت تفعيل الساس.
/// null حين لا يمكن الحكم (لا يوزر أو لا تاريخ).
bool? isRecordedInApp(
  Map<String, List<DateTime>> recordedDays,
  String username,
  DateTime? at,
) {
  final user = username.trim().toLowerCase();
  if (user.isEmpty || at == null) return null;
  final days = recordedDays[user];
  if (days == null) return false;
  return days.any((day) => day.difference(at).abs() <= const Duration(days: 1));
}

/// التقرير الحسابي الشهري: أربعة أسئلة فقط (المبيعات، النقد، الديون، الأرصدة)
/// ثم التفاصيل. الأرقام نفسها التي تجمعها المهام اليومية لأيام الشهر.
class AccountingReportsScreen extends StatefulWidget {
  const AccountingReportsScreen({super.key});

  @override
  State<AccountingReportsScreen> createState() =>
      _AccountingReportsScreenState();
}

class _AccountingReportsScreenState extends State<AccountingReportsScreen> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  /// أرصدة كل الساسات المربوطة.
  SasWallets? _wallets;
  bool _loadingSasBalance = false;

  /// كل الساسات؛ الجدول المالي يعرض واحداً منها يختاره الوكيل.
  List<SasSettings> _sasAccounts = const [];
  String _reportAccount = '';
  bool _ftthConfigured = false;
  double? _ftthBalance;
  bool _loadingFtthBalance = false;
  String? _ftthBalanceError;
  SasFinancialReportType _reportType = SasFinancialReportType.activations;
  SasFinancialPage? _financialPage;
  bool _loadingFinancialReport = false;
  String? _financialReportError;

  /// سجل الشهر لكل ساس، بمعرفه.
  Map<String, SasManagerJournalMonth> _journals = const {};
  int _activationPage = 1;
  static const _activationsPerPage = 10;
  bool _loadingJournalMonth = false;
  Map<String, String> _journalErrors = const {};

  static const _monthNames = <String>[
    'كانون الثاني',
    'شباط',
    'آذار',
    'نيسان',
    'أيار',
    'حزيران',
    'تموز',
    'آب',
    'أيلول',
    'تشرين الأول',
    'تشرين الثاني',
    'كانون الأول',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadSasBalance();
      _loadFtthBalance();
      _loadFinancialReport();
      _loadJournalMonth();
    });
  }

  /// الرصيد المباشر من الساس، وإلا الرصيد بعد آخر حركة في سجل الشهر الحالي.
  /// رصيد ساس: المباشر منه، وإلا الرصيد بعد آخر حركة في سجل الشهر الحالي.
  double? _balanceOf(String account) {
    for (final wallet in _wallets?.items ?? const <SasWallet>[]) {
      if (wallet.account.accountId == account && wallet.balance != null) {
        return wallet.balance;
      }
    }
    final now = DateTime.now();
    final current = _month.year == now.year && _month.month == now.month;
    return current ? _journals[account]?.latestBalance : null;
  }

  /// مجموع أرصدة الساسات المعروفة.
  double? get _currentSasBalance {
    final known = _sasAccounts
        .map((a) => _balanceOf(a.accountId))
        .whereType<double>()
        .toList();
    if (known.isEmpty) return null;
    return known.fold<double>(0, (sum, v) => sum + v);
  }

  double? get _monthDeposits => _journals.isEmpty
      ? null
      : _journals.values.fold<double>(0, (sum, j) => sum + j.deposits);

  double? get _monthDeductions => _journals.isEmpty
      ? null
      : _journals.values.fold<double>(0, (sum, j) => sum + j.deductions);

  String _accountName(String account) {
    for (final a in _sasAccounts) {
      if (a.accountId == account) return a.displayName;
    }
    return SasSettings.labelFor(account);
  }

  String? get _journalMonthError => _journalErrors.isEmpty
      ? null
      : _journalErrors.entries
            .map(
              (e) => _sasAccounts.length > 1
                  ? '${_accountName(e.key)}: ${e.value}'
                  : e.value,
            )
            .join('\n');

  String get _monthLabel => '${_monthNames[_month.month - 1]} ${_month.year}';

  bool _inSelectedMonth(DateTime date) =>
      date.year == _month.year && date.month == _month.month;

  /// كل تفعيلات الشهر، ومنها FTTH: للنقد والديون كما في المهام اليومية.
  List<AccountingActivationRecord> get _allMonthActivations => AppStore
      .accountingActivations
      .where((record) => _inSelectedMonth(record.at))
      .toList();

  /// تفعيلات الساس فقط، الأحدث أولاً: للمبيعات والربح والقائمة.
  List<AccountingActivationRecord> get _activations =>
      _allMonthActivations.where((record) => !isFtthActivation(record)).toList()
        ..sort((a, b) => b.at.compareTo(a.at));

  Subscriber? _subscriberOf(AccountingActivationRecord record) {
    final user = record.subscriberUser.trim().toLowerCase();
    if (user.isEmpty) return null;
    for (final subscriber in AppStore.subscribers) {
      if (subscriber.user.trim().toLowerCase() == user) return subscriber;
    }
    return null;
  }

  void _openSubscriber(AccountingActivationRecord record) {
    final subscriber = _subscriberOf(record);
    if (subscriber == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('المشترك لم يعد موجوداً في التطبيق')),
      );
      return;
    }
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => SubscriberDetailsScreen(subscriber: subscriber),
          ),
        )
        .then((_) {
          if (mounted) setState(() {});
        });
  }

  /// يوزرات الساس المسجل تفعيلها في التطبيق، مع أيامها، لمطابقة سجل الساس.
  Map<String, List<DateTime>> get _recordedActivationDays {
    final days = <String, List<DateTime>>{};
    for (final record in AppStore.accountingActivations) {
      final user = record.subscriberUser.trim().toLowerCase();
      if (user.isEmpty) continue;
      days.putIfAbsent(user, () => []).add(record.at.toLocal());
    }
    return days;
  }

  Iterable<DailyTaskEvent> get _monthEvents =>
      AppStore.dailyTaskEvents.where((event) => _inSelectedMonth(event.at));

  /// مجموع المهام اليومية لأيام الشهر، بالطريقة نفسها.
  DailyTaskSummary _cashSummary(List<AccountingActivationRecord> activations) =>
      DailyTaskSummary.fromEvents(_monthEvents, activations: activations);

  double get _currentOutstandingDebt => AppStore.subscribers.fold<double>(
    0,
    (total, subscriber) => total + subscriber.remaining,
  );

  String _money(double value) {
    final rounded = value.round();
    final sign = rounded < 0 ? '-' : '';
    final digits = rounded.abs().toString();
    final formatted = digits.replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );
    return '$sign$formatted د.ع';
  }

  String _dateTime(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}/${two(local.month)}/${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  void _changeMonth(int offset) {
    setState(() {
      _month = DateTime(_month.year, _month.month + offset);
      _activationPage = 1;
    });
    _loadJournalMonth();
  }

  Future<void> _loadSasBalance() async {
    if (_loadingSasBalance) return;
    setState(() => _loadingSasBalance = true);
    try {
      final accounts = await SasSettings.loadAll();
      if (mounted) setState(() => _sasAccounts = accounts);
      final wallets = await SasWallets.load(loadAccounts: () async => accounts);
      if (mounted) setState(() => _wallets = wallets);
    } catch (_) {
      if (mounted) setState(() => _wallets = null);
    } finally {
      if (mounted) setState(() => _loadingSasBalance = false);
    }
  }

  Future<void> _loadFtthBalance() async {
    if (_loadingFtthBalance) return;
    setState(() {
      _loadingFtthBalance = true;
      _ftthBalanceError = null;
    });
    try {
      final settings = await SasProjectNationalSettings.load();
      if (!settings.isComplete) {
        if (mounted) setState(() => _ftthConfigured = false);
        return;
      }
      if (mounted) setState(() => _ftthConfigured = true);
      final service = SasProjectNationalService(settings);
      final balance = await service.fetchOwnPartnerBalance();
      if (mounted) setState(() => _ftthBalance = balance);
    } catch (error) {
      if (mounted) {
        setState(() {
          _ftthBalance = null;
          _ftthBalanceError = '$error';
        });
      }
    } finally {
      if (mounted) setState(() => _loadingFtthBalance = false);
    }
  }

  Future<void> _loadFinancialReport({
    SasFinancialReportType? type,
    int page = 1,
  }) async {
    if (_loadingFinancialReport) return;
    final selectedType = type ?? _reportType;
    setState(() {
      _reportType = selectedType;
      _loadingFinancialReport = true;
      _financialReportError = null;
    });
    try {
      final settings = await SasSettings.forAccount(_reportAccount);
      final result = await SasApiService(
        settings,
      ).fetchFinancialReport(selectedType, page: page, count: 10);
      if (!mounted || selectedType != _reportType) return;
      setState(() => _financialPage = result);
    } catch (error) {
      if (!mounted || selectedType != _reportType) return;
      setState(() {
        _financialPage = null;
        _financialReportError = error.toString();
      });
    } finally {
      if (mounted && selectedType == _reportType) {
        setState(() => _loadingFinancialReport = false);
      }
    }
  }

  Future<void> _loadJournalMonth() async {
    final requestedMonth = _month;
    setState(() {
      _loadingJournalMonth = true;
      _journals = const {};
      _journalErrors = const {};
    });
    try {
      final accounts = await SasSettings.loadAll();
      final journals = <String, SasManagerJournalMonth>{};
      final errors = <String, String>{};
      await Future.wait(
        accounts.map((account) async {
          try {
            journals[account.accountId] = await SasApiService(
              account,
            ).fetchManagerJournalMonth(requestedMonth);
          } catch (error) {
            errors[account.accountId] = error.toString();
          }
        }),
      );
      if (!mounted || requestedMonth != _month) return;
      setState(() {
        _sasAccounts = accounts;
        _journals = journals;
        _journalErrors = errors;
      });
    } catch (error) {
      if (!mounted || requestedMonth != _month) return;
      setState(() => _journalErrors = {'': error.toString()});
    } finally {
      if (mounted && requestedMonth == _month) {
        setState(() => _loadingJournalMonth = false);
      }
    }
  }

  void _refreshAll() {
    _loadSasBalance();
    _loadFtthBalance();
    _loadJournalMonth();
    _loadFinancialReport(page: _financialPage?.currentPage ?? 1);
  }

  Future<void> _exportMonthlyReport() async {
    try {
      final activations = _activations;
      final sales = AccountingMonthlySummary.fromRecords(
        activations: activations,
      );
      final cash = _cashSummary(_allMonthActivations);
      final settlements = ActivationOutcome.of(activations, _monthEvents);
      final excel = xls.Excel.createExcel();
      const sheetName = 'التقرير الحسابي';
      final sheet = excel[sheetName];
      final defaultSheet = excel.getDefaultSheet();
      if (defaultSheet != null && defaultSheet != sheetName) {
        excel.delete(defaultSheet);
      }
      void row(String label, [Object? value]) => sheet.appendRow([
        xls.TextCellValue(label),
        switch (value) {
          null => xls.TextCellValue(''),
          int v => xls.IntCellValue(v),
          double v => xls.DoubleCellValue(v),
          _ => xls.TextCellValue('$value'),
        },
      ]);

      row('الشهر', _monthLabel);
      row('');
      row('مبيعات الساس والربح');
      row('عدد التفعيلات', sales.activationCount);
      row('المبيعات', sales.subscriberSales);
      row('كلفة الساس', sales.sasDeductions);
      row('الربح', sales.profit);
      row('');
      row('النقد المستلم');
      row('واصل عند التفعيل', cash.activationCollected);
      row('تسديد ديون', cash.debtPaymentsCollected);
      if (cash.otherCollected > 0) row('واصل آخر', cash.otherCollected);
      row('المجموع المستلم', cash.totalCollected);
      row('');
      row('الديون');
      row('ديون أُضيفت هذا الشهر', cash.debtAddedTotal);
      row('ديون سُددت هذا الشهر', cash.debtPaymentsCollected);
      if (cash.debtReducedTotal > 0) {
        row('ديون أُسقطت هذا الشهر', cash.debtReducedTotal);
      }
      row('المتبقي الآن على المشتركين', _currentOutstandingDebt);
      row('');
      row('الأرصدة');
      row('إيداعات الساس هذا الشهر', _monthDeposits ?? 'غير متاح');
      row('استقطاعات الساس هذا الشهر', _monthDeductions ?? 'غير متاح');
      row('رصيد الساس الحالي', _currentSasBalance ?? 'غير متاح');
      if (_sasAccounts.length > 1) {
        for (final account in _sasAccounts) {
          row(
            'رصيد ${account.displayName}',
            _balanceOf(account.accountId) ?? 'غير متاح',
          );
        }
      }
      if (_ftthConfigured) row('رصيد محفظة FTTH', _ftthBalance ?? 'غير متاح');
      row('');
      row('تفاصيل التفعيلات');
      sheet.appendRow([
        for (final title in const [
          'التاريخ',
          'المشترك',
          'اليوزر',
          'الباقة',
          'السعر',
          'الكلفة',
          'الربح',
          'الدفع',
          'الواصل',
          'الدين',
        ])
          xls.TextCellValue(title),
      ]);
      for (final record in activations) {
        final s = settlements[record];
        sheet.appendRow([
          xls.TextCellValue(_dateTime(record.at)),
          xls.TextCellValue(record.subscriberName),
          xls.TextCellValue(record.subscriberUser),
          xls.TextCellValue(record.packageName),
          xls.DoubleCellValue(record.saleAmount),
          xls.DoubleCellValue(record.sasDeduction),
          xls.DoubleCellValue(record.profit),
          xls.TextCellValue(s?.status.label ?? ''),
          xls.DoubleCellValue(s?.collected ?? 0),
          xls.DoubleCellValue(s?.debt ?? 0),
        ]);
      }

      final encoded = excel.encode();
      if (encoded == null) throw Exception('تعذر إنشاء ملف Excel');
      final monthStamp =
          '${_month.year}${_month.month.toString().padLeft(2, '0')}';
      final savedPath = await FileSaver.instance.saveFile(
        name: 'وكيل-نت_تقرير-حسابي_$monthStamp',
        bytes: Uint8List.fromList(encoded),
        fileExtension: 'xlsx',
        mimeType: MimeType.microsoftExcel,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            savedPath.isEmpty
                ? 'تم حفظ التقرير بنجاح'
                : 'تم حفظ التقرير بنجاح:\n$savedPath',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('تعذر تصدير التقرير: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final activations = _activations;
    final sales = AccountingMonthlySummary.fromRecords(
      activations: activations,
    );
    final cash = _cashSummary(_allMonthActivations);
    final settlements = ActivationOutcome.of(activations, _monthEvents);
    final activationPages = activations.isEmpty
        ? 1
        : (activations.length / _activationsPerPage).ceil();
    final activationPage = _activationPage.clamp(1, activationPages);
    final refreshing =
        _loadingSasBalance || _loadingJournalMonth || _loadingFtthBalance;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('التقارير الحسابية'),
          foregroundColor: Colors.white,
          backgroundColor: Colors.transparent,
          elevation: 0,
          flexibleSpace: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0xFF2E7D32)),
              Image.asset(
                'assets/reference/NetAgent_Glossy_Green_3D.png',
                fit: BoxFit.cover,
                alignment: Alignment.center,
              ),
            ],
          ),
          actions: [
            IconButton(
              onPressed: _loadingJournalMonth ? null : _exportMonthlyReport,
              tooltip: 'تصدير تقرير الشهر إلى Excel',
              icon: const Icon(Icons.download_rounded),
            ),
            IconButton(
              onPressed: refreshing ? null : _refreshAll,
              tooltip: 'تحديث الأرصدة والسجلات',
              icon: refreshing
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _MonthSelector(
                  label: _monthLabel,
                  onPrevious: () => _changeMonth(-1),
                  onNext: () => _changeMonth(1),
                ),
                const SizedBox(height: 12),
                _Section(
                  title: 'مبيعات الساس والربح',
                  icon: Icons.point_of_sale_outlined,
                  children: [
                    _Figure(
                      'عدد التفعيلات',
                      '${sales.activationCount}',
                      const Color(0xFF75538F),
                    ),
                    _Figure(
                      'المبيعات',
                      _money(sales.subscriberSales),
                      const Color(0xFF2468A2),
                    ),
                    _Figure(
                      'الربح',
                      _money(sales.profit),
                      const Color(0xFF2E7D32),
                      hint:
                          'المبيعات − كلفة الساس '
                          '(${_money(sales.sasDeductions)})',
                      emphasized: true,
                    ),
                  ],
                ),
                _Section(
                  title: 'النقد المستلم',
                  icon: Icons.payments_outlined,
                  children: [
                    _Figure(
                      'واصل عند التفعيل',
                      _money(cash.activationCollected),
                      const Color(0xFF1B7F5C),
                    ),
                    _Figure(
                      'تسديد ديون',
                      _money(cash.debtPaymentsCollected),
                      const Color(0xFF1B7F5C),
                    ),
                    if (cash.otherCollected > 0.0001)
                      _Figure(
                        'واصل آخر',
                        _money(cash.otherCollected),
                        const Color(0xFF1B7F5C),
                        hint: 'مشتريات ومبالغ سُجلت مع واصلها',
                      ),
                    _Figure(
                      'المجموع المستلم',
                      _money(cash.totalCollected),
                      const Color(0xFF2E7D32),
                      emphasized: true,
                    ),
                  ],
                ),
                _Section(
                  title: 'الديون',
                  icon: Icons.account_balance_outlined,
                  children: [
                    _Figure(
                      'أُضيفت هذا الشهر',
                      _money(cash.debtAddedTotal),
                      const Color(0xFFC04A35),
                    ),
                    _Figure(
                      'سُددت هذا الشهر',
                      _money(cash.debtPaymentsCollected),
                      const Color(0xFF1B7F5C),
                    ),
                    if (cash.debtReducedTotal > 0.0001)
                      _Figure(
                        'أُسقطت هذا الشهر',
                        _money(cash.debtReducedTotal),
                        const Color(0xFF546E7A),
                      ),
                    _Figure(
                      'المتبقي الآن على المشتركين',
                      _money(_currentOutstandingDebt),
                      const Color(0xFFC04A35),
                      hint: 'يشمل ديون الأشهر السابقة',
                      emphasized: true,
                    ),
                  ],
                ),
                _Section(
                  title: 'الأرصدة',
                  icon: Icons.account_balance_wallet_outlined,
                  children: [
                    _WalletCard(
                      title: _sasAccounts.length > 1
                          ? 'رصيد الساسات (${_sasAccounts.length})'
                          : 'رصيد الساس',
                      icon: Icons.cloud_outlined,
                      colors: const [Color(0xFF1B5E20), Color(0xFF43A047)],
                      value: _loadingSasBalance && _currentSasBalance == null
                          ? '...'
                          : _currentSasBalance == null
                          ? 'غير متاح'
                          : _money(_currentSasBalance!),
                      lines: [
                        if (_sasAccounts.length > 1)
                          for (final account in _sasAccounts)
                            (
                              account.displayName,
                              _balanceOf(account.accountId) == null
                                  ? 'غير متاح'
                                  : _money(_balanceOf(account.accountId)!),
                            ),
                        (
                          'إيداعات $_monthLabel',
                          _loadingJournalMonth
                              ? '...'
                              : _monthDeposits == null
                              ? 'غير متاح'
                              : _money(_monthDeposits!),
                        ),
                        (
                          'استقطاعات $_monthLabel',
                          _loadingJournalMonth
                              ? '...'
                              : _monthDeductions == null
                              ? 'غير متاح'
                              : _money(_monthDeductions!),
                        ),
                      ],
                    ),
                    if (_ftthConfigured)
                      _WalletCard(
                        title: 'محفظة FTTH (رصيد الوكيل)',
                        icon: Icons.router_outlined,
                        colors: const [Color(0xFF0D47A1), Color(0xFF1E88E5)],
                        value: _loadingFtthBalance
                            ? '...'
                            : _ftthBalance == null
                            ? 'غير متاح'
                            : _money(_ftthBalance!),
                        lines: [
                          if (_ftthBalanceError != null)
                            ('تعذرت القراءة', 'اضغط تحديث'),
                        ],
                      ),
                  ],
                ),
                if (_journalMonthError != null)
                  _ErrorBand(
                    'تعذر احتساب حركة الشهر من سجل الساس: $_journalMonthError',
                  ),
                const SizedBox(height: 8),
                _SectionTitle(
                  icon: Icons.task_alt_rounded,
                  title: 'تفاصيل عمليات التفعيل',
                  trailing: '${activations.length}',
                ),
                const SizedBox(height: 10),
                if (activations.isEmpty)
                  const _EmptyBox('لا توجد عمليات تفعيل مسجلة لهذا الشهر')
                else ...[
                  _ListCard(
                    children: [
                      for (final record
                          in activations
                              .skip((activationPage - 1) * _activationsPerPage)
                              .take(_activationsPerPage))
                        _ActivationTile(
                          record: record,
                          settlement: settlements[record],
                          money: _money,
                          date: _dateTime(record.at),
                          onTap: () => _openSubscriber(record),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _Pager(
                    total: activations.length,
                    page: activationPage,
                    lastPage: activationPages,
                    onPage: (page) => setState(() => _activationPage = page),
                  ),
                ],
                const SizedBox(height: 28),
                if (_sasAccounts.length > 1) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final account in _sasAccounts)
                        ChoiceChip(
                          key: ValueKey('report-sas-${account.accountId}'),
                          label: Text(account.displayName),
                          selected: _reportAccount == account.accountId,
                          onSelected: (_) {
                            if (_reportAccount == account.accountId) return;
                            setState(() {
                              _reportAccount = account.accountId;
                              _financialPage = null;
                            });
                            _loadFinancialReport();
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
                _SasFinancialReports(
                  selectedType: _reportType,
                  page: _financialPage,
                  loading: _loadingFinancialReport,
                  error: _financialReportError,
                  money: _money,
                  recordedDays: _recordedActivationDays,
                  onTypeSelected: (type) => _loadFinancialReport(type: type),
                  onPageSelected: (page) => _loadFinancialReport(page: page),
                  onRefresh: () => _loadFinancialReport(
                    page: _financialPage?.currentPage ?? 1,
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.icon,
    required this.title,
    this.trailing,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? trailing;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      // العنوان يأخذ كل العرض المتبقي ويلتف لسطر ثانٍ بدل أن يُقص.
      Expanded(
        child: Row(
          children: [
            Icon(icon, size: 20, color: const Color(0xFF2E7D32)),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            ..._badge(),
          ],
        ),
      ),
      ?action,
    ],
  );

  List<Widget> _badge() => [
    if (trailing != null) ...[
      const SizedBox(width: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFFE8F5E9),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          trailing!,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: Color(0xFF2E7D32),
          ),
        ),
      ),
    ],
  ];
}

/// قسم من الأرقام: بطاقات متساوية تلتف حسب عرض الشاشة.
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(icon: icon, title: title),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = children.any((c) => c is _WalletCard);
            final columns = wide
                ? (constraints.maxWidth >= 620 ? 2 : 1)
                : constraints.maxWidth >= 900
                ? 4
                : 2;
            const spacing = 10.0;
            final width =
                (constraints.maxWidth - spacing * (columns - 1)) / columns;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final child in children)
                  SizedBox(width: width, child: child),
              ],
            );
          },
        ),
      ],
    ),
  );
}

class _Figure extends StatelessWidget {
  const _Figure(
    this.label,
    this.value,
    this.color, {
    this.hint,
    this.emphasized = false,
  });

  final String label;
  final String value;
  final Color color;
  final String? hint;
  final bool emphasized;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 92),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: emphasized
          ? color.withValues(alpha: 0.08)
          : Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(
        color: emphasized
            ? color.withValues(alpha: 0.45)
            : Theme.of(context).colorScheme.outlineVariant,
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF64748B),
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: emphasized ? 21 : 19,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        if (hint != null) ...[
          const SizedBox(height: 4),
          Text(
            hint!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
          ),
        ],
      ],
    ),
  );
}

/// بطاقة رصيد بخلفية متدرجة: الرصيد الحالي كبيراً وتحته حركة الشهر.
class _WalletCard extends StatelessWidget {
  const _WalletCard({
    required this.title,
    required this.icon,
    required this.colors,
    required this.value,
    this.lines = const [],
  });

  final String title;
  final IconData icon;
  final List<Color> colors;
  final String value;
  final List<(String, String)> lines;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 150),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: colors,
        begin: AlignmentDirectional.topStart,
        end: AlignmentDirectional.bottomEnd,
      ),
      borderRadius: BorderRadius.circular(14),
      boxShadow: [
        BoxShadow(
          color: colors.first.withValues(alpha: 0.25),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: DefaultTextStyle(
      style: const TextStyle(color: Colors.white),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.white70, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          if (lines.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Divider(color: Colors.white24, height: 1),
            const SizedBox(height: 8),
            for (final (label, amount) in lines)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                    Text(
                      amount,
                      style: const TextStyle(fontWeight: FontWeight.w800),
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

class _ListCard extends StatelessWidget {
  const _ListCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Column(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          children[i],
          if (i < children.length - 1) const Divider(height: 1, indent: 16),
        ],
      ],
    ),
  );
}

class _StatusChip extends StatelessWidget {
  const _StatusChip(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800),
    ),
  );
}

/// سطر تفعيل: من وبأي باقة، السعر والربح، وكيف دُفع.
class _ActivationTile extends StatelessWidget {
  const _ActivationTile({
    required this.record,
    required this.settlement,
    required this.money,
    required this.date,
    this.onTap,
  });

  final AccountingActivationRecord record;
  final ActivationOutcome? settlement;
  final String Function(double) money;
  final String date;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final status = settlement?.status ?? ActivationPaymentStatus.unknown;
    final statusColor = switch (status) {
      ActivationPaymentStatus.paid => const Color(0xFF2E7D32),
      ActivationPaymentStatus.partial => const Color(0xFFE65100),
      ActivationPaymentStatus.debt => const Color(0xFFC62828),
      ActivationPaymentStatus.unknown => const Color(0xFF64748B),
    };
    final name = record.subscriberName.trim().isNotEmpty
        ? record.subscriberName
        : record.subscriberUser;
    final details = [
      if (record.packageName.trim().isNotEmpty) record.packageName,
      date,
    ].join(' · ');
    final paymentNote = switch (status) {
      ActivationPaymentStatus.partial =>
        'واصل ${money(settlement!.collected)} · دين ${money(settlement!.debt)}',
      _ => null,
    };
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      if (status != ActivationPaymentStatus.unknown)
                        _StatusChip(status.label, statusColor),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    details,
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 12.5,
                    ),
                  ),
                  if (paymentNote != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        paymentNote,
                        style: TextStyle(color: statusColor, fontSize: 12.5),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  money(record.saleAmount),
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'ربح ${money(record.profit)}',
                  style: TextStyle(
                    color: record.profit < 0
                        ? const Color(0xFFC62828)
                        : const Color(0xFF2E7D32),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBand extends StatelessWidget {
  const _ErrorBand(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline_rounded),
        const SizedBox(width: 8),
        Expanded(child: Text(message)),
      ],
    ),
  );
}

class _EmptyBox extends StatelessWidget {
  const _EmptyBox(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    height: 120,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.receipt_long_outlined, size: 32),
        const SizedBox(height: 8),
        Text(message),
      ],
    ),
  );
}

/// سجلات الساس كما هي، بأسطر مقروءة بدل جدول عريض.
class _SasFinancialReports extends StatelessWidget {
  const _SasFinancialReports({
    required this.selectedType,
    required this.page,
    required this.loading,
    required this.error,
    required this.money,
    required this.recordedDays,
    required this.onTypeSelected,
    required this.onPageSelected,
    required this.onRefresh,
  });

  final SasFinancialReportType selectedType;
  final SasFinancialPage? page;
  final bool loading;
  final String? error;
  final String Function(double value) money;

  /// يوزرات التفعيلات المسجلة في التطبيق مع أيامها.
  final Map<String, List<DateTime>> recordedDays;
  final ValueChanged<SasFinancialReportType> onTypeSelected;
  final ValueChanged<int> onPageSelected;
  final VoidCallback onRefresh;

  static const _tabs = <(SasFinancialReportType, String)>[
    (SasFinancialReportType.activations, 'التفعيلات'),
    (SasFinancialReportType.managerJournal, 'حركة الرصيد'),
  ];

  dynamic _nested(Map<String, dynamic> row, String parent, String key) {
    final value = row[parent];
    return value is Map ? value[key] : null;
  }

  dynamic _first(Map<String, dynamic> row, List<String> keys) {
    for (final key in keys) {
      final value = row[key];
      if (value != null && value.toString().trim().isNotEmpty) return value;
    }
    return null;
  }

  String _text(dynamic value) => value?.toString().trim() ?? '';

  double? _number(dynamic value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString().replaceAll(',', '') ?? '');

  String _amount(dynamic value) {
    final number = _number(value);
    return number == null ? _text(value) : money(number);
  }

  /// "2026-11-05 14:20:11" ← "2026/11/05 14:20".
  String _date(dynamic value) {
    final raw = _text(value);
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${parsed.year}/${two(parsed.month)}/${two(parsed.day)} '
        '${two(parsed.hour)}:${two(parsed.minute)}';
  }

  String _operation(dynamic value) {
    switch (value?.toString().toLowerCase()) {
      case 'purchase':
        return 'استقطاع';
      case 'deposit':
      case 'recharge':
      case 'topup':
        return 'إيداع';
      case 'refund':
        return 'استرجاع';
      default:
        return _text(value);
    }
  }

  _SasRow _row(Map<String, dynamic> row) {
    switch (selectedType) {
      case SasFinancialReportType.activations:
        final username = _text(
          _nested(row, 'user_details', 'username') ??
              _first(row, const ['username', 'user_name', 'user']),
        );
        final fullName = [
          _text(
            _nested(row, 'user_details', 'firstname') ??
                _first(row, const ['firstname', 'first_name']),
          ),
          _text(
            _nested(row, 'user_details', 'lastname') ??
                _first(row, const ['lastname', 'last_name']),
          ),
        ].where((part) => part.isNotEmpty).join(' ');
        final createdAt = _first(row, const [
          'created_at',
          'activation_date',
          'date',
        ]);
        final recorded = isRecordedInApp(
          recordedDays,
          username,
          DateTime.tryParse(_text(createdAt)),
        );
        return _SasRow(
          title: fullName.isNotEmpty ? fullName : username,
          warning: recorded == false ? 'غير مسجل في التطبيق' : null,
          details: [
            _text(
              _nested(row, 'profile_details', 'name') ??
                  _first(row, const [
                    'profile_name',
                    'package_name',
                    'profile',
                  ]),
            ),
            _date(_first(row, const ['created_at', 'activation_date', 'date'])),
          ],
          amount: _amount(_first(row, const ['price', 'user_price', 'amount'])),
          tag: _text(
            _first(row, const [
              'activation_method',
              'method',
              'payment_method',
            ]),
          ),
        );
      case SasFinancialReportType.managerJournal:
        final operation = _operation(row['operation']);
        final isDeposit = operation == 'إيداع' || operation == 'استرجاع';
        final from = _text(row['cr']);
        final to = _text(row['dr']);
        return _SasRow(
          title: operation.isEmpty ? 'حركة' : operation,
          details: [
            if (from.isNotEmpty || to.isNotEmpty)
              '${from.isEmpty ? '—' : from} ← ${to.isEmpty ? '—' : to}',
            _date(row['created_at']),
          ],
          amount: _amount(row['amount']),
          amountColor: isDeposit
              ? const Color(0xFF2E7D32)
              : const Color(0xFFC62828),
          note: row['balance'] == null
              ? null
              : 'الرصيد بعدها ${_amount(row['balance'])}',
        );
      case SasFinancialReportType.managerInvoices:
      case SasFinancialReportType.userInvoices:
        final description = _text(row['description']);
        final type = _text(row['type']);
        return _SasRow(
          title: description.isNotEmpty
              ? description
              : type.isNotEmpty
              ? type
              : 'فاتورة',
          details: [
            if (_text(row['invoice_number']).isNotEmpty)
              'رقم ${_text(row['invoice_number'])}',
            if (description.isNotEmpty && type.isNotEmpty) type,
            _date(row['created_at'] ?? row['due_date']),
          ],
          amount: _amount(row['amount']),
          tag: _text(row['payment_method']),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentPage = page?.currentPage ?? 1;
    final lastPage = page?.lastPage ?? 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(
          icon: Icons.cloud_sync_outlined,
          title: 'سجلات الساس المباشرة',
          action: IconButton(
            onPressed: loading ? null : onRefresh,
            tooltip: 'تحديث السجل',
            icon: const Icon(Icons.refresh_rounded),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (type, label) in _tabs)
              ChoiceChip(
                label: Text(label),
                selected: selectedType == type,
                onSelected: loading || selectedType == type
                    ? null
                    : (_) => onTypeSelected(type),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (loading)
          const SizedBox(
            height: 160,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (error != null)
          _ErrorBand('تعذر جلب السجل من الساس: $error')
        else if (page == null || page!.rows.isEmpty)
          const _EmptyBox('لا توجد سجلات في هذه القائمة')
        else ...[
          _ListCard(children: [for (final row in page!.rows) _row(row)]),
          const SizedBox(height: 6),
          _Pager(
            total: page!.total,
            page: currentPage,
            lastPage: lastPage,
            onPage: onPageSelected,
          ),
        ],
      ],
    );
  }
}

class _SasRow extends StatelessWidget {
  const _SasRow({
    required this.title,
    required this.details,
    required this.amount,
    this.amountColor,
    this.tag = '',
    this.note,
    this.warning,
  });

  final String title;
  final List<String> details;
  final String amount;
  final Color? amountColor;
  final String tag;
  final String? note;

  /// تنبيه أحمر بجانب العنوان، مثل تفعيل في الساس لم يُسجل في التطبيق.
  final String? warning;

  @override
  Widget build(BuildContext context) {
    final line = details.where((d) => d.trim().isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    if (tag.isNotEmpty)
                      _StatusChip(tag, const Color(0xFF546E7A)),
                    if (warning != null)
                      _StatusChip(warning!, const Color(0xFFC62828)),
                  ],
                ),
                if (line.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    line,
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                amount,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                  color: amountColor,
                ),
              ),
              if (note != null) ...[
                const SizedBox(height: 3),
                Text(
                  note!,
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _MonthSelector extends StatelessWidget {
  const _MonthSelector({
    required this.label,
    required this.onPrevious,
    required this.onNext,
  });

  final String label;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: const Color(0xFFE8F5E9),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        IconButton(
          onPressed: onPrevious,
          tooltip: 'الشهر السابق',
          icon: const Icon(Icons.chevron_right_rounded),
        ),
        Expanded(
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1B5E20),
            ),
          ),
        ),
        IconButton(
          onPressed: onNext,
          tooltip: 'الشهر التالي',
          icon: const Icon(Icons.chevron_left_rounded),
        ),
      ],
    ),
  );
}

/// أرقام الصفحات مربعات في سطر واحد تحت القائمة؛ الضغط على رقم يفتح صفحته.
/// إذا كثرت الصفحات يُسحب السطر جانبياً.
class _Pager extends StatefulWidget {
  const _Pager({
    required this.total,
    required this.page,
    required this.lastPage,
    required this.onPage,
  });

  final int total;
  final int page;
  final int lastPage;
  final ValueChanged<int> onPage;

  @override
  State<_Pager> createState() => _PagerState();
}

class _PagerState extends State<_Pager> {
  final _scroll = ScrollController();
  static const _squareExtent = 44.0;

  int get total => widget.total;
  int get page => widget.page;
  int get lastPage => widget.lastPage;
  ValueChanged<int> get onPage => widget.onPage;

  @override
  void initState() {
    super.initState();
    _revealSelected();
  }

  @override
  void didUpdateWidget(_Pager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page) _revealSelected();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// يحرك سطر الأرقام أفقياً فقط حتى يكون مربع الصفحة المفتوحة في الوسط.
  void _revealSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      final target =
          (page - 1) * _squareExtent -
          (position.viewportDimension - _squareExtent) / 2;
      _scroll.animateTo(
        target.clamp(0.0, position.maxScrollExtent),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'الإجمالي: $total',
        style: const TextStyle(color: Color(0xFF64748B)),
      ),
      if (lastPage > 1) ...[
        const SizedBox(height: 8),
        SingleChildScrollView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var number = 1; number <= lastPage; number++)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: _PageSquare(
                    key: ValueKey('page-$number'),
                    number: number,
                    selected: number == page,
                    onTap: () => onPage(number),
                  ),
                ),
            ],
          ),
        ),
      ],
    ],
  );
}

class _PageSquare extends StatelessWidget {
  const _PageSquare({
    super.key,
    required this.number,
    required this.selected,
    required this.onTap,
  });

  final int number;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected
        ? const Color(0xFF2E7D32)
        : Theme.of(context).colorScheme.surface,
    borderRadius: BorderRadius.circular(8),
    child: InkWell(
      onTap: selected ? null : onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 38,
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 3),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? const Color(0xFF2E7D32)
                : Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '$number',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: selected
                  ? Colors.white
                  : Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
    ),
  );
}
