import 'package:flutter/material.dart';

import '../models.dart';
import '../services/whatsapp_notification_preferences.dart';

class WhatsAppEventSettingsSection extends StatefulWidget {
  const WhatsAppEventSettingsSection({super.key});

  @override
  State<WhatsAppEventSettingsSection> createState() =>
      _WhatsAppEventSettingsSectionState();
}

class _WhatsAppEventSettingsSectionState
    extends State<WhatsAppEventSettingsSection> {
  static const _eventTitles = {
    'subscription_activated': 'تفعيل الاشتراك',
    'debt_reminder': 'تذكير بالدين',
    'expiry_3days': 'انتهاء الاشتراك بعد 3 أيام',
    'subscription_expired': 'انتهاء الاشتراك',
  };

  final _preferences = FirebaseWhatsAppNotificationPreferences();
  final Map<String, TextEditingController> _controllers = {
    for (final eventType in FirebaseWhatsAppNotificationPreferences.eventTypes)
      eventType: TextEditingController(),
  };
  final Map<String, WhatsAppNotificationEventPreference> _values = {};
  final Set<String> _busyEvents = {};
  final Map<String, String> _eventErrors = {};
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadPreferences() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final entries = await Future.wait(
        _eventTitles.keys.map(
          (eventType) async =>
              MapEntry(eventType, await _preferences.load(eventType)),
        ),
      );
      if (!mounted) return;
      setState(() {
        _values
          ..clear()
          ..addEntries(entries);
        for (final entry in entries) {
          _controllers[entry.key]!.text =
              entry.value.message ?? _defaultMessage(entry.key);
        }
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadError =
            'تعذر تحميل إعدادات أحداث WhatsApp. تحقق من الاتصال ثم أعد المحاولة.';
        _loading = false;
      });
    }
  }

  String _defaultMessage(String eventType) => switch (eventType) {
    'subscription_activated' =>
      AppStore.messageTemplates['activation'] ?? AppStore.activationTemplate,
    'debt_reminder' =>
      AppStore.messageTemplates['debt'] ?? AppStore.debtTemplate,
    'expiry_3days' =>
      AppStore.messageTemplates['nearExpiry'] ?? AppStore.nearExpiryTemplate,
    'subscription_expired' =>
      AppStore.messageTemplates['expired'] ??
          'مرحباً {{customer_name}}، اشتراكك لدى {{agent_name}} منتهي.',
    _ => '',
  };

  Future<void> _saveEnabled(String eventType, bool enabled) async {
    final current = _values[eventType]!;
    await _savePreference(
      eventType,
      WhatsAppNotificationEventPreference(
        enabled: enabled,
        message: current.message,
      ),
    );
  }

  Future<void> _saveMessage(String eventType) async {
    final current = _values[eventType]!;
    final message = _controllers[eventType]!.text.trim();
    await _savePreference(
      eventType,
      WhatsAppNotificationEventPreference(
        enabled: current.enabled,
        message: message.isEmpty ? null : message,
      ),
    );
  }

  Future<void> _savePreference(
    String eventType,
    WhatsAppNotificationEventPreference preference,
  ) async {
    setState(() {
      _busyEvents.add(eventType);
      _eventErrors.remove(eventType);
    });
    try {
      await _preferences.save(eventType, preference);
      if (!mounted) return;
      setState(() => _values[eventType] = preference);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم حفظ إعداد ${_eventTitles[eventType]}.')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _eventErrors[eventType] =
            'تعذر حفظ الإعداد. تحقق من الاتصال والصلاحيات ثم أعد المحاولة.',
      );
    } finally {
      if (mounted) setState(() => _busyEvents.remove(eventType));
    }
  }

  Future<void> _restoreDefaultMessage(String eventType) async {
    final current = _values[eventType]!;
    await _savePreference(
      eventType,
      WhatsAppNotificationEventPreference(enabled: current.enabled),
    );
    if (!mounted || _eventErrors.containsKey(eventType)) return;
    setState(() => _controllers[eventType]!.text = _defaultMessage(eventType));
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            Icon(
              Icons.notifications_active_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(
              'أحداث رسائل WhatsApp',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
      const Text(
        'إعدادات مستقلة لهذا الحساب للأحداث الأربعة ورسائلها.',
      ),
      const SizedBox(height: 10),
      if (_loading)
        const Center(child: CircularProgressIndicator())
      else if (_loadError != null)
        Column(
          children: [
            Text(_loadError!, style: const TextStyle(color: Colors.red)),
            TextButton.icon(
              onPressed: _loadPreferences,
              icon: const Icon(Icons.refresh),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        )
      else
        for (final eventType in _eventTitles.keys) _eventCard(eventType),
    ],
  );

  Widget _eventCard(String eventType) {
    final preference = _values[eventType]!;
    final busy = _busyEvents.contains(eventType);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_eventTitles[eventType]!),
              subtitle: Text(preference.enabled ? 'مفعّل' : 'متوقف'),
              value: preference.enabled,
              onChanged: busy
                  ? null
                  : (enabled) => _saveEnabled(eventType, enabled),
            ),
            const Divider(),
            TextField(
              controller: _controllers[eventType],
              minLines: 3,
              maxLines: 6,
              enabled: !busy,
              decoration: const InputDecoration(
                labelText: 'نص الرسالة',
                border: OutlineInputBorder(),
              ),
            ),
            if (_eventErrors[eventType] != null) ...[
              const SizedBox(height: 8),
              Text(
                _eventErrors[eventType]!,
                style: const TextStyle(color: Colors.red),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: busy
                      ? null
                      : () => _restoreDefaultMessage(eventType),
                  child: const Text('استعادة النص الافتراضي'),
                ),
                FilledButton(
                  onPressed: busy ? null : () => _saveMessage(eventType),
                  child: Text(busy ? 'جارٍ الحفظ' : 'حفظ الرسالة'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
