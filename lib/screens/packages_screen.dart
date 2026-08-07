import 'package:flutter/material.dart';
import '../models.dart';

class PackagesScreen extends StatefulWidget {
  const PackagesScreen({super.key});

  @override
  State<PackagesScreen> createState() => _PackagesScreenState();
}

class _PackagesScreenState extends State<PackagesScreen> {
  void edit([PackagePlan? package]) {
    final nameController = TextEditingController(text: package?.name ?? '');
    final priceController = TextEditingController(
      text: package?.price.toStringAsFixed(0) ?? '',
    );

    showDialog(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(package == null ? 'إضافة باقة' : 'تعديل الباقة'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'اسم الباقة',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: priceController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'السعر',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () async {
                if (nameController.text.trim().isEmpty) return;

                final price = double.tryParse(priceController.text) ?? 0;
                if (package == null) {
                  AppStore.addPackage(
                    PackagePlan(
                      name: nameController.text.trim(),
                      price: price,
                    ),
                  );
                } else {
                  package.name = nameController.text.trim();
                  package.price = price;
                }

                await AppStore.save();
                if (!mounted) return;
                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                }
                setState(() {});
              },
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('الباقات'),
          centerTitle: true,
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () => edit(),
          child: const Icon(Icons.add),
        ),
        body: AppStore.packages.isEmpty
            ? const Center(
                child: Text('لا توجد باقات، اضغط + للإضافة'),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: AppStore.packages.length,
                itemBuilder: (context, index) {
                  final package = AppStore.packages[index];
                  return Card(
                    child: ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.inventory_2_outlined),
                      ),
                      title: Text(
                        package.name,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        'السعر: ${package.price.toStringAsFixed(0)}',
                      ),
                      onTap: () => edit(package),
                      trailing: IconButton(
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Colors.red,
                        ),
                        onPressed: () async {
                          AppStore.removePackage(package);
                          await AppStore.save();
                          if (mounted) setState(() {});
                        },
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
