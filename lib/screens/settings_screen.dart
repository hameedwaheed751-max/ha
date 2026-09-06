import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models.dart';
import '../services/render_whatsapp_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController name, phone, address, footer;
  WhatsAppSendProvider _whatsAppProvider = WhatsAppSendProvider.meta;
  bool _testingWhatsApp = false;

  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: AppStore.officeName);
    phone = TextEditingController(text: AppStore.officePhone);
    address = TextEditingController(text: AppStore.officeAddress);
    footer = TextEditingController(text: AppStore.receiptFooter);
    _loadWhatsAppProvider();
  }

  Future<void> _loadWhatsAppProvider() async {
    final provider = await RenderWhatsAppService.loadProvider();
    if (!mounted) return;
    setState(() => _whatsAppProvider = provider);
  }

  Future<void> _testWhatsAppService() async {
    if (_testingWhatsApp) return;
    setState(() => _testingWhatsApp = true);
    final result = await RenderWhatsAppService.testLocalService(phone.text);
    if (!mounted) return;
    setState(() => _testingWhatsApp = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.success
              ? 'تم إرسال رسالة الاختبار عبر WhatsApp Service'
              : 'فشل اختبار WhatsApp Service: ${result.error ?? 'خطأ غير معروف'}',
        ),
      ),
    );
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
              const Text(
                'طريقة إرسال واتساب',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              SegmentedButton<WhatsAppSendProvider>(
                segments: const [
                  ButtonSegment(
                    value: WhatsAppSendProvider.meta,
                    label: Text('Meta WhatsApp'),
                    icon: Icon(Icons.cloud_outlined),
                  ),
                  ButtonSegment(
                    value: WhatsAppSendProvider.whatsappService,
                    label: Text('WhatsApp Service'),
                    icon: Icon(Icons.computer_outlined),
                  ),
                ],
                selected: {_whatsAppProvider},
                onSelectionChanged: (selection) {
                  setState(() => _whatsAppProvider = selection.first);
                },
              ),
              if (_whatsAppProvider == WhatsAppSendProvider.whatsappService) ...[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _testingWhatsApp ? null : _testWhatsAppService,
                  icon: _testingWhatsApp
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_outlined),
                  label: const Text('إرسال رسالة اختبار'),
                ),
              ],
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
                    await RenderWhatsAppService.saveProvider(_whatsAppProvider);
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
