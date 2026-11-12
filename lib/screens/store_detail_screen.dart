import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/product_service.dart';
import '../services/store_directory_service.dart';
import '../services/trial_guard_service.dart';
import 'stores_screen.dart';
import 'store_iframe_stub.dart'
    if (dart.library.js_interop) 'store_iframe_web.dart';

String _currentUid() => FirebaseAuth.instance.currentUser?.uid ?? '';

Future<String> _resolveOwnerName(String uid) async {
  final user = FirebaseAuth.instance.currentUser;
  try {
    final snap =
        await FirebaseDatabase.instance.ref('agents/$uid/profile/name').get();
    final name = '${snap.value ?? ''}'.trim();
    if (name.isNotEmpty) return name;
  } catch (_) {}
  return (user?.displayName ?? '').trim();
}

/// شاشة المتجر: ترويسة المتجر ثم شبكة أجهزته. المالك/الأدمن يضيف ويعدّل.
class StoreDetailScreen extends StatefulWidget {
  const StoreDetailScreen({
    super.key,
    required this.store,
    this.initialProducts,
    this.currentUidOverride,
    this.isAdminOverride,
  });

  final Store store;
  final List<Product>? initialProducts;
  final String? currentUidOverride;
  final bool? isAdminOverride;

  @override
  State<StoreDetailScreen> createState() => _StoreDetailScreenState();
}

class _StoreDetailScreenState extends State<StoreDetailScreen> {
  final _service = ProductService();
  List<Product> _products = const [];
  bool _loading = true;

  String get _uid => widget.currentUidOverride ?? _currentUid();
  bool get _isAdmin => widget.isAdminOverride ?? TrialGuardService.isAdmin;
  bool get _canManage => _isAdmin || widget.store.ownerUid == _uid;

