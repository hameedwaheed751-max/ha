import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController name, phone, address, footer;

  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: AppStore.officeName);
    phone = TextEditingController(text: AppStore.officePhone);
    address = TextEditingController(text: AppStore.officeAddress);
    footer = TextEditingController(text: AppStore.receiptFooter);
  }

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    address.dispose();
    footer.dispose();
    super.dispose();
  }

  InputDecoration dec(String x) => InputDecoration(
        labelText: x,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      );

  Future<void> pickLogo() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
      maxWidth: 900,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    setState(() => AppStore.officeLogoBase64 = base64Encode(bytes));
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: const Text('إعدادات المكتب'), centerTitle: true),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Center(
                child: InkWell(
                  borderRadius: BorderRadius.circular(60),
                  onTap: pickLogo,
                  child: CircleAvatar(
                    radius: 52,
                    backgroundColor: Colors.blue.shade50,
                    backgroundImage: AppStore.officeLogoBase64.isNotEmpty
                        ? MemoryImage(base64Decode(AppStore.officeLogoBase64))
                        : null,
                    child: AppStore.officeLogoBase64.isEmpty
                        ? const Icon(Icons.add_photo_alternate_outlined, size: 38)
                        : null,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Center(child: Text('اضغط لاختيار شعار المكتب')),
              if (AppStore.officeLogoBase64.isNotEmpty)
                TextButton.icon(
                  onPressed: () => setState(() => AppStore.officeLogoBase64 = ''),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('حذف الشعار'),
                ),
              const SizedBox(height: 14),
              TextField(controller: name, decoration: dec('اسم المكتب')),
              const SizedBox(height: 12),
              TextField(controller: phone, keyboardType: TextInputType.phone, decoration: dec('رقم هاتف المكتب')),
              const SizedBox(height: 12),
              TextField(controller: address, decoration: dec('عنوان المكتب')),
              const SizedBox(height: 12),
              TextField(controller: footer, maxLines: 2, decoration: dec('ملاحظة أسفل الوصل')),
              const SizedBox(height: 16),
              Card(
                child: SwitchListTile(
                  value: AppStore.isDarkMode,
                  onChanged: (_) {
                    AppStore.toggleTheme();
                    setState(() {});
                  },
                  secondary: Icon(
                    AppStore.isDarkMode ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                  ),
                  title: const Text('الوضع الداكن', style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(AppStore.isDarkMode ? 'المظهر الداكن مفعّل' : 'المظهر الفاتح مفعّل'),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: () async {
                    AppStore.officeName = name.text.trim();
                    AppStore.officePhone = phone.text.trim();
                    AppStore.officeAddress = address.text.trim();
                    AppStore.receiptFooter = footer.text.trim();
                    await AppStore.save();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ إعدادات المكتب')));
                      Navigator.pop(context, true);
                    }
                  },
                  icon: const Icon(Icons.save),
                  label: const Text('حفظ الإعدادات'),
                ),
              ),
            ],
          ),
        ),
      );
}
