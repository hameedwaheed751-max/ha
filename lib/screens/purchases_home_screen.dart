import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../services/product_service.dart';
import '../services/store_directory_service.dart';
import '../services/trial_guard_service.dart';
import 'store_detail_screen.dart';
import 'stores_screen.dart';

/// صفحة «المشتريات»: مستطيلان واضحان بالأعلى للتبديل —
///  • «المتاجر»: دليل روابط متاجر الوكلاء الخارجية (تُفتح كما هي).
///  • «أجهزة للبيع»: خلاصة منشورات أجهزة الوكلاء (اسم الناشر أعلى ثم الصورة).
/// كل قسم يعرض محتواه فقط، وزر الإضافة يتبع القسم الظاهر.
class PurchasesHomeScreen extends StatefulWidget {
  const PurchasesHomeScreen({
    super.key,
    this.initialStores,
    this.initialProducts,
    this.currentUidOverride,
    this.isAdminOverride,
    this.initialTab = 0,
  });

  final List<Store>? initialStores;
  final List<Product>? initialProducts;
  final String? currentUidOverride;
  final bool? isAdminOverride;
  final int initialTab;

  @override
  State<PurchasesHomeScreen> createState() => _PurchasesHomeScreenState();
}

class _PurchasesHomeScreenState extends State<PurchasesHomeScreen> {
  final _storeService = StoreDirectoryService();
  final _productService = ProductService();
  int _index = 0;
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
    _index = widget.initialTab;
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

  // ---- devices (marketplace feed) ----
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

  Widget _storesTab() {
    final visible = _visibleStores;
    final pending =
        _isAdmin ? visible.where((s) => !s.approved).toList() : const <Store>[];
    final listed =
        _isAdmin ? visible.where((s) => s.approved).toList() : visible;
    StoreCard card(Store s) => StoreCard(
          store: s,
          onOpen: () => _openStore(s),
          onEdit: s.ownerUid == _uid ? () => _addStore(existing: s) : null,
          onDelete: (s.ownerUid == _uid || _isAdmin)
              ? () => _confirmDeleteStore(s)
              : null,
          onApprove: (_isAdmin && !s.approved) ? () => _approveStore(s) : null,
        );
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
        children: [
          if (pending.isNotEmpty) ...[
            const _SectionTitle('متاجر قيد المراجعة'),
            const SizedBox(height: 8),
            _grid([for (final s in pending) card(s)], 0.70, columns: 3),
            const SizedBox(height: 20),
          ],
          if (listed.isEmpty && pending.isEmpty)
            const _EmptyHint('لا توجد متاجر بعد')
          else if (listed.isNotEmpty)
            _grid([for (final s in listed) card(s)], 0.70, columns: 3),
        ],
      ),
    );
  }

  Widget _devicesTab() {
    return RefreshIndicator(
      onRefresh: _load,
      child: _products.isEmpty
          ? ListView(
              children: const [
                Padding(
                  padding: EdgeInsets.only(top: 80),
                  child: _EmptyHint('لا توجد أجهزة معروضة بعد'),
                ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              children: [
                for (final p in _products)
                  DevicePostCard(product: p, onTap: () => _openDevice(p)),
              ],
            ),
    );
  }

  Widget _grid(List<Widget> cards, double aspect, {int columns = 2}) =>
      GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        crossAxisCount: columns,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: aspect,
        children: cards,
      );

  @override
  Widget build(BuildContext context) {
    final onStores = _index == 0;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('المشتريات'), centerTitle: true),
        floatingActionButton: _loading
            ? null
            : (onStores
                ? FloatingActionButton.extended(
                    key: const Key('purchases-add-store'),
                    onPressed: () => _addStore(),
                    icon: const Icon(Icons.add_business_rounded),
                    label: const Text('أضف متجري'),
                  )
                : FloatingActionButton.extended(
                    key: const Key('purchases-add-device'),
                    onPressed: _addDevice,
                    icon: const Icon(Icons.add_photo_alternate_rounded),
                    label: const Text('أضف جهازاً'),
                  )),
        body: Column(
          children: [
            // مستطيلا التبديل بالأعلى — واضحان كما قبل التغيير.
            Padding(
              padding: const EdgeInsets.all(12),
              child: _Segmented(
                index: _index,
                labels: const ['المتاجر', 'أجهزة للبيع'],
                keys: const [Key('seg-stores'), Key('seg-devices')],
                onChanged: (i) => setState(() => _index = i),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : IndexedStack(
                      index: _index,
                      children: [_storesTab(), _devicesTab()],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// شريط تبديل من مستطيلين واضحين؛ المحدَّد مملوء واضح.
class _Segmented extends StatelessWidget {
  const _Segmented({
    required this.index,
    required this.labels,
    required this.keys,
    required this.onChanged,
  });

  final int index;
  final List<String> labels;
  final List<Key> keys;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                key: keys[i],
                onTap: () => onChanged(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: index == i ? scheme.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: index == i ? scheme.onPrimary : scheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
        ],
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
