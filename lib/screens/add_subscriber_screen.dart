import 'package:flutter/material.dart';
import '../models.dart';
import '../sas_api_service.dart';

class AddSubscriberScreen extends StatefulWidget {
  final Subscriber? subscriber;
  const AddSubscriberScreen({super.key, this.subscriber});

  @override
  State<AddSubscriberScreen> createState() => _AddSubscriberScreenState();
}

class _AddSubscriberScreenState extends State<AddSubscriberScreen> {
  final user = TextEditingController();
  final name = TextEditingController();
  final phone = TextEditingController();
  final address = TextEditingController();
  final ip = TextEditingController();
  final type = TextEditingController();
  final price = TextEditingController();
  final paid = TextEditingController();
  final start = TextEditingController();
  final end = TextEditingController();
  final notes = TextEditingController();
  final paymentDate = TextEditingController();
  final sasPassword = TextEditingController();
  final sasProfileId = TextEditingController();
  final sasParentId = TextEditingController();
  DateTime? startDate;
  DateTime? endDate;
  bool loadingSasLists = false;
  String? sasListsError;
  List<Map<String, dynamic>> sasProfiles = [];
  List<Map<String, dynamic>> sasParents = [];
  int? selectedProfileId;
  int? selectedParentId;

  String fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  String _pickSasValue(
    Map<String, dynamic> data,
    List<String> keys, [
    String fallback = '',
  ]) {
    for (final key in keys) {
      final value = data[key];
      if (value != null && value.toString().trim().isNotEmpty) {
        return value.toString().trim();
      }
    }
    return fallback;
  }

  DateTime? _parseDateValue(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    return DateTime.tryParse(value.toString());
  }

  void _populateFromSubscriber(Subscriber? s) {
    if (s == null) return;
    final data = Map<String, dynamic>.from(s.sasData);

    user.text = _pickSasValue(data, ['username', 'user', 'login'], s.user);
    final rawName = _pickSasValue(data, [
      'fullname',
      'full_name',
      'name',
      'customer_name',
    ], s.name);
    name.text = rawName;
    phone.text = _pickSasValue(data, [
      'phone',
      'phone_number',
      'mobile',
      'contact_phone',
    ], s.phone);
    address.text = _pickSasValue(data, [
      'address',
      'street',
      'full_address',
    ], s.address);
    ip.text = _pickSasValue(data, ['ip', 'ip_address', 'nas_ip'], s.ip);
    type.text = _pickSasValue(data, [
      'profile_name',
      'package',
      'plan',
      'service_profile',
      'type',
    ], s.type);
    notes.text = _pickSasValue(data, [
      'notes',
      'comment',
      'remark',
      'description',
    ], s.notes);
    price.text = s.price.toStringAsFixed(0);
    paid.text = s.paid.toStringAsFixed(0);
    paymentDate.text = s.paymentDate;

    startDate =
        _parseDateValue(
          _pickSasValue(data, [
            'start_date',
            'start',
            'activation_date',
            'created',
            'activated_at',
            'from_date',
          ], ''),
        ) ??
        s.startDate;
    endDate =
        _parseDateValue(
          _pickSasValue(data, [
            'end_date',
            'expiration',
            'expiration_date',
            'expires_at',
            'finish_date',
            'date_end',
          ], ''),
        ) ??
        s.endDate;

    start.text = fmt(startDate!);
    end.text = fmt(endDate!);
  }

