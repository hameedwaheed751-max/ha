import 'package:flutter/material.dart';

class PingScreen extends StatelessWidget {
  const PingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('Ping')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Column(
                children: [
                  Icon(Icons.info_outline_rounded, size: 40),
                  SizedBox(height: 14),
                  Text(
                    'ICMP Ping غير متاح داخل المتصفح',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  SizedBox(height: 10),
                  Text(
                    'Safari وبقية المتصفحات لا تسمح بإرسال حزم ICMP من '
                    'الجهاز. استخدم تطبيق NetAgent على Android أو iOS لتنفيذ '
                    'Ping حقيقي إلى عنوان IP أو اسم المضيف الذي تختاره.',
                    textAlign: TextAlign.center,
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
