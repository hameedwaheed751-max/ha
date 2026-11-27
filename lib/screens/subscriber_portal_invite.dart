import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../services/subscriber_portal_service.dart';

/// نص الدعوة الذي يصل للمشترك. نقيّة.
String portalInviteMessage({
  required String subscriberName,
  required String officeName,
  required String code,
}) {
  final office = officeName.trim().isEmpty ? 'مكتبنا' : officeName.trim();
  return 'مرحباً ${subscriberName.trim()}،\n'
      '$office يدعوك لتطبيق «مشترك نت» لمتابعة اشتراكك وطلب التجديد.\n'
      'رمز الدعوة: $code\n'
      'الرمز صالح 48 ساعة ولمرة واحدة.\n'
      'افتح مشترك نت من هنا واختر «الانضمام باشتراك موجود»:\n'
      '$mushtarakNetWebUrl\n'
      'تطبيق مشترك نت قريباً على Google Play.';
}

/// نسخة الويب من مشترك نت (Render).
const mushtarakNetWebUrl = 'https://mushtarak-net.onrender.com';

/// رقم بصيغة wa.me (964…)، أو null إن لم يصلح. نقيّة.
String? whatsappNumber(String phone) {
  var digits = phone.replaceAll(RegExp(r'\D'), '');
  if (digits.startsWith('00')) digits = digits.substring(2);
  if (digits.startsWith('9640')) digits = '964${digits.substring(4)}';
  if (digits.startsWith('0')) digits = '964${digits.substring(1)}';
  if (digits.length == 10 && digits.startsWith('7')) digits = '964$digits';
  return digits.length >= 12 ? digits : null;
}

/// ينشئ دعوة. إن كان السجل مربوطاً بجهاز سابق (حذف المشترك التطبيق مثلاً)
/// يُفك الربط ويُعاد الإنشاء، لكن فقط بعد تأكيد الوكيل. null = تراجع الوكيل.
Future<PortalInvitation?> inviteWithRelink(
  SubscriberPortalClient client,
  String subscriberId, {
  required Future<bool> Function() confirmRelink,
}) async {
  try {
    return await client.createInvitation(subscriberId);
  } on PortalException catch (e) {
    if (e.code != 'record_already_linked') rethrow;
    if (!await confirmRelink()) return null;
    await client.unlink(subscriberId);
    return client.createInvitation(subscriberId);
  }
}

/// يلغي ربط المشترك بمشترك نت بعد تأكيد الوكيل. البوابة تغلق طلبه المفتوح
/// وتُشعره. false = تراجع الوكيل؛ غير المربوط يرمي PortalException(not_linked).
Future<bool> unlinkFromPortal(
  SubscriberPortalClient client,
  String subscriberId, {
  required Future<bool> Function() confirm,
}) async {
  if (!await confirm()) return false;
  await client.unlink(subscriberId);
  return true;
}

/// زر «دعوة لمشترك نت» في شريط معلومات المشترك. يظهر لحساب التجربة فقط.
class SubscriberPortalInviteAction extends StatefulWidget {
  const SubscriberPortalInviteAction({super.key, required this.subscriber});

  final Subscriber subscriber;

  @override
  State<SubscriberPortalInviteAction> createState() =>
      _SubscriberPortalInviteActionState();
}

