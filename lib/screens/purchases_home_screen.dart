import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../services/product_service.dart';
import '../services/store_directory_service.dart';
import '../services/trial_guard_service.dart';
import 'store_detail_screen.dart';
import 'stores_screen.dart';

/// صفحة «المشتريات»: تعرض المحتوى مباشرةً — سوق الأجهزة للبيع ثم روابط المتاجر —
/// وزرّا «انشاء متجر» (أضف جهازاً) و«أضف متجري» (أضف رابط متجر) للإضافة فقط.
class PurchasesHomeScreen extends StatefulWidget {
  const PurchasesHomeScreen({
    super.key,
    this.initialStores,
    this.initialProducts,
    this.currentUidOverride,
    this.isAdminOverride,
  });

  final List<Store>? initialStores;
  final List<Product>? initialProducts;
  final String? currentUidOverride;
  final bool? isAdminOverride;

  @override
  State<PurchasesHomeScreen> createState() => _PurchasesHomeScreenState();
}

class _PurchasesHomeScreenState extends State<PurchasesHomeScreen> {
  final _storeService = StoreDirectoryService();
  final _productService = ProductService();
  List<Store> _stores = const [];
  List<Product> _products = const [];
  bool _loading = true;

  String get _uid =>
      widget.currentUidOverride ??
      FirebaseAuth.instance.currentUser?.uid ??
      '';
  bool get _isAdmin => widget.isAdminOverride ?? TrialGuardService.isAdmin;

  @override
  void initState() {
    super.initState();
    if (widget.initialStores != null || widget.initialProducts != null) {
      _stores = widget.initialStores ?? const [];
      _products = widget.initialProducts ?? const [];
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final stores = await _storeService.load();
    final products = await _productService.loadAll();
    if (!mounted) return;
    setState(() {
      _stores = stores;
      _products = products;
      _loading = false;
    });
  }

  List<Store> get _visibleStores =>
      StoreDirectoryService.visibleFor(all: _stores, uid: _uid, isAdmin: _isAdmin);

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

  // ---- stores (external-link directory) ----
  Future<void> _addStore({Store? existing}) async {
    final submission = await showDialog<StoreSubmission>(
      context: context,
      builder: (_) => StoreFormDialog(existing: existing),
    );
    if (submission == null || !mounted) return;
    final ownerName = await _ownerName();
    if (existing == null) {
      await _storeService.submit(submission, ownerUid: _uid, ownerName: ownerName);
    } else {
      await _storeService.updateOwn(existing.key, submission,
          ownerUid: _uid, ownerName: ownerName);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم الإرسال — بانتظار موافقة الإدارة')),
    );
    await _load();
  }

  Future<void> _confirmDeleteStore(Store store) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('حذف المتجر'),
        content: Text('حذف «${store.name}»؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('حذف')),
        ],
      ),
    );
    if (yes != true) return;
    if (_isAdmin && store.ownerUid != _uid) {
      await _storeService.deleteAny(store.key);
    } else {
      await _storeService.deleteOwn(store.key);
    }
    await _load();
  }

  Future<void> _approveStore(Store store) async {
    await _storeService.approve(store.key);
    await _load();
  }

  void _openStore(Store store) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => StoreWebViewScreen(store: store)),
    );
  }

  // ---- devices (marketplace) ----
  Future<void> _addDevice() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ProductFormScreen(storeKey: _uid)),
    );
    if (changed == true) await _load();
  }

  void _openDevice(Product p) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProductDetailScreen(
          product: p,
          canManage: _isAdmin || p.ownerUid == _uid,
          onEdit: () => _editDevice(p),
          onChanged: _load,
        ),
      ),
    );
  }

  Future<void> _editDevice(Product p) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ProductFormScreen(storeKey: p.storeKey, existing: p),
      ),
    );
    if (changed == true) await _load();
  }

  Widget _grid(List<Widget> cards, double aspect) => GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: aspect,
        children: cards,
      );

  @override
  Widget build(BuildContext context) {
    final visible = _visibleStores;
    final pending =
        _isAdmin ? visible.where((s) => !s.approved).toList() : const <Store>[];
    final listedStores =
        _isAdmin ? visible.where((s) => s.approved).toList() : visible;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('المشتريات'), centerTitle: true),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            key: const Key('purchases-add-device'),
                            onPressed: _addDevice,
                            icon: const Icon(Icons.add_photo_alternate_rounded),
                            label: const Text('انشاء متجر'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            key: const Key('purchases-add-store'),
                            onPressed: () => _addStore(),
                            icon: const Icon(Icons.add_business_rounded),
                            label: const Text('أضف متجري'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // ---- devices marketplace (posts) ----
                    const _SectionTitle('أجهزة للبيع'),
                    const SizedBox(height: 8),
                    if (_products.isEmpty)
                      const _EmptyHint('لا توجد أجهزة معروضة بعد')
                    else
                      _grid([
                        for (final p in _products)
                          ProductCard(product: p, onTap: () => _openDevice(p)),
                      ], 0.72),
                    const SizedBox(height: 20),

                    // ---- stores (external links) ----
                    if (pending.isNotEmpty) ...[
                      const _SectionTitle('متاجر قيد المراجعة'),
                      const SizedBox(height: 8),
                      _grid([
                        for (final s in pending)
                          StoreCard(
                            store: s,
                            onOpen: () => _openStore(s),
                            onEdit: s.ownerUid == _uid
                                ? () => _addStore(existing: s)
                                : null,
                            onDelete: () => _confirmDeleteStore(s),
                            onApprove: () => _approveStore(s),
                          ),
                      ], 0.82),
                      const SizedBox(height: 20),
                    ],
                    const _SectionTitle('المتاجر'),
                    const SizedBox(height: 8),
                    if (listedStores.isEmpty)
                      const _EmptyHint('لا توجد متاجر بعد')
                    else
                      _grid([
                        for (final s in listedStores)
                          StoreCard(
                            store: s,
                            onOpen: () => _openStore(s),
                            onEdit: s.ownerUid == _uid
                                ? () => _addStore(existing: s)
                                : null,
                            onDelete: (s.ownerUid == _uid || _isAdmin)
                                ? () => _confirmDeleteStore(s)
                                : null,
                            onApprove:
                                (_isAdmin && !s.approved) ? () => _approveStore(s) : null,
                          ),
                      ], 0.82),
                  ],
                ),
              ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerRight,
        child: Text(text,
            style:
                const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      );
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
            child: Text(text, style: const TextStyle(color: Colors.grey))),
      );
}