  @override
  void initState() {
    super.initState();
    if (widget.initialProducts != null) {
      _products = widget.initialProducts!;
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await _service.loadForStore(widget.store.key);
    if (!mounted) return;
    setState(() {
      _products = items;
      _loading = false;
    });
  }

  Future<void> _addOrEdit({Product? existing}) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ProductFormScreen(
          storeKey: widget.store.key,
          existing: existing,
        ),
      ),
    );
    if (changed == true) await _load();
  }

  void _openProduct(Product p) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProductDetailScreen(
          product: p,
          canManage: _isAdmin || p.ownerUid == _uid,
          onEdit: () => _addOrEdit(existing: p),
          onChanged: _load,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: Text(store.name), centerTitle: true),
        floatingActionButton: _canManage
            ? FloatingActionButton.extended(
                onPressed: () => _addOrEdit(),
                icon: const Icon(Icons.add_photo_alternate_rounded),
                label: const Text('أضف جهازاً'),
              )
            : null,
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                  children: [
                    _StoreHeader(store: store),
                    const SizedBox(height: 12),
                    if (_products.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 48),
                        child: Center(child: Text('لا توجد أجهزة في هذا المتجر')),
                      )
                    else
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: EdgeInsets.zero,
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 200,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          childAspectRatio: 0.72,
                        ),
                        itemCount: _products.length,
                        itemBuilder: (context, i) => _ProductCard(
                          product: _products[i],
                          onTap: () => _openProduct(_products[i]),
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _StoreHeader extends StatelessWidget {
  const _StoreHeader({required this.store});
  final Store store;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 56,
                height: 56,
                child: buildStoreLogo(store.logo, 56),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    store.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  if (store.ownerName.isNotEmpty)
                    Text(
                      store.ownerName,
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                ],
              ),
            ),
            if (store.url.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => StoreWebViewScreen(store: store),
                  ),
                ),
                icon: const Icon(Icons.public, size: 18),
                label: const Text('زيارة الموقع'),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.product, required this.onTap});
  final Product product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                color: const Color(0x11000000),
                child: buildStoreImageFill(product.firstImage),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    product.title.isNotEmpty ? product.title : product.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (product.price != null)
                    Text(
                      '${_fmtPrice(product.price!)} ${product.currency}',
                      style: const TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
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

String _fmtPrice(double v) {
  final n = v == v.roundToDouble() ? v.toInt().toString() : v.toString();
  // فواصل آلاف بسيطة.
  final b = StringBuffer();
  for (var i = 0; i < n.length; i++) {
    if (i > 0 && (n.length - i) % 3 == 0) b.write(',');
    b.write(n[i]);
  }
  return b.toString();
}

/// تفاصيل جهاز: معرض صور، وصف، سعر، وزر واتساب للطلب.
class ProductDetailScreen extends StatefulWidget {
  const ProductDetailScreen({
    super.key,
    required this.product,
    required this.canManage,
    required this.onEdit,
    required this.onChanged,
  });

  final Product product;
  final bool canManage;
  final VoidCallback onEdit;
  final Future<void> Function() onChanged;

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  final _service = ProductService();
  final _page = PageController();
  int _index = 0;

  Future<void> _delete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('حذف الجهاز'),
        content: const Text('حذف هذا الجهاز نهائياً؟'),
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
    await _service.deleteOwn(widget.product.key);
    await widget.onChanged();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _whatsapp() async {
    var digits = widget.product.whatsapp.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.startsWith('00')) digits = digits.substring(2);
    if (digits.startsWith('0')) digits = '964${digits.substring(1)}';
    final uri = Uri.parse('https://wa.me/$digits');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(p.title.isNotEmpty ? p.title : 'تفاصيل الجهاز'),
          actions: [
            if (widget.canManage) ...[
              IconButton(
                tooltip: 'تعديل',
                icon: const Icon(Icons.edit),
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onEdit();
                },
              ),
              IconButton(
                tooltip: 'حذف',
                icon: const Icon(Icons.delete_outline),
                onPressed: _delete,
              ),
            ],
          ],
        ),
        body: ListView(
          children: [
            SizedBox(
              height: 300,
              child: Stack(
                children: [
                  PageView.builder(
                    controller: _page,
                    onPageChanged: (i) => setState(() => _index = i),
                    itemCount: p.images.length,
                    itemBuilder: (_, i) => Container(
                      color: const Color(0x11000000),
                      child: buildStoreImageFill(p.images[i]),
                    ),
                  ),
                  if (p.images.length > 1)
                    Positioned(
                      bottom: 8,
                      left: 0,
                      right: 0,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 0; i < p.images.length; i++)
                            Container(
                              width: 8,
                              height: 8,
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: i == _index
                                    ? Colors.blue
                                    : Colors.grey.withValues(alpha: 0.5),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (p.title.isNotEmpty)
                    Text(
                      p.title,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  if (p.price != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        '${_fmtPrice(p.price!)} ${p.currency}',
                        style: const TextStyle(
                          fontSize: 18,
                          color: Colors.green,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text(p.description, style: const TextStyle(fontSize: 15)),
                  if (p.ownerName.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'البائع: ${p.ownerName}',
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ],
                  if (p.whatsapp.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF25D366),
                        ),
                        onPressed: _whatsapp,
                        icon: const Icon(Icons.chat),
                        label: const Text('اطلب عبر واتساب'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// نموذج إضافة/تعديل جهاز: اختيار صور (حتى 5)، وصف، اسم، سعر، عملة، واتساب.
class ProductFormScreen extends StatefulWidget {
  const ProductFormScreen({
    super.key,
    required this.storeKey,
    this.existing,
  });

  final String storeKey;
  final Product? existing;

  @override
  State<ProductFormScreen> createState() => _ProductFormScreenState();
}

class _ProductFormScreenState extends State<ProductFormScreen> {
  final _service = ProductService();
  final _desc = TextEditingController();
  final _title = TextEditingController();
  final _price = TextEditingController();
  final _currency = TextEditingController(text: 'د.ع');
  final _whatsapp = TextEditingController();

  // الصور المحفوظة مسبقاً (روابط) + الصور المختارة حديثاً (ملفات).
  final List<String> _keptUrls = [];
  final List<XFile> _picked = [];
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _desc.text = e.description;
      _title.text = e.title;
      _price.text = e.price == null ? '' : _fmtPlainPrice(e.price!);
      _currency.text = e.currency.isEmpty ? 'د.ع' : e.currency;
      _whatsapp.text = e.whatsapp;
      _keptUrls.addAll(e.images);
    }
  }

  @override
  void dispose() {
    _desc.dispose();
    _title.dispose();
    _price.dispose();
    _currency.dispose();
    _whatsapp.dispose();
    super.dispose();
  }

  int get _imageCount => _keptUrls.length + _picked.length;

  Future<void> _pick() async {
    try {
      // تصغير الصور قبل الرفع لتوفير مساحة الخادم وسرعة النقل.
      final files = await ImagePicker().pickMultiImage(
        maxWidth: 1600,
        imageQuality: 80,
      );
      if (files.isEmpty) return;
      setState(() {
        for (final f in files) {
          if (_imageCount >= ProductService.maxImages) break;
          _picked.add(f);
        }
      });
    } catch (e) {
      setState(() => _error = 'تعذّر اختيار الصور');
    }
  }

  Future<void> _save() async {
    final price = _price.text.trim().isEmpty
        ? null
        : double.tryParse(_price.text.trim().replaceAll(',', ''));
    // تحقق مبكر قبل أي رفع — نبني submission بالصور المحفوظة فقط للفحص.
    final check = ProductSubmission(
      storeKey: widget.storeKey,
      description: _desc.text,
      title: _title.text,
      price: price,
      currency: _currency.text,
      whatsapp: _whatsapp.text,
      imageUrls: List.generate(_imageCount, (_) => 'x'),
    );
    final error = ProductService.validateSubmission(check);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final uid = widget.existing?.ownerUid ?? _currentUid();
    final ownerName = await _resolveOwnerName(uid);
    final key = widget.existing?.key ?? _service.newKey();
    try {
      final uploaded = <String>[];
      for (final f in _picked) {
        final url = await _service.uploadImage(f, productKey: key);
        if (url != null && url.isNotEmpty) uploaded.add(url);
      }
      // إن فشل رفع صورة أو أكثر، لا نحفظ إعلاناً بصور ناقصة؛ نحذف ما رُفع للتوّ
      // أفضل‑جهد (تفادي ملفات يتيمة) ونعرض خطأ.
      if (uploaded.length != _picked.length) {
        for (final url in uploaded) {
          await _service.deleteImage(url);
        }
        if (!mounted) return;
        setState(() {
          _saving = false;
          _error = 'تعذّر رفع بعض الصور، حاول مجدداً';
        });
        return;
      }
      final allImages = [..._keptUrls, ...uploaded];
      final submission = ProductSubmission(
        storeKey: widget.storeKey,
        description: _desc.text,
        title: _title.text,
        price: price,
        currency: _currency.text,
        whatsapp: _whatsapp.text,
        imageUrls: allImages,
      );
      await _service.updateOwn(
        key,
        submission,
        ownerUid: uid,
        ownerName: ownerName,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'تعذّر الحفظ، حاول مجدداً';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.existing == null ? 'أضف جهازاً' : 'تعديل الجهاز'),
        ),
        body: AbsorbPointer(
          absorbing: _saving,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // معرض الصور المختارة.
              SizedBox(
                height: 96,
                child: Row(
                  children: [
                    InkWell(
                      key: const Key('product-form-pick'),
                      onTap: _imageCount >= ProductService.maxImages
                          ? null
                          : _pick,
                      child: Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.add_a_photo_outlined),
                            Text('صورة', style: TextStyle(fontSize: 11)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (var i = 0; i < _keptUrls.length; i++)
                            _thumb(
                              child: SizedBox(
                                width: 90,
                                height: 90,
                                child: buildStoreImageFill(_keptUrls[i]),
                              ),
                              onRemove: () =>
                                  setState(() => _keptUrls.removeAt(i)),
                            ),
                          for (var i = 0; i < _picked.length; i++)
                            _thumb(
                              child: _PickedThumb(file: _picked[i]),
                              onRemove: () =>
                                  setState(() => _picked.removeAt(i)),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('product-form-desc'),
                controller: _desc,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'وصف الجهاز',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: 'اسم/عنوان الجهاز (اختياري)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _price,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'السعر (اختياري)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _currency,
                      decoration: const InputDecoration(
                        labelText: 'العملة',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _whatsapp,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'واتساب للطلب (اختياري)',
                  border: OutlineInputBorder(),
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
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('product-form-save'),
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: Text(_saving ? 'جارٍ الحفظ...' : 'حفظ'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thumb({required Widget child, required VoidCallback onRemove}) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Stack(
        children: [
          ClipRRect(borderRadius: BorderRadius.circular(8), child: child),
          Positioned(
            top: 0,
            left: 0,
            child: GestureDetector(
              onTap: onRemove,
              child: const CircleAvatar(
                radius: 11,
                backgroundColor: Colors.black54,
                child: Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _fmtPlainPrice(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// معاينة صورة مختارة من الجهاز (تعمل على الجوال والويب عبر البايتات).
class _PickedThumb extends StatelessWidget {
  const _PickedThumb({required this.file});
  final XFile file;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: file.readAsBytes(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const SizedBox(
            width: 90,
            height: 90,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        return Image.memory(
          snap.data!,
          width: 90,
          height: 90,
          fit: BoxFit.cover,
        );
      },
    );
  }
}
