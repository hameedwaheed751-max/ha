import 'dart:convert';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models.dart';
import 'add_subscriber_screen.dart';
import 'receipt_screen.dart';

class SubscriberDetailsScreen extends StatefulWidget {
  final Subscriber subscriber;
  const SubscriberDetailsScreen({super.key, required this.subscriber});

  @override
  State<SubscriberDetailsScreen> createState() => _SubscriberDetailsScreenState();
}

class _SubscriberDetailsScreenState extends State<SubscriberDetailsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController tabs;
  Subscriber get s => widget.subscriber;
  String _invoiceMonthFilter = 'all';
  String _paymentMonthFilter = 'all';

  String f(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  String _monthLabel(String monthKey) {
    final parts = monthKey.split('-');
    if (parts.length != 2) return monthKey;
    final y = parts[0];
    final m = int.tryParse(parts[1]) ?? 0;
    const names = <String>[
      'يناير',
      'فبراير',
      'مارس',
      'ابريل',
      'مايو',
      'يونيو',
      'يوليو',
      'اغسطس',
      'سبتمبر',
      'اكتوبر',
      'نوفمبر',
      'ديسمبر',
    ];
    if (m < 1 || m > 12) return monthKey;
    return '${names[m - 1]} $y';
  }

  List<InvoiceRecord> _sortedInvoices() {
    final list = List<InvoiceRecord>.from(s.invoices);
    list.sort((a, b) => b.at.compareTo(a.at));
    return list;
  }

  List<PaymentRecord> _sortedPayments() {
    final list = List<PaymentRecord>.from(s.payments);
    list.sort((a, b) => b.at.compareTo(a.at));
    return list;
  }

  List<String> _invoiceMonthOptions() {
    final keys = s.invoices.map((e) => e.monthKey).toSet().toList()..sort((a, b) => b.compareTo(a));
    return <String>['all', ...keys];
  }

  List<String> _paymentMonthOptions() {
    final keys = s.payments
        .map((e) => Subscriber.monthKeyOf(e.at))
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));
    return <String>['all', ...keys];
  }

  String _csvCell(String value) {
    final escaped = value.replaceAll('"', '""');
    return '"$escaped"';
  }

  Future<void> _exportInvoicesCsv(List<InvoiceRecord> invoices, String monthFilter) async {
    if (invoices.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد فواتير للتصدير حسب الفلتر المختار')),
      );
      return;
    }

    try {
      final lines = <String>[
        'receipt_number,date,month,amount,note',
        ...invoices.map((inv) {
          final date = f(inv.at);
          final month = _monthLabel(inv.monthKey);
          return [
            inv.receiptNumber.toString(),
            _csvCell(date),
            _csvCell(month),
            inv.amount.toStringAsFixed(0),
            _csvCell(inv.note),
          ].join(',');
        }),
      ];

      final csv = '\uFEFF${lines.join('\n')}';
      final bytes = Uint8List.fromList(utf8.encode(csv));
      final sanitizedUser = s.user.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final suffix = monthFilter == 'all' ? 'all' : monthFilter;

      await FileSaver.instance.saveFile(
        name: 'invoices_${sanitizedUser}_$suffix',
        bytes: bytes,
        fileExtension: 'csv',
        mimeType: MimeType.csv,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تصدير الفواتير بنجاح')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر تصدير الملف، حاول مرة أخرى')),
      );
    }
  }

  Future<void> _exportPaymentsCsv(List<PaymentRecord> payments, String monthFilter) async {
    if (payments.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لا توجد مدفوعات للتصدير حسب الفلتر المختار')),
      );
      return;
    }

    try {
      final lines = <String>[
        'date,month,amount,note',
        ...payments.map((p) {
          final date = f(p.at);
          final month = _monthLabel(Subscriber.monthKeyOf(p.at));
          return [
            _csvCell(date),
            _csvCell(month),
            p.amount.toStringAsFixed(0),
            _csvCell(p.note),
          ].join(',');
        }),
      ];

      final csv = '\uFEFF${lines.join('\n')}';
      final bytes = Uint8List.fromList(utf8.encode(csv));
      final sanitizedUser = s.user.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final suffix = monthFilter == 'all' ? 'all' : monthFilter;

      await FileSaver.instance.saveFile(
        name: 'payments_${sanitizedUser}_$suffix',
        bytes: bytes,
        fileExtension: 'csv',
        mimeType: MimeType.csv,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم تصدير المدفوعات بنجاح')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر تصدير الملف، حاول مرة أخرى')),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    tabs = TabController(length: 6, vsync: this);
  }

  @override
  void dispose() {
    tabs.dispose();
    super.dispose();
  }

  dynamic _pick(List<String> keys) {
    for (final key in keys) {
      final v = s.sasData[key];
      if (v != null && v.toString().trim().isNotEmpty) return v;
    }
    return null;
  }

  String _sas(List<String> keys, [String fallback = '—']) {
    final v = _pick(keys);
    return v == null ? fallback : v.toString();
  }

  String _bytes(dynamic value) {
    if (value == null) return '—';
    final n = double.tryParse(value.toString());
    if (n == null) return value.toString();
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var x = n;
    var i = 0;
    while (x >= 1024 && i < units.length - 1) {
      x /= 1024;
      i++;
    }
    return '${x.toStringAsFixed(i == 0 ? 0 : 2)} ${units[i]}';
  }

  Widget infoRow(String label, String value, IconData icon, {Color? valueColor, VoidCallback? onTap}) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: const Color(0xFFE0E0E0)),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF607D8B), size: 21),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: TextStyle(color: Colors.grey.shade700))),
            Flexible(
              child: onTap == null
                  ? Text(
                      value.isEmpty ? '—' : value,
                      textAlign: TextAlign.left,
                      style: TextStyle(fontWeight: FontWeight.w600, color: valueColor),
                    )
                  : InkWell(
                      onTap: onTap,
                      child: Text(
                        value.isEmpty ? '—' : value,
                        textAlign: TextAlign.left,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: valueColor ?? Colors.blue,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      );

  Widget emptyTab(IconData icon, String title, String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 58, color: Colors.blueGrey.shade300),
              const SizedBox(height: 12),
              Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(text, textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade600)),
            ],
          ),
        ),
      );




  @override
  Widget build(BuildContext context) {
    final status = s.disabled ? 'معطل' : s.isActive ? 'فعال' : 'منتهي';
    final online = s.isOnline;
    Color statusColor;
    if (s.disabled) {
      statusColor = Colors.orange;
    } else if (s.endDate.isBefore(DateTime.now())) {
      statusColor = online ? Colors.red : Colors.orange;
    } else {
      statusColor = online ? Colors.blue : Colors.green;
    }
    final isSas = s.source == 'sas';

    final lastConnection = _sas([
      'last_connection', 'last_seen', 'last_login', 'last_online',
      'last_auth', 'last_activity', 'last_connection_date'
    ]);
    final download = _bytes(_pick([
      'download', 'downloaded', 'total_download', 'download_bytes',
      'acct_output_octets', 'output_octets'
    ]));
    final upload = _bytes(_pick([
      'upload', 'uploaded', 'total_upload', 'upload_bytes',
      'acct_input_octets', 'input_octets'
    ]));
    final remainingData = _bytes(_pick([
      'remaining_data', 'data_remaining', 'remaining_traffic', 'traffic_left'
    ]));

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F7F9),
        appBar: AppBar(title: const Text('معلومات المشترك'), centerTitle: true),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
              color: const Color(0xFF34434D),
              child: Row(
                children: [
                  const CircleAvatar(radius: 34, child: Icon(Icons.person, size: 40)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s.name, style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 3),
                        Text(s.user, style: const TextStyle(color: Colors.white70)),
                        const SizedBox(height: 7),
                        Wrap(
                          spacing: 8,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(20)),
                              child: Text(status, style: TextStyle(color: statusColor, fontWeight: FontWeight.bold)),
                            ),
                            if (isSas)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(20)),
                                child: const Text('SAS', style: TextStyle(color: Colors.lightBlueAccent, fontWeight: FontWeight.bold)),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Material(
              color: Colors.white,
              child: TabBar(
                controller: tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: const [
                  Tab(text: 'عام'),
                  Tab(text: 'تعديل'),
                  Tab(text: 'الاستهلاك'),
                  Tab(text: 'الجلسات'),
                  Tab(text: 'فواتير'),
                  Tab(text: 'مدفوعات'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: tabs,
                children: [
                  ListView(
                    padding: const EdgeInsets.all(14),
                    children: [
                      infoRow('اسم الدخول', s.user, Icons.person_outline),
                      infoRow('رقم الهاتف', s.phone, Icons.phone_outlined),
                      infoRow('العنوان', s.address, Icons.location_on_outlined),
                      infoRow(
                        'IP',
                        s.ip,
                        Icons.language,
                        valueColor: Colors.blue,
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
                      ),
                      infoRow('الباقة', s.packageDisplay, Icons.inventory_2_outlined),
                      infoRow('تاريخ الانتهاء', f(s.endDate), Icons.event_outlined),
                      infoRow('الحالة', _sas(['status', 'state', 'user_status'], status), Icons.info_outline),
                      if (isSas) infoRow('معرف SAS', s.sasId, Icons.fingerprint),
                      if (isSas) infoRow('تابع إلى', _sas(['parent_name','parent','manager_name','reseller_name']), Icons.account_tree_outlined),
                      if (isSas) infoRow('الأيام المقترضة', _sas(['loan_days','borrowed_days','debt_days'], '0'), Icons.calendar_month_outlined),
                      if (isSas) infoRow('آخر اتصال', lastConnection, Icons.history),
                    ],
                  ),
                  Center(
                    child: FilledButton.icon(
                      onPressed: () async {
                        final changed = await Navigator.push<bool>(
                          context,
                          MaterialPageRoute(builder: (_) => AddSubscriberScreen(subscriber: s)),
                        );
                        if (changed == true && mounted) setState(() {});
                      },
                      icon: const Icon(Icons.edit),
                      label: const Text('تعديل بيانات المشترك'),
                    ),
                  ),
                  ListView(
                    padding: const EdgeInsets.all(14),
                    children: [
                      infoRow('الداونلود', download, Icons.download),
                      infoRow('الأبلود', upload, Icons.upload),
                      infoRow('كمية البيانات المتبقية', remainingData, Icons.data_usage),
                      infoRow('آخر اتصال', lastConnection, Icons.schedule),
                    ],
                  ),
                  isSas
                      ? ListView(
                          padding: const EdgeInsets.all(14),
                          children: [
                            infoRow('آخر اتصال', lastConnection, Icons.router_outlined),
                            infoRow(
                              'IP',
                              s.ip,
                              Icons.language,
                              valueColor: Colors.blue,
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
                            ),
                            infoRow('NAS', _sas(['nas_name','nas','router_name']), Icons.dns_outlined),
                            infoRow('MAC', _sas(['mac','mac_address','calling_station_id']), Icons.devices),
                            infoRow('مدة الجلسة', _sas(['session_time','acct_session_time','online_time']), Icons.timer_outlined),
                          ],
                        )
                      : emptyTab(Icons.router_outlined, 'الجلسات', 'لا توجد بيانات جلسات للمشترك المحلي.'),
                  Builder(
                    builder: (_) {
                      final allInvoices = _sortedInvoices();
                      final options = _invoiceMonthOptions();
                      final effectiveFilter = options.contains(_invoiceMonthFilter) ? _invoiceMonthFilter : 'all';
                      final invoices = effectiveFilter == 'all'
                          ? allInvoices
                          : allInvoices.where((inv) => inv.monthKey == effectiveFilter).toList();

                      final monthlyTotals = <String, double>{};
                      for (final inv in invoices) {
                        monthlyTotals[inv.monthKey] = (monthlyTotals[inv.monthKey] ?? 0) + inv.amount;
                      }
                      final monthlyInvoices = monthlyTotals.entries.toList()
                        ..sort((a, b) => b.key.compareTo(a.key));

                      return ListView(
                        padding: const EdgeInsets.all(14),
                        children: [
                          infoRow('مبلغ الاشتراك', s.price.toStringAsFixed(0), Icons.receipt_long_outlined),
                          infoRow('الواصل', s.paid.toStringAsFixed(0), Icons.payments_outlined),
                          infoRow('المتبقي', s.remaining.toStringAsFixed(0), Icons.money_off_outlined),
                          infoRow('تاريخ التفعيل', f(s.startDate), Icons.event_outlined),
                          infoRow('تاريخ التسديد', s.paymentDate.isEmpty ? 'غير محدد' : s.paymentDate, Icons.event_available_outlined),
                          if (isSas) infoRow('رصيد SAS', _sas(['balance','credit','user_balance']), Icons.account_balance_wallet_outlined),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  initialValue: effectiveFilter,
                                  decoration: const InputDecoration(
                                    labelText: 'فلتر الشهر',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  items: options
                                      .map(
                                        (key) => DropdownMenuItem<String>(
                                          value: key,
                                          child: Text(key == 'all' ? 'الكل' : _monthLabel(key)),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (value) {
                                    setState(() {
                                      _invoiceMonthFilter = value ?? 'all';
                                    });
                                  },
                                ),
                              ),
                              const SizedBox(width: 10),
                              FilledButton.icon(
                                onPressed: () => _exportInvoicesCsv(invoices, effectiveFilter),
                                icon: const Icon(Icons.download_outlined),
                                label: const Text('تصدير'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Text('الفواتير الشهرية', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 8),
                          if (monthlyInvoices.isEmpty)
                            const Text('لا توجد فواتير مسجلة بعد')
                          else
                            ...monthlyInvoices.map(
                              (e) => Card(
                                child: ListTile(
                                  leading: const Icon(Icons.calendar_month),
                                  title: Text(_monthLabel(e.key)),
                                  trailing: Text('${e.value.toStringAsFixed(0)} د.ع', style: const TextStyle(fontWeight: FontWeight.bold)),
                                ),
                              ),
                            ),
                          const SizedBox(height: 8),
                          const Text('سجل الفواتير', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 8),
                          if (invoices.isEmpty)
                            const Text('لا يوجد سجل فواتير حتى الآن')
                          else
                            ...invoices.map(
                              (inv) => Card(
                                child: ListTile(
                                  leading: const CircleAvatar(child: Icon(Icons.receipt_long_outlined)),
                                  title: Text('وصل رقم ${inv.receiptNumber.toString().padLeft(6, '0')}'),
                                  subtitle: Text('${f(inv.at)} • ${_monthLabel(inv.monthKey)}${inv.note.isEmpty ? '' : ' • ${inv.note}'}'),
                                  trailing: Text('${inv.amount.toStringAsFixed(0)} د.ع', style: const TextStyle(fontWeight: FontWeight.bold)),
                                  onTap: () async {
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ReceiptScreen(
                                          subscriber: s,
                                          invoice: inv,
                                        ),
                                      ),
                                    );
                                    if (mounted) setState(() {});
                                  },
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  Builder(
                    builder: (_) {
                      final allPayments = _sortedPayments();
                      final options = _paymentMonthOptions();
                      final effectiveFilter = options.contains(_paymentMonthFilter) ? _paymentMonthFilter : 'all';
                      final payments = effectiveFilter == 'all'
                          ? allPayments
                          : allPayments
                              .where((p) => Subscriber.monthKeyOf(p.at) == effectiveFilter)
                              .toList();

                      final monthlyTotals = <String, double>{};
                      for (final p in payments) {
                        final key = Subscriber.monthKeyOf(p.at);
                        monthlyTotals[key] = (monthlyTotals[key] ?? 0) + p.amount;
                      }
                      final monthlyPaid = monthlyTotals.entries.toList()
                        ..sort((a, b) => b.key.compareTo(a.key));

                      return ListView(
                        padding: const EdgeInsets.all(14),
                        children: [
                          infoRow('الواصل الإجمالي', s.paid.toStringAsFixed(0), Icons.price_check_outlined),
                          infoRow('تاريخ التسديد', s.paymentDate.isEmpty ? 'غير محدد' : s.paymentDate, Icons.event_available_outlined),
                          if (isSas) infoRow('آخر دفعة SAS', _sas(['last_payment','last_payment_date','payment_date']), Icons.payments_outlined),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  initialValue: effectiveFilter,
                                  decoration: const InputDecoration(
                                    labelText: 'فلتر الشهر',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  items: options
                                      .map(
                                        (key) => DropdownMenuItem<String>(
                                          value: key,
                                          child: Text(key == 'all' ? 'الكل' : _monthLabel(key)),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (value) {
                                    setState(() {
                                      _paymentMonthFilter = value ?? 'all';
                                    });
                                  },
                                ),
                              ),
                              const SizedBox(width: 10),
                              FilledButton.icon(
                                onPressed: () => _exportPaymentsCsv(payments, effectiveFilter),
                                icon: const Icon(Icons.download_outlined),
                                label: const Text('تصدير'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Text('المدفوعات حسب الأشهر', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 8),
                          if (monthlyPaid.isEmpty)
                            const Text('لا توجد مدفوعات مسجلة بعد')
                          else
                            ...monthlyPaid.map(
                              (e) => Card(
                                child: ListTile(
                                  leading: const Icon(Icons.calendar_today_outlined),
                                  title: Text(_monthLabel(e.key)),
                                  trailing: Text('${e.value.toStringAsFixed(0)} د.ع', style: const TextStyle(fontWeight: FontWeight.bold)),
                                ),
                              ),
                            ),
                          const SizedBox(height: 8),
                          const Text('سجل المدفوعات', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 8),
                          if (payments.isEmpty)
                            const Text('لا يوجد سجل دفعات حتى الآن')
                          else
                            ...payments.map(
                              (p) => Card(
                                child: ListTile(
                                  leading: const CircleAvatar(child: Icon(Icons.payments_outlined)),
                                  title: Text('${p.amount.toStringAsFixed(0)} د.ع', style: const TextStyle(fontWeight: FontWeight.bold)),
                                  subtitle: Text('${f(p.at)} • ${_monthLabel(Subscriber.monthKeyOf(p.at))}${p.note.isEmpty ? '' : ' • ${p.note}'}'),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
