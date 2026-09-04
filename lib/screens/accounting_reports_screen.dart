import 'package:flutter/material.dart';

import '../models.dart';
import '../sas_api_service.dart';

class AccountingReportsScreen extends StatefulWidget {
  const AccountingReportsScreen({super.key});

  @override
  State<AccountingReportsScreen> createState() =>
      _AccountingReportsScreenState();
}

class _AccountingReportsScreenState extends State<AccountingReportsScreen> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  String? _sasBalance;
  bool _loadingSasBalance = false;
  SasFinancialReportType _reportType = SasFinancialReportType.managerJournal;
  SasFinancialPage? _financialPage;
  bool _loadingFinancialReport = false;
  String? _financialReportError;
  SasManagerJournalMonth? _journalMonth;
  bool _loadingJournalMonth = false;
  String? _journalMonthError;

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
      _loadFinancialReport();
      _loadJournalMonth();
    });
  }

  bool _inSelectedMonth(DateTime date) =>
      date.year == _month.year && date.month == _month.month;

  List<AccountingActivationRecord> get _activations =>
      AppStore.accountingActivations
          .where((record) => _inSelectedMonth(record.at))
          .toList()
        ..sort((a, b) => b.at.compareTo(a.at));

  AccountingMonthlySummary get _summary =>
      AccountingMonthlySummary.fromRecords(activations: _activations);

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
    });
    _loadJournalMonth();
  }

  int? _firstSasUserId() {
    for (final subscriber in AppStore.subscribers) {
      final raw = subscriber.sasId.trim().isNotEmpty
          ? subscriber.sasId.trim()
          : (subscriber.sasData['id'] ?? subscriber.sasData['user_id'] ?? '')
                .toString()
                .trim();
      final userId = int.tryParse(raw);
      if (userId != null) return userId;
    }
    return null;
  }

  Future<void> _loadSasBalance() async {
    if (_loadingSasBalance) return;
    final userId = _firstSasUserId();
    if (userId == null) return;
    setState(() => _loadingSasBalance = true);
    try {
      final settings = await SasSettings.load();
      final wallet = await SasApiService(settings).fetchDashboardWallet(userId);
      if (mounted) {
        setState(() => _sasBalance = wallet['balance']?.toString());
      }
    } catch (_) {
      if (mounted) setState(() => _sasBalance = null);
    } finally {
      if (mounted) setState(() => _loadingSasBalance = false);
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
      final settings = await SasSettings.load();
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
      _journalMonthError = null;
    });
    try {
      final settings = await SasSettings.load();
      final result = await SasApiService(
        settings,
      ).fetchManagerJournalMonth(requestedMonth);
      if (!mounted || requestedMonth != _month) return;
      setState(() => _journalMonth = result);
    } catch (error) {
      if (!mounted || requestedMonth != _month) return;
      setState(() {
        _journalMonth = null;
        _journalMonthError = error.toString();
      });
    } finally {
      if (mounted && requestedMonth == _month) {
        setState(() => _loadingJournalMonth = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    final activations = _activations;
    final balanceAdded = _journalMonth?.deposits ?? 0;
    final sasDeductions = _journalMonth?.deductions ?? 0;
    final profit = summary.profit;
    final latestSasBalance = _journalMonth?.latestBalance;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('التقارير الحسابية'),
          actions: [
            IconButton(
              onPressed: _loadingSasBalance || _loadingJournalMonth
                  ? null
                  : () {
                      _loadSasBalance();
                      _loadJournalMonth();
                    },
              tooltip: 'تحديث بيانات SAS',
              icon: _loadingSasBalance || _loadingJournalMonth
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _MonthSelector(
              label: '${_monthNames[_month.month - 1]} ${_month.year}',
              onPrevious: () => _changeMonth(-1),
              onNext: () => _changeMonth(1),
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 1000
                    ? 3
                    : constraints.maxWidth >= 620
                    ? 2
                    : 1;
                final spacing = 12.0;
                final width =
                    (constraints.maxWidth - spacing * (columns - 1)) / columns;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    _MetricTile(
                      width: width,
                      icon: Icons.add_card_rounded,
                      label: 'إجمالي إيداعات SAS',
                      value: _loadingJournalMonth
                          ? '...'
                          : _money(balanceAdded),
                      color: const Color(0xFF1B7F5C),
                    ),
                    _MetricTile(
                      width: width,
                      icon: Icons.account_balance_wallet_outlined,
                      label: 'إجمالي المبالغ المستقطعة فعلياً من SAS',
                      value: _loadingJournalMonth
                          ? '...'
                          : _money(sasDeductions),
                      color: const Color(0xFFC04A35),
                    ),
                    _MetricTile(
                      width: width,
                      icon: Icons.receipt_long_outlined,
                      label: 'إجمالي المبيعات من المشتركين',
                      value: _money(summary.subscriberSales),
                      color: const Color(0xFF2468A2),
                    ),
                    _MetricTile(
                      width: width,
                      icon: Icons.trending_up_rounded,
                      label: 'إجمالي الربح',
                      value: _loadingJournalMonth ? '...' : _money(profit),
                      color: const Color(0xFF8B6914),
                    ),
                    _MetricTile(
                      width: width,
                      icon: Icons.calculate_outlined,
                      label: 'الرصيد بعد آخر حركة في SAS',
                      value: _loadingJournalMonth
                          ? '...'
                          : latestSasBalance == null
                          ? 'غير متاح'
                          : _money(latestSasBalance),
                      color: const Color(0xFF4E5D78),
                    ),
                    _MetricTile(
                      width: width,
                      icon: Icons.task_alt_rounded,
                      label: 'عدد عمليات التفعيل',
                      value: '${summary.activationCount}',
                      color: const Color(0xFF75538F),
                    ),
                  ],
                );
              },
            ),
            if (_journalMonthError != null) ...[
              const SizedBox(height: 12),
              _JournalLoadError(message: _journalMonthError!),
            ],
            const SizedBox(height: 12),
            _SasBalanceBand(balance: _sasBalance, loading: _loadingSasBalance),
            const SizedBox(height: 24),
            _SasFinancialReports(
              selectedType: _reportType,
              page: _financialPage,
              loading: _loadingFinancialReport,
              error: _financialReportError,
              money: _money,
              onTypeSelected: (type) => _loadFinancialReport(type: type),
              onPageSelected: (page) => _loadFinancialReport(page: page),
              onRefresh: () =>
                  _loadFinancialReport(page: _financialPage?.currentPage ?? 1),
            ),
            const SizedBox(height: 24),
            Text(
              'تفاصيل عمليات التفعيل',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            if (activations.isEmpty)
              const _EmptyActivations()
            else
              Card(
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('المشترك')),
                      DataColumn(label: Text('الباقة')),
                      DataColumn(
                        label: Text('مبلغ الاشتراك (سعر البيع)'),
                        numeric: true,
                      ),
                      DataColumn(label: Text('استقطاع SAS'), numeric: true),
                      DataColumn(label: Text('الربح'), numeric: true),
                      DataColumn(label: Text('التاريخ')),
                    ],
                    rows: [
                      for (final record in activations)
                        DataRow(
                          cells: [
                            DataCell(Text(record.subscriberName)),
                            DataCell(Text(record.packageName)),
                            DataCell(Text(_money(record.saleAmount))),
                            DataCell(Text(_money(record.sasDeduction))),
                            DataCell(Text(_money(record.profit))),
                            DataCell(Text(_dateTime(record.at))),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _JournalLoadError extends StatelessWidget {
  const _JournalLoadError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline_rounded),
        const SizedBox(width: 8),
        Expanded(child: Text('تعذر احتساب الشهر من سجل SAS: $message')),
      ],
    ),
  );
}

class _SasFinancialReports extends StatelessWidget {
  const _SasFinancialReports({
    required this.selectedType,
    required this.page,
    required this.loading,
    required this.error,
    required this.money,
    required this.onTypeSelected,
    required this.onPageSelected,
    required this.onRefresh,
  });

  final SasFinancialReportType selectedType;
  final SasFinancialPage? page;
  final bool loading;
  final String? error;
  final String Function(double value) money;
  final ValueChanged<SasFinancialReportType> onTypeSelected;
  final ValueChanged<int> onPageSelected;
  final VoidCallback onRefresh;

  static const _labels = <SasFinancialReportType, String>{
    SasFinancialReportType.managerJournal: 'السجل المالي',
    SasFinancialReportType.managerInvoices: 'فواتير المدراء',
    SasFinancialReportType.activations: 'التفعيلات',
    SasFinancialReportType.userInvoices: 'فواتير المشتركين',
  };

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

  String _text(dynamic value) {
    final result = value?.toString().trim() ?? '';
    return result.isEmpty ? '—' : result;
  }

  String _amount(dynamic value) {
    final number = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    return number == null ? _text(value) : money(number);
  }

  String _operation(dynamic value) {
    switch (value?.toString().toLowerCase()) {
      case 'purchase':
        return 'استقطاع / شراء';
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

  List<String> get _columns {
    switch (selectedType) {
      case SasFinancialReportType.managerJournal:
        return const [
          'التاريخ',
          'من',
          'إلى',
          'المبلغ',
          'العملية',
          'الرصيد بعد الحركة',
        ];
      case SasFinancialReportType.managerInvoices:
        return const [
          'التاريخ',
          'رقم الفاتورة',
          'النوع',
          'المبلغ',
          'طريقة الدفع',
          'الوصف',
        ];
      case SasFinancialReportType.activations:
        return const [
          'التاريخ',
          'المشترك',
          'الاسم',
          'الباقة',
          'استقطاع SAS',
          'طريقة التفعيل',
        ];
      case SasFinancialReportType.userInvoices:
        return const [
          'رقم الفاتورة',
          'تاريخ الاستحقاق',
          'النوع',
          'المبلغ',
          'طريقة الدفع',
          'الوصف',
        ];
    }
  }

  List<String> _cells(Map<String, dynamic> row) {
    switch (selectedType) {
      case SasFinancialReportType.managerJournal:
        return [
          _text(row['created_at']),
          _text(row['cr']),
          _text(row['dr']),
          _amount(row['amount']),
          _operation(row['operation']),
          _amount(row['balance']),
        ];
      case SasFinancialReportType.managerInvoices:
        return [
          _text(row['created_at']),
          _text(row['invoice_number']),
          _text(row['type']),
          _amount(row['amount']),
          _text(row['payment_method']),
          _text(row['description']),
        ];
      case SasFinancialReportType.activations:
        final firstName = _text(
          _nested(row, 'user_details', 'firstname') ??
              _first(row, const ['firstname', 'first_name']),
        );
        final lastName = _text(
          _nested(row, 'user_details', 'lastname') ??
              _first(row, const ['lastname', 'last_name']),
        );
        return [
          _text(_first(row, const ['created_at', 'activation_date', 'date'])),
          _text(
            _nested(row, 'user_details', 'username') ??
                _first(row, const ['username', 'user_name', 'user']),
          ),
          [firstName, if (lastName != '—') lastName].join(' '),
          _text(
            _nested(row, 'profile_details', 'name') ??
                _first(row, const ['profile_name', 'package_name', 'profile']),
          ),
          _amount(_first(row, const ['price', 'user_price', 'amount'])),
          _text(
            _first(row, const [
              'activation_method',
              'method',
              'payment_method',
            ]),
          ),
        ];
      case SasFinancialReportType.userInvoices:
        return [
          _text(row['invoice_number']),
          _text(row['due_date']),
          _text(row['type']),
          _amount(row['amount']),
          _text(row['payment_method']),
          _text(row['description']),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentPage = page?.currentPage ?? 1;
    final lastPage = page?.lastPage ?? 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'سجلات SAS المباشرة',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            IconButton(
              onPressed: loading ? null : onRefresh,
              tooltip: 'تحديث السجل',
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final type in SasFinancialReportType.values)
              ChoiceChip(
                label: Text(_labels[type]!),
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
            height: 180,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (error != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('تعذر جلب السجل من SAS: $error'),
          )
        else if (page == null)
          const SizedBox(
            height: 120,
            child: Center(child: Text('لا توجد سجلات في هذه القائمة')),
          )
        else ...[
          if (page!.rows.isEmpty)
            const SizedBox(
              height: 120,
              child: Center(child: Text('لا توجد سجلات في هذه الصفحة')),
            )
          else
            Card(
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: [
                    for (final column in _columns)
                      DataColumn(label: Text(column)),
                  ],
                  rows: [
                    for (final row in page!.rows)
                      DataRow(
                        cells: [
                          for (final value in _cells(row))
                            DataCell(
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 240,
                                ),
                                child: Text(
                                  value,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text('الإجمالي: ${page!.total}'),
              const Spacer(),
              IconButton(
                onPressed: currentPage > 1
                    ? () => onPageSelected(currentPage - 1)
                    : null,
                tooltip: 'الصفحة السابقة',
                icon: const Icon(Icons.chevron_right_rounded),
              ),
              Text('$currentPage / $lastPage'),
              IconButton(
                onPressed: currentPage < lastPage
                    ? () => onPageSelected(currentPage + 1)
                    : null,
                tooltip: 'الصفحة التالية',
                icon: const Icon(Icons.chevron_left_rounded),
              ),
            ],
          ),
        ],
      ],
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
  Widget build(BuildContext context) => Row(
    children: [
      IconButton(
        onPressed: onNext,
        tooltip: 'الشهر التالي',
        icon: const Icon(Icons.chevron_right_rounded),
      ),
      Expanded(
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
        ),
      ),
      IconButton(
        onPressed: onPrevious,
        tooltip: 'الشهر السابق',
        icon: const Icon(Icons.chevron_left_rounded),
      ),
    ],
  );
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.width,
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final double width;
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: 112,
    child: Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(icon, color: color, size: 30),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 6),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      value,
                      style: TextStyle(
                        color: color,
                        fontSize: 21,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SasBalanceBand extends StatelessWidget {
  const _SasBalanceBand({required this.balance, required this.loading});

  final String? balance;
  final bool loading;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        const Icon(Icons.cloud_done_outlined),
        const SizedBox(width: 12),
        const Expanded(
          child: Text(
            'الرصيد الحقيقي في SAS',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        Text(
          loading ? '...' : (balance ?? 'غير متاح'),
          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
        ),
      ],
    ),
  );
}

class _EmptyActivations extends StatelessWidget {
  const _EmptyActivations();

  @override
  Widget build(BuildContext context) => Container(
    height: 150,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(8),
    ),
    child: const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.receipt_long_outlined, size: 36),
        SizedBox(height: 8),
        Text('لا توجد عمليات تفعيل مسجلة لهذا الشهر'),
      ],
    ),
  );
}
