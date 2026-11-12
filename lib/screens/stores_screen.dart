import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/store_directory_service.dart';
import '../services/trial_guard_service.dart';
import 'store_iframe_stub.dart'
    if (dart.library.js_interop) 'store_iframe_web.dart';

/// قسم «المشتريات»: دليل متاجر الوكلاء. يعرض المتاجر المعتمدة، ويتيح لكل
/// وكيل إضافة متجره (بانتظار موافقة الأدمن)، وللأدمن اعتماد/حذف المتاجر.
class StoresScreen extends StatefulWidget {
  const StoresScreen({
    super.key,
    this.initialStores,
    this.currentUidOverride,
    this.isAdminOverride,
  });

  /// للاختبار: متاجر جاهزة تتخطى القراءة من Firebase.
  final List<Store>? initialStores;

  /// للاختبار: يتجاوز uid الحالي.
  final String? currentUidOverride;

  /// للاختبار: يتجاوز حالة الأدمن.
  final bool? isAdminOverride;

  @override
  State<StoresScreen> createState() => _StoresScreenState();
}

class _StoresScreenState extends State<StoresScreen> {
  final _service = StoreDirectoryService();
  List<Store> _all = const [];
  bool _loading = true;
  String _query = '';

  String get _uid =>
      widget.currentUidOverride ??
      FirebaseAuth.instance.currentUser?.uid ??
      '';

  bool get _isAdmin => widget.isAdminOverride ?? TrialGuardService.isAdmin;

  @override
  void initState() {
    super.initState();
    if (widget.initialStores != null) {
      _all = widget.initialStores!;
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final stores = await _service.load();
    if (!mounted) return;
    setState(() {
      _all = stores;
      _loading = false;
    });
  }

  List<Store> get _visible {
    final v = StoreDirectoryService.visibleFor(
      all: _all,
      uid: _uid,
      isAdmin: _isAdmin,
    );
    final q = _query.trim();
    if (q.isEmpty) return v;
    return v
        .where((s) =>
            s.name.contains(q) || s.ownerName.contains(q))
        .toList();
  }

  /// اسم المكتب للعرض عند إضافة متجر: من ملف الوكيل، وإلا اسم الحساب.
  Future<String> _ownerName() async {
    final user = FirebaseAuth.instance.currentUser;
    try {
      final snap =
          await FirebaseDatabase.instance.ref('agents/$_uid/profile/name').get();
      final name = '${snap.value ?? ''}'.trim();
      if (name.isNotEmpty) return name;
    } catch (_) {}
    return (user?.displayName ?? '').trim();
  }

  Future<void> _openForm({Store? existing}) async {
    final submission = await showDialog<StoreSubmission>(
      context: context,
      builder: (_) => StoreFormDialog(existing: existing),
    );
    if (submission == null || !mounted) return;
    final ownerName = await _ownerName();
    if (existing == null) {
      await _service.submit(submission, ownerUid: _uid, ownerName: ownerName);
    } else {
      await _service.updateOwn(
        existing.key,
        submission,
        ownerUid: _uid,
        ownerName: ownerName,
      );
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم الإرسال — بانتظار موافقة الإدارة')),
    );
    await _load();
  }

  Future<void> _confirmDelete(Store store) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('حذف المتجر'),
        content: Text('حذف «${store.name}»؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    if (_isAdmin && store.ownerUid != _uid) {
      await _service.deleteAny(store.key);
    } else {
      await _service.deleteOwn(store.key);
    }
    await _load();
  }

  Future<void> _approve(Store store) async {
    await _service.approve(store.key);
    await _load();
  }

  void _open(Store store) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => StoreWebViewScreen(store: store)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final pending = _isAdmin
        ? visible.where((s) => !s.approved).toList()
        : const <Store>[];
    final listed = _isAdmin
        ? visible.where((s) => s.approved).toList()
        : visible;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('المشتريات'),
          centerTitle: true,
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _openForm(),
          icon: const Icon(Icons.add_business_rounded),
          label: const Text('أضف متجري'),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                  children: [
                    TextField(
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'ابحث عن متجر',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                    const SizedBox(height: 12),
                    if (_isAdmin && pending.isNotEmpty) ...[
                      Text(
                        'قيد المراجعة',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      for (final s in pending)
                        _StoreTile(
                          store: s,
                          isOwner: s.ownerUid == _uid,
                          isAdmin: _isAdmin,
                          onOpen: () => _open(s),
                          onEdit: s.ownerUid == _uid
                              ? () => _openForm(existing: s)
                              : null,
                          onDelete: () => _confirmDelete(s),
                          onApprove: () => _approve(s),
                        ),
                      const Divider(height: 24),
                    ],
                    if (listed.isEmpty && pending.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 48),
                        child: Center(child: Text('لا توجد متاجر بعد')),
                      ),
                    for (final s in listed)
                      _StoreTile(
                        store: s,
                        isOwner: s.ownerUid == _uid,
                        isAdmin: _isAdmin,
                        onOpen: () => _open(s),
                        onEdit: s.ownerUid == _uid
                            ? () => _openForm(existing: s)
                            : null,
                        onDelete: (s.ownerUid == _uid || _isAdmin)
                            ? () => _confirmDelete(s)
                            : null,
                        onApprove: null,
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _StoreTile extends StatelessWidget {
  const _StoreTile({
    required this.store,
    required this.isOwner,
    required this.isAdmin,
    required this.onOpen,
    this.onEdit,
    this.onDelete,
    this.onApprove,
  });

  final Store store;
  final bool isOwner;
  final bool isAdmin;
  final VoidCallback onOpen;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onApprove;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        onTap: store.approved ? onOpen : null,
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.network(
            store.logo,
            width: 44,
            height: 44,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) =>
                const Icon(Icons.storefront_rounded, size: 40),
          ),
        ),
        title: Text(store.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (store.ownerName.isNotEmpty) Text(store.ownerName),
            if (store.description.isNotEmpty)
              Text(
                store.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            if (!store.approved)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'قيد المراجعة',
                  style: TextStyle(
                    color: Colors.orange,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onApprove != null)
              IconButton(
                tooltip: 'اعتماد',
                icon: const Icon(Icons.check_circle, color: Colors.green),
                onPressed: onApprove,
              ),
            if (onEdit != null)
              IconButton(
                tooltip: 'تعديل',
                icon: const Icon(Icons.edit),
                onPressed: onEdit,
              ),
            if (onDelete != null)
              IconButton(
                tooltip: 'حذف',
                icon: const Icon(Icons.delete_outline),
                onPressed: onDelete,
              ),
          ],
        ),
      ),
    );
  }
}