  @override
  void initState() {
    super.initState();
    final s = widget.subscriber;
    if (s != null) {
      _populateFromSubscriber(s);
    } else {
      startDate = DateTime.now();
      endDate = DateTime.now().add(const Duration(days: 30));
      start.text = fmt(startDate!);
      end.text = fmt(endDate!);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) loadSasLists();
      });
    }
  }

  @override
  void dispose() {
    for (final c in [
      user,
      name,
      phone,
      address,
      ip,
      type,
      price,
      paid,
      start,
      end,
      notes,
      paymentDate,
      sasPassword,
      sasProfileId,
      sasParentId,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  int? _idOf(Map<String, dynamic> m) {
    for (final key in [
      'id',
      'manager_id',
      'parent_id',
      'profile_id',
      'user_id',
    ]) {
      final v = m[key];
      final n = int.tryParse(v?.toString() ?? '');
      if (n != null) return n;
    }
    return null;
  }

  String _labelOf(Map<String, dynamic> m) {
    for (final key in [
      'name',
      'username',
      'manager_name',
      'profile_name',
      'fullname',
      'title',
    ]) {
      final v = m[key];
      if (v != null && v.toString().trim().isNotEmpty)
        return v.toString().trim();
    }
    return 'ID ${_idOf(m) ?? '-'}';
  }

  Future<void> loadSasLists() async {
    if (loadingSasLists) return;
    setState(() {
      loadingSasLists = true;
      sasListsError = null;
    });
    try {
      final settings = await SasSettings.load();
      final api = SasApiService(settings);

      // manager endpoint gives the available/current parent.
      final parents = await api.fetchParents();
      int managerId = 5;
      for (final p in parents) {
        final id = _idOf(p);
        if (id != null) {
          managerId = id;
          break;
        }
      }

      final profiles = await api.fetchProfiles(managerId: managerId);
      if (!mounted) return;
      setState(() {
        sasParents = parents.where((e) => _idOf(e) != null).toList();
        sasProfiles = profiles.where((e) => _idOf(e) != null).toList();
        if (sasParents.length == 1) selectedParentId = _idOf(sasParents.first);
        loadingSasLists = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loadingSasLists = false;
        sasListsError = e.toString();
      });
    }
  }

  Future<void> pick(bool isStart) async {
    final d = await showDatePicker(
      context: context,
      initialDate: (isStart ? startDate : endDate) ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d == null) return;
    setState(() {
      if (isStart) {
        startDate = d;
        start.text = fmt(d);
      } else {
        endDate = d;
        end.text = fmt(d);
      }
    });
  }

  InputDecoration dec(String s, IconData icon) {
    final colors = Theme.of(context).colorScheme;
    return InputDecoration(
      labelText: s,
      labelStyle: TextStyle(color: colors.onSurfaceVariant),
      floatingLabelStyle: TextStyle(color: colors.primary),
      prefixIcon: Icon(icon, color: colors.onSurfaceVariant),
      filled: true,
      fillColor: colors.surfaceContainerHighest,
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
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.subscriber == null ? 'إضافة مشترك' : 'تعديل مشترك'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: user,
              textAlign: TextAlign.right,
              decoration: dec('اليوزر', Icons.person_outline),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: name,
              textAlign: TextAlign.right,
              decoration: dec('اسم المشترك', Icons.badge_outlined),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              textAlign: TextAlign.right,
              decoration: dec(
                'رقم الهاتف المرتبط بواتساب',
                Icons.phone_outlined,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: address,
              textAlign: TextAlign.right,
              decoration: dec('العنوان', Icons.location_on_outlined),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ip,
              textAlign: TextAlign.right,
              decoration: dec('IP', Icons.language),
            ),
            const SizedBox(height: 12),
            AppStore.packages.isEmpty
                ? TextField(
                    controller: type,
                    textAlign: TextAlign.right,
                    decoration: dec('نوع الاشتراك', Icons.inventory_2_outlined),
                  )
                : DropdownButtonFormField<String>(
                    initialValue:
                        AppStore.packages.any((p) => p.name == type.text)
                        ? type.text
                        : null,
                    decoration: dec('اختر الباقة', Icons.inventory_2_outlined),
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
                    items: AppStore.packages
                        .map(
                          (p) => DropdownMenuItem(
                            value: p.name,
                            child: Text(
                              '${p.name} - ${p.price.toStringAsFixed(0)}',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      final p = AppStore.packages.firstWhere(
                        (x) => x.name == v,
                      );
                      setState(() {
                        type.text = p.name;
                        price.text = p.price.toStringAsFixed(0);
                      });
                    },
                  ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: price,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.right,
                    decoration: dec('مبلغ الاشتراك', Icons.payments_outlined),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: paid,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.right,
                    decoration: dec(
                      'المبلغ المدفوع',
                      Icons.price_check_outlined,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: paymentDate,
              textAlign: TextAlign.right,
              decoration: dec('تاريخ التسديد', Icons.event_available_outlined),
            ),
            const SizedBox(height: 12),
            if (widget.subscriber == null) ...[
              const Divider(height: 28),
              const Align(
                alignment: Alignment.centerRight,
                child: Text(
                  'إضافة إلى SAS (اختياري)',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: sasPassword,
                obscureText: true,
                textAlign: TextAlign.right,
                decoration: dec('كلمة مرور SAS', Icons.lock_outline),
              ),
              const SizedBox(height: 12),
              if (loadingSasLists)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(),
                )
              else ...[
                DropdownButtonFormField<int>(
                  initialValue: selectedProfileId,
                  decoration: dec('اختر باقة SAS', Icons.inventory_2_outlined),
                  dropdownColor: Theme.of(context).colorScheme.surfaceContainer,
                  iconEnabledColor: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                  items: sasProfiles
                      .map(
                        (p) => DropdownMenuItem<int>(
                          value: _idOf(p),
                          child: Text(_labelOf(p)),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => selectedProfileId = v),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: selectedParentId,
                  decoration: dec('اختر Parent', Icons.account_tree_outlined),
                  dropdownColor: Theme.of(context).colorScheme.surfaceContainer,
                  iconEnabledColor: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                  items: sasParents
                      .map(
                        (p) => DropdownMenuItem<int>(
                          value: _idOf(p),
                          child: Text(_labelOf(p)),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => selectedParentId = v),
                ),
              ],
              if (sasListsError != null) ...[
                const SizedBox(height: 8),
                Text(
                  'تعذر جلب قوائم SAS: $sasListsError',
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
                TextButton.icon(
                  onPressed: loadSasLists,
                  icon: const Icon(Icons.refresh),
                  label: const Text('إعادة المحاولة'),
                ),
              ],
              const SizedBox(height: 8),
              const Text(
                'اختر الباقة والـ Parent من القوائم الحقيقية القادمة من SAS.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: start,
              readOnly: true,
              onTap: () => pick(true),
              decoration: dec(
                'تاريخ بداية الاشتراك',
                Icons.calendar_today_outlined,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: end,
              readOnly: true,
              onTap: () => pick(false),
              decoration: dec('تاريخ انتهاء الاشتراك', Icons.event_outlined),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: notes,
              maxLines: 3,
              textAlign: TextAlign.right,
              decoration: dec('ملاحظات', Icons.notes),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                icon: const Icon(Icons.save),
                label: const Text('حفظ المشترك'),
                onPressed: () async {
                  if (user.text.trim().isEmpty ||
                      name.text.trim().isEmpty ||
                      startDate == null ||
                      endDate == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('أكمل اليوزر والاسم والتواريخ'),
                      ),
                    );
                    return;
                  }
                  if (endDate!.isBefore(startDate!)) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'تاريخ الانتهاء يجب أن يكون بعد تاريخ البداية',
                        ),
                      ),
                    );
                    return;
                  }
                  final duplicate = AppStore.subscribers.any(
                    (x) =>
                        x.user.toLowerCase() ==
                            user.text.trim().toLowerCase() &&
                        !identical(x, widget.subscriber),
                  );
                  if (duplicate) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('هذا اليوزر موجود مسبقاً')),
                    );
                    return;
                  }
                  final p = double.tryParse(price.text) ?? 0;
                  final pd = double.tryParse(paid.text) ?? 0;
                  if (p < 0 || pd < 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'مبالغ الاشتراك والواصل يجب أن تكون أرقاماً موجبة',
                        ),
                      ),
                    );
                    return;
                  }
                  if (pd > p) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'الواصل لا يمكن أن يكون أكبر من مبلغ الاشتراك',
                        ),
                      ),
                    );
                    return;
                  }
                  if (widget.subscriber == null) {
                    final wantsSas =
                        sasPassword.text.isNotEmpty ||
                        selectedProfileId != null ||
                        selectedParentId != null;
                    if (wantsSas) {
                      final profileId = selectedProfileId;
                      final parentId = selectedParentId;
                      if (sasPassword.text.isEmpty ||
                          profileId == null ||
                          parentId == null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'لإضافة المشترك إلى SAS أكمل كلمة المرور واختر الباقة والـ Parent',
                            ),
                          ),
                        );
                        return;
                      }
                      try {
                        final settings = await SasSettings.load();
                        final api = SasApiService(settings);
                        final parts = name.text.trim().split(RegExp(r'\s+'));
                        final firstName = parts.isEmpty
                            ? name.text.trim()
                            : parts.first;
                        final lastName = parts.length > 1
                            ? parts.sublist(1).join(' ')
                            : '-';
                        await api.createUser(
                          username: user.text.trim(),
                          password: sasPassword.text,
                          profileId: profileId,
                          parentId: parentId,
                          firstName: firstName,
                          lastName: lastName,
                        );
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('فشل إنشاء المشترك في SAS: $e'),
                            ),
                          );
                        }
                        return;
                      }
                    }
                    final subscriber = Subscriber(
                      user: user.text.trim(),
                      name: name.text.trim(),
                      phone: phone.text.trim(),
                      address: address.text.trim(),
                      ip: ip.text.trim(),
                      type: type.text.trim(),
                      price: p,
                      paid: 0,
                      startDate: startDate!,
                      endDate: endDate!,
                      notes: notes.text.trim(),
                      paymentDate: paymentDate.text.trim(),
                    );
                    subscriber.adjustPaidToTarget(
                      pd,
                      at: DateTime.now(),
                      increaseNote: 'رصيد افتتاحي للمشترك الجديد',
                      decreaseNote: 'تصحيح رصيد افتتاحي للمشترك الجديد',
                    );
                    if (subscriber.paymentDate.isEmpty && pd > 0) {
                      subscriber.paymentDate = paymentDate.text.trim().isEmpty
                          ? fmt(DateTime.now())
                          : paymentDate.text.trim();
                    }
                    AppStore.subscribers.add(subscriber);
                  } else {
                    final s = widget.subscriber!;
                    final oldPrice = s.price;
                    final oldPaid = s.paid;
                    final oldRemaining = s.remaining;

                    // إذا كان المشترك قادماً من SAS: نرسل PUT الحقيقي أولاً.
                    // لا نحفظ التعديل محلياً إذا رفضه الخادم.
                    if (s.source == 'sas' && s.sasId.trim().isNotEmpty) {
                      try {
                        final settings = await SasSettings.load();
                        final api = SasApiService(settings);
                        final requestedName = name.text.trim();
                        final explicitNameChangedInApp =
                            requestedName.isNotEmpty &&
                            requestedName != s.name.trim();
                        await api.updateUser(
                          userId: s.sasId.trim(),
                          currentData: s.sasData,
                          username: user.text.trim(),
                          fullName: requestedName,
                          phone: phone.text.trim(),
                          address: address.text.trim(),
                          ip: ip.text.trim(),
                          allowNameUpdate: explicitNameChangedInApp,
                        );
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('فشل تعديل المشترك في SAS: $e'),
                            ),
                          );
                        }
                        return;
                      }
                    }

                    s.user = user.text.trim();
                    s.name = name.text.trim();
                    s.phone = phone.text.trim();
                    s.address = address.text.trim();
                    s.ip = ip.text.trim();
                    s.type = type.text.trim();
                    s.price = p;
                    double targetPaid;
                    if ((pd - oldPaid).abs() > 0.0001) {
                      targetPaid = pd.clamp(0, p).toDouble();
                    } else if ((p - oldPrice).abs() > 0.0001 ||
                        ((p - pd) - oldRemaining).abs() > 0.0001) {
                      targetPaid = (p - pd).clamp(0, p).toDouble();
                    } else {
                      targetPaid = oldPaid.clamp(0, p).toDouble();
                    }
                    final now = DateTime.now();
                    final delta = s.adjustPaidToTarget(
                      targetPaid,
                      at: now,
                      increaseNote: 'تعديل رصيد الواصل من شاشة المشترك',
                      decreaseNote: 'تصحيح رصيد الواصل من شاشة المشترك',
                    );
                    if (delta.abs() > 0.0001) {
                      final receiptNumber = await AppStore.issueReceiptNumber(
                        persist: false,
                      );
                      s.registerInvoiceFromPayment(
                        receiptNumber: receiptNumber,
                        amount: delta,
                        at: now,
                        note: delta >= 0
                            ? 'فاتورة تعديل من شاشة المشترك'
                            : 'فاتورة تصحيح من شاشة المشترك',
                      );
                      s.paymentDate = fmt(now);
                    }
                    s.startDate = startDate!;
                    s.endDate = endDate!;
                    s.notes = notes.text.trim();
                    final manualPaymentDate = paymentDate.text.trim();
                    if (manualPaymentDate.isNotEmpty) {
                      s.paymentDate = manualPaymentDate;
                    }

                    // حدّث النسخة الخام محلياً للحقول التي أرسلناها.
                    if (s.source == 'sas') {
                      s.sasData['username'] = s.user;
                      s.sasData['firstname'] = s.name
                          .trim()
                          .split(RegExp(r'\s+'))
                          .first;
                      final parts = s.name.trim().split(RegExp(r'\s+'));
                      s.sasData['lastname'] = parts.length > 1
                          ? parts.sublist(1).join(' ')
                          : '-';
                      if (s.phone.isNotEmpty) s.sasData['phone'] = s.phone;
                      if (s.address.isNotEmpty)
                        s.sasData['address'] = s.address;
                      if (s.ip.isNotEmpty) s.sasData['ip'] = s.ip;
                    }
                  }
                  await AppStore.save();
                  if (context.mounted) Navigator.pop(context, true);
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
