import 'package:flutter/material.dart';

import 'store_detail_screen.dart';
import 'stores_screen.dart';

/// صفحة «المشتريات»: بوابتان منفصلتان —
///  • «أضف متجري»: دليل روابط متاجر الوكلاء الخارجية (تُفتح كما هي).
///  • «انشاء متجر»: سوق أجهزة الوكلاء للبيع بالصور.
class PurchasesHomeScreen extends StatelessWidget {
  const PurchasesHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('المشتريات'), centerTitle: true),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _NavCard(
              navKey: const Key('purchases-stores'),
              icon: Icons.storefront_rounded,
              title: 'أضف متجري',
              subtitle: 'روابط متاجر الوكلاء الخارجية — تُفتح كما هي',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const StoresScreen()),
              ),
            ),
            const SizedBox(height: 16),
            _NavCard(
              navKey: const Key('purchases-devices'),
              icon: Icons.devices_other_rounded,
              title: 'انشاء متجر',
              subtitle: 'اعرض أجهزتك للبيع بالصور والوصف',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DevicesScreen()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavCard extends StatelessWidget {
  const _NavCard({
    required this.navKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final Key navKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        key: navKey,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(icon, size: 40, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_left),
            ],
          ),
        ),
      ),
    );
  }
}