/// نافذة إضافة/تعديل متجر. ترجع StoreSubmission صالحة عند الحفظ، أو null
/// عند الإلغاء. تتحقق داخلياً وتعرض رسالة الخطأ دون إغلاق.
class StoreFormDialog extends StatefulWidget {
  const StoreFormDialog({super.key, this.existing});

  final Store? existing;

  @override
  State<StoreFormDialog> createState() => _StoreFormDialogState();
}

class _StoreFormDialogState extends State<StoreFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _logo;
  late final TextEditingController _whatsapp;
  late final TextEditingController _desc;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _url = TextEditingController(text: e?.url ?? '');
    _logo = TextEditingController(text: e?.logoUrl ?? '');
    _whatsapp = TextEditingController(text: e?.whatsapp ?? '');
    _desc = TextEditingController(text: e?.description ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _logo.dispose();
    _whatsapp.dispose();
    _desc.dispose();
    super.dispose();
  }

  void _submit() {
    final submission = StoreSubmission(
      name: _name.text,
      url: _url.text,
      logoUrl: _logo.text,
      whatsapp: _whatsapp.text,
      description: _desc.text,
    );
    final error = StoreDirectoryService.validateSubmission(submission);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(submission);
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(widget.existing == null ? 'أضف متجري' : 'تعديل المتجر'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('store-form-name'),
                controller: _name,
                decoration: const InputDecoration(labelText: 'اسم المتجر'),
              ),
              TextField(
                key: const Key('store-form-url'),
                controller: _url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'رابط المتجر (https)',
                ),
              ),
              TextField(
                key: const Key('store-form-logo'),
                controller: _logo,
                decoration: const InputDecoration(
                  labelText: 'رابط الشعار (اختياري)',
                ),
              ),
              TextField(
                key: const Key('store-form-whatsapp'),
                controller: _whatsapp,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'واتساب (اختياري)',
                ),
              ),
              TextField(
                key: const Key('store-form-desc'),
                controller: _desc,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'وصف قصير (اختياري)',
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            key: const Key('store-form-submit'),
            onPressed: _submit,
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }
}

/// يفتح متجر الوكيل داخل التطبيق. على الويب يفتح الرابط في تبويب خارجي.
class StoreWebViewScreen extends StatefulWidget {
  const StoreWebViewScreen({super.key, required this.store});

  final Store store;

  @override
  State<StoreWebViewScreen> createState() => _StoreWebViewScreenState();
}

class _StoreWebViewScreenState extends State<StoreWebViewScreen> {
  WebViewController? _controller;
  final _progress = ValueNotifier<int>(0);
  final _error = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(
          NavigationDelegate(
            onProgress: (v) => _progress.value = v,
            onWebResourceError: (e) {
              if (e.isForMainFrame == false) return;
              _error.value = e.description;
            },
          ),
        )
        ..loadRequest(Uri.parse(widget.store.url));
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _error.dispose();
    super.dispose();
  }

  Future<void> _openExternal() async {
    final uri = Uri.tryParse(widget.store.url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.store.name),
          actions: [
            IconButton(
              tooltip: 'فتح في المتصفح',
              icon: const Icon(Icons.open_in_browser),
              onPressed: _openExternal,
            ),
            if (!kIsWeb)
              IconButton(
                tooltip: 'إعادة التحميل',
                icon: const Icon(Icons.refresh),
                onPressed: () {
                  _error.value = null;
                  _controller?.reload();
                },
              ),
          ],
        ),
        body: kIsWeb
            ? Column(
                children: [
                  // يُفتح المتجر مضمّناً داخل التطبيق. إن رفض الموقع التضمين
                  // يبقى زر «فتح في المتصفح» في الأعلى بديلاً.
                  Expanded(
                    child: Directionality(
                      textDirection: TextDirection.ltr,
                      child: buildStoreIframe(widget.store.url),
                    ),
                  ),
                ],
              )
            : Stack(
                children: [
                  Positioned.fill(
                    child: Directionality(
                      textDirection: TextDirection.ltr,
                      child: WebViewWidget(controller: _controller!),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: ValueListenableBuilder<int>(
                      valueListenable: _progress,
                      builder: (context, value, child) => value >= 100
                          ? const SizedBox.shrink()
                          : LinearProgressIndicator(value: value / 100),
                    ),
                  ),
                  Positioned.fill(
                    child: ValueListenableBuilder<String?>(
                      valueListenable: _error,
                      builder: (context, error, child) => error == null
                          ? const IgnorePointer(child: SizedBox.shrink())
                          : ColoredBox(
                              color: Theme.of(context).colorScheme.surface,
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'تعذّر تحميل المتجر:\n$error',
                                        textAlign: TextAlign.center,
                                      ),
                                      const SizedBox(height: 12),
                                      FilledButton(
                                        onPressed: _openExternal,
                                        child: const Text('فتح في المتصفح'),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
