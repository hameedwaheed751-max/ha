import 'package:flutter/material.dart';
import '../models.dart';

class MessageTemplatesScreen extends StatefulWidget {
  const MessageTemplatesScreen({super.key});

  @override
  State<MessageTemplatesScreen> createState() =>
      _MessageTemplatesScreenState();
}

class _MessageTemplatesScreenState extends State<MessageTemplatesScreen> {
  void edit(String key, String title) {
    final controller = TextEditingController(
      text: AppStore.messageTemplates[key] ?? '',
    );

    showDialog<void>(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            maxLines: 6,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'اكتب نص الرسالة...',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () async {
                AppStore.messageTemplates[key] = controller.text;
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
    final items = <String, String>{
      'activation': 'رسالة التفعيل',
      'extension': 'رسالة التمديد',
      'nearExpiry': 'رسالة قرب الانتهاء',
      'expired': 'رسالة انتهاء الاشتراك',
      'debt': 'رسالة تنبيه دفع الديون',
    };

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('التنبيهات ورسائل واتساب'),
          centerTitle: true,
        ),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'المتغيرات المتاحة داخل الرسائل: {name} الاسم، {user} اليوزر، {office} اسم المكتب، {endDate} تاريخ الانتهاء، {price} مبلغ الاشتراك، {paid} الواصل، {remaining} المتبقي، {package} الباقة.',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            ),
            ...items.entries
              .map(
                (entry) => Card(
                  child: ListTile(
                    leading: const Icon(
                      Icons.chat_outlined,
                      color: Colors.green,
                    ),
                    title: Text(entry.value),
                    subtitle: Text(
                      AppStore.messageTemplates[entry.key] ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () => edit(entry.key, entry.value),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
