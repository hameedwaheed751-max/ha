// ignore_for_file: unnecessary_underscores, use_build_context_synchronously
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _imagePicker = ImagePicker();
  bool _sending = false;
  Future<bool>? _isAdminFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    _isAdminFuture = AppStore.isAdmin;
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _sendText() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final ok = await AppStore.sendChatMessage(text);
    if (!mounted) return;
    if (ok) {
      _textController.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('فشل إرسال الرسالة')));
    }
    setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        backgroundColor: isDark
            ? const Color(0xFF0F172A)
            : const Color(0xfff5f7fb),
        appBar: AppBar(
          backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
          automaticallyImplyLeading: false,
          leading: IconButton(
            tooltip: 'رجوع',
            onPressed: () => Navigator.maybePop(context),
            icon: Icon(
              Icons.arrow_forward,
              color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1F2937),
            ),
          ),
          title: Text(
            'الدردشة',
            style: TextStyle(
              color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1F2937),
            ),
          ),
          centerTitle: true,
          actions: [
            FutureBuilder<bool>(
              future: _isAdminFuture,
              builder: (context, snapshot) {
                final isAdmin = snapshot.data == true;
                if (!isAdmin) return const SizedBox.shrink();
                return IconButton(
                  tooltip: 'حذف جميع الرسائل',
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('حذف جميع الرسائل'),
                        content: const Text(
                          'هل أنت متأكد من حذف جميع الرسائل؟ لا يمكن التراجع عن هذا الإجراء.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('إلغاء'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('حذف الكل'),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      await AppStore.deleteAllChat();
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('تم حذف جميع الرسائل')),
                      );
                    }
                  },
                  icon: Icon(Icons.delete_forever, color: Colors.red),
                );
              },
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: ValueListenableBuilder<int>(
                valueListenable: AppStore.chatMessagesChange,
                builder: (context, _, __) {
                  final messages = AppStore.chatMessages;
                  if (messages.isEmpty) {
                    return Center(
                      child: Text(
                        'لا توجد رسائل بعد',
                        style: TextStyle(
                          color: isDark
                              ? const Color(0xFF94A3B8)
                              : Colors.grey.shade600,
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    reverse: true,
                    itemBuilder: (context, index) {
                      final msg = messages[index];
                      final isMe = msg.senderEmail == AppStore.agentEmail;
                      final time =
                          '${msg.sentAt.hour.toString().padLeft(2, '0')}:${msg.sentAt.minute.toString().padLeft(2, '0')}';
                      return GestureDetector(
                        onLongPress: () => _showMessageOptions(context, msg),
                        child: Align(
                          alignment: isMe
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 6),
                            padding: const EdgeInsets.all(12),
                            constraints: BoxConstraints(
                              maxWidth:
                                  MediaQuery.of(context).size.width * 0.75,
                            ),
                            decoration: BoxDecoration(
                              color: isMe
                                  ? (isDark
                                        ? const Color(0xFF2563EB)
                                        : Colors.blue.shade600)
                                  : (isDark
                                        ? const Color(0xFF1E293B)
                                        : Colors.white),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isDark
                                    ? const Color(0xFF334155)
                                    : Colors.grey.shade200,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  msg.senderName,
                                  style: TextStyle(
                                    color: isMe
                                        ? Colors.white
                                        : const Color(0xFFA5B4FC),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                                if (msg.text.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    msg.text,
                                    style: TextStyle(
                                      color: isMe
                                          ? Colors.white
                                          : (isDark
                                                ? const Color(0xFFE2E8F0)
                                                : const Color(0xFF1F2937)),
                                      fontSize: 15,
                                    ),
                                  ),
                                ],
                                if (msg.imageUrl != null &&
                                    msg.imageUrl!.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Image.network(
                                      msg.imageUrl!,
                                      width:
                                          MediaQuery.of(context).size.width *
                                          0.5,
                                      fit: BoxFit.cover,
                                      loadingBuilder:
                                          (context, child, progress) {
                                            if (progress == null) return child;
                                            return const SizedBox(
                                              height: 120,
                                              child: Center(
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              ),
                                            );
                                          },
                                      errorBuilder:
                                          (context, error, stackTrace) =>
                                              const Icon(
                                                Icons.broken_image,
                                                size: 48,
                                              ),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 4),
                                Text(
                                  time,
                                  style: TextStyle(
                                    color: isMe
                                        ? Colors.white70
                                        : (isDark
                                              ? const Color(0xFF94A3B8)
                                              : Colors.grey.shade600),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : Colors.white,
                border: Border(
                  top: BorderSide(
                    color: isDark
                        ? const Color(0xFF334155)
                        : Colors.grey.shade200,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      style: TextStyle(
                        color: isDark
                            ? const Color(0xFFE2E8F0)
                            : const Color(0xFF1F2937),
                      ),
                      decoration: InputDecoration(
                        hintText: 'اكتب رسالة...',
                        hintStyle: TextStyle(
                          color: isDark
                              ? const Color(0xFF94A3B8)
                              : Colors.grey.shade600,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide(
                            color: isDark
                                ? const Color(0xFF334155)
                                : Colors.grey.shade300,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _sending ? null : _pickAndSendImage,
                    icon: Icon(
                      Icons.image_outlined,
                      color: isDark
                          ? const Color(0xFFA5B4FC)
                          : Colors.blue.shade700,
                    ),
                  ),
                  IconButton(
                    onPressed: _sending ? null : _sendText,
                    icon: Icon(
                      Icons.send_rounded,
                      color: isDark
                          ? const Color(0xFFA5B4FC)
                          : Colors.blue.shade700,
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

  Future<void> _pickAndSendImage() async {
    final xfile = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (xfile == null) return;
    await _sendImage(xfile);
  }

  Future<void> _sendImage(XFile file) async {
    setState(() => _sending = true);
    try {
      final url = await AppStore.uploadChatImage(file);
      if (url == null) throw Exception('فشل رفع الصورة');
      final ok = await AppStore.sendChatMessage('', imageUrl: url);
      if (!mounted) return;
      if (ok) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('فشل إرسال الصورة')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('خطأ: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _showMessageOptions(BuildContext context, ChatMessage msg) {
    final isMe = msg.senderEmail == AppStore.agentEmail;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isMe) ...[
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('تعديل'),
                onTap: () {
                  Navigator.pop(ctx);
                  _editMessage(context, msg);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete),
                title: const Text('حذف'),
                onTap: () {
                  Navigator.pop(ctx);
                  _deleteMessage(context, msg);
                },
              ),
            ],
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('إلغاء'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editMessage(BuildContext context, ChatMessage msg) async {
    final controller = TextEditingController(text: msg.text);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تعديل الرسالة'),
        content: TextField(
          controller: controller,
          maxLines: null,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    if (ok == true && controller.text.trim().isNotEmpty) {
      final result = await AppStore.editChatMessage(
        msg.id,
        controller.text.trim(),
      );
      if (!mounted) return;
      if (result) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تم تعديل الرسالة')));
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تعذر تعديل الرسالة')));
      }
    }
  }

  Future<void> _deleteMessage(BuildContext context, ChatMessage msg) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الرسالة'),
        content: const Text('هل أنت متأكد من حذف هذه الرسالة؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      final result = await AppStore.deleteChatMessage(msg.id);
      if (!mounted) return;
      if (result) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تم حذف الرسالة')));
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تعذر حذف الرسالة')));
      }
    }
  }
}