class _SubscriberPortalInviteActionState
    extends State<SubscriberPortalInviteAction> {
  late final Future<bool> _enabled = SubscriberPortalFeature.isEnabled();
  bool _busy = false;

  Future<void> _invite() async {
    final s = widget.subscriber;
    if (s.phone.trim().isEmpty) {
      _snack('أضف رقم هاتف المشترك أولاً');
      return;
    }
    setState(() => _busy = true);
    try {
      final invitation = await inviteWithRelink(
        SubscriberPortalSync.instance.client,
        s.subscriberId,
        confirmRelink: _confirmRelink,
      );
      SubscriberPortalSync.instance.markLinksStale();
      if (!mounted || invitation == null) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _InvitationDialog(subscriber: s, invitation: invitation),
      );
    } on PortalException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showOptions() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.send_to_mobile_rounded),
                title: const Text('إرسال دعوة لمشترك نت'),
                onTap: () => Navigator.pop(context, 'invite'),
              ),
              ListTile(
                leading: const Icon(Icons.link_off_rounded),
                title: const Text('إلغاء ربط مشترك نت'),
                subtitle: const Text('يتوقف وصول المشترك لاشتراكه في التطبيق'),
                onTap: () => Navigator.pop(context, 'unlink'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == 'invite') await _invite();
    if (choice == 'unlink') await _unlink();
  }

  Future<void> _unlink() async {
    setState(() => _busy = true);
    try {
      final done = await unlinkFromPortal(
        SubscriberPortalSync.instance.client,
        widget.subscriber.subscriberId,
        confirm: _confirmUnlink,
      );
      SubscriberPortalSync.instance.markLinksStale();
      if (done) _snack('أُلغي ربط المشترك، ووصله إشعار بذلك');
    } on PortalException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmUnlink() async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('إلغاء ربط مشترك نت'),
            content: Text(
              'لن يرى ${widget.subscriber.name} اشتراكه في تطبيق مشترك نت، ولن يستطيع طلب التجديد منه. '
              'يُلغى طلبه المفتوح إن وُجد، ويصله إشعار. يمكن ربطه لاحقاً بدعوة جديدة.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('تراجع'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('إلغاء الربط'),
              ),
            ],
          ),
        ),
      ) ??
      false;

  Future<bool> _confirmRelink() async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('المشترك مرتبط مسبقاً'),
            content: const Text(
              'هذا المشترك مربوط بتطبيق مشترك نت على جهاز آخر. '
              'إنشاء دعوة جديدة يفك ذلك الربط، ولن يرى الجهاز القديم الاشتراك بعدها.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('تراجع'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('فك الربط وإنشاء دعوة'),
              ),
            ],
          ),
        ),
      ) ??
      false;

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: _enabled,
    builder: (context, snapshot) {
      if (snapshot.data != true) return const SizedBox.shrink();
      return PortalInviteButton(onPressed: _showOptions, busy: _busy);
    },
  );
}

/// أيقونة مشترك نت وتحتها كلمة «دعوة»، داخل بطاقة المشترك الداكنة.
class PortalInviteButton extends StatelessWidget {
  const PortalInviteButton({super.key, required this.onPressed, required this.busy});

  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'مشترك نت: دعوة أو إلغاء ربط',
    child: InkWell(
      onTap: busy ? null : onPressed,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            busy
                ? const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.phone_iphone_rounded, color: Colors.white, size: 24),
            const SizedBox(height: 4),
            const Text(
              'دعوة',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  );
}

class _InvitationDialog extends StatelessWidget {
  const _InvitationDialog({required this.subscriber, required this.invitation});

  final Subscriber subscriber;
  final PortalInvitation invitation;

  String get _message => portalInviteMessage(
    subscriberName: subscriber.name,
    officeName: AppStore.officeName,
    code: invitation.displayCode,
  );

  @override
  Widget build(BuildContext context) {
    final number = whatsappNumber(subscriber.phone);
    final expires = invitation.expiresAt;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('دعوة لتطبيق مشترك نت'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('أرسل الرمز إلى ${subscriber.name} على الرقم المنتهي بـ '
                '${invitation.maskedPhone.replaceAll('•', '')}.'),
            const SizedBox(height: 16),
            SelectableText(
              invitation.displayCode,
              textAlign: TextAlign.center,
              textDirection: TextDirection.ltr,
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.bold,
                letterSpacing: 4,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'صالح حتى ${expires.year}/${expires.month}/${expires.day} '
              '${expires.hour.toString().padLeft(2, '0')}:${expires.minute.toString().padLeft(2, '0')}، '
              'ولمرة واحدة. الرمز لا يظهر مرة أخرى؛ دعوة جديدة تلغي هذا الرمز.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _message));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('نُسخت رسالة الدعوة')),
                );
              }
            },
            child: const Text('نسخ الرسالة'),
          ),
          if (number != null)
            FilledButton.icon(
              onPressed: () => launchUrl(
                Uri.parse('https://wa.me/$number?text=${Uri.encodeComponent(_message)}'),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.send_rounded),
              label: const Text('إرسال واتساب'),
            ),
        ],
      ),
    );
  }
}
