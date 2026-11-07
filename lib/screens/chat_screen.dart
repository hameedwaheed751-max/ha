// ignore_for_file: unnecessary_underscores, use_build_context_synchronously
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
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
  final Set<String> _knownMessageIds = {};
  final List<ChatMessage> _pendingNotifications = [];
  final FocusNode _inputFocus = FocusNode();
  final Map<String, GlobalKey> _messageKeys = {};
  bool _sending = false;
  Future<bool>? _isAdminFuture;
  Timer? _notificationTimer;
  Timer? _highlightTimer;

  /// الرسالة التي يُكتب الرد عليها الآن.
  ChatReply? _replyTo;
  String? _highlightedId;

  String? get _myUid => FirebaseAuth.instance.currentUser?.uid;

  GlobalKey _keyFor(String id) => _messageKeys.putIfAbsent(id, GlobalKey.new);

  void _startReply(ChatMessage message) {
    if (message.deletedAt != null) return;
    setState(() => _replyTo = ChatReply.of(message));
    _inputFocus.requestFocus();
  }

  void _cancelReply() => setState(() => _replyTo = null);

  String _replyAuthor(ChatReply reply) =>
      reply.senderUid.isNotEmpty && reply.senderUid == _myUid
      ? 'أنت'
      : reply.senderName;

  /// ينتقل إلى الرسالة الأصلية؛ القائمة كسولة فيُمرَّر حتى تُبنى.
  Future<void> _jumpToMessage(String id) async {
    final index = AppStore.chatMessages.indexWhere((m) => m.id == id);
    if (index < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الرسالة الأصلية لم تعد موجودة')),
      );
      return;
    }
    for (var step = 0; step < 40; step++) {
      final target = _messageKeys[id]?.currentContext;
      if (target != null) {
        await Scrollable.ensureVisible(
          target,
          alignment: 0.5,
          duration: const Duration(milliseconds: 250),
        );
        break;
      }
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (position.pixels >= position.maxScrollExtent) break;
      _scrollController.jumpTo(
        (position.pixels + position.viewportDimension * 0.8).clamp(
          0,
          position.maxScrollExtent,
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    if (!mounted) return;
    setState(() => _highlightedId = id);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightedId = null);
    });
  }

  @override
  void initState() {
    super.initState();
    AppStore.markChatOpened();
    _knownMessageIds.addAll(AppStore.chatMessages.map((message) => message.id));
    AppStore.chatMessagesChange.addListener(_handleChatMessagesChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    _isAdminFuture = AppStore.isAdmin;
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _inputFocus.dispose();
    _highlightTimer?.cancel();
    AppStore.chatMessagesChange.removeListener(_handleChatMessagesChanged);
    _notificationTimer?.cancel();
    super.dispose();
  }

  void _handleChatMessagesChanged() {
    final newMessages = <ChatMessage>[];
    final currentUid = FirebaseAuth.instance.currentUser?.uid;
    for (final message in AppStore.chatMessages) {
      if (_knownMessageIds.add(message.id) && message.senderUid != currentUid) {
        newMessages.add(message);
      }
    }
    if (newMessages.isEmpty || !mounted) return;

    setState(() {
      _pendingNotifications.addAll(newMessages.reversed);
      _scheduleNextNotification();
    });
  }

  void _scheduleNextNotification() {
    if (_notificationTimer != null || _pendingNotifications.isEmpty) return;
    _notificationTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      setState(() {
        _pendingNotifications.clear();
        _notificationTimer = null;
      });
    });
  }

  void _dismissNotification() {
    if (_pendingNotifications.isEmpty) return;
    _notificationTimer?.cancel();
    setState(() {
      _pendingNotifications.clear();
      _notificationTimer = null;
    });
  }

  Widget _buildIncomingNotification(bool isDark) {
    final count = _pendingNotifications.length;
    final previewMessage = _pendingNotifications.isNotEmpty
        ? _pendingNotifications.first
        : null;
    final senderName = previewMessage?.senderName ?? 'الدردشة';
    final repliedToMe =
        previewMessage?.replyTo != null &&
        previewMessage!.replyTo!.senderUid.isNotEmpty &&
        previewMessage.replyTo!.senderUid == _myUid;
    final previewText = previewMessage == null
        ? ''
        : (repliedToMe ? 'ردّ على رسالتك: ' : '') +
              (previewMessage.text.isEmpty ? 'أرسل صورة' : previewMessage.text);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF163B2D) : const Color(0xFFE7F6EC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? const Color(0xFF2E6B4B) : const Color(0xFFB9E4C7),
        ),
      ),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 12),
            child: CircleAvatar(
              radius: 14,
              backgroundColor: const Color(0xFF22834D),
              child: Text(
                count.toString(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    count > 1 ? 'رسائل جديدة' : 'رسالة جديدة',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isDark ? Colors.white : const Color(0xFF17452B),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    count > 1
                        ? '$count رسائل واردة من $senderName'
                        : '$senderName: $previewText',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isDark
                          ? const Color(0xFFD1E8D8)
                          : const Color(0xFF315B40),
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: 'إغلاق الإشعار',
            onPressed: _dismissNotification,
            icon: Icon(
              Icons.close,
              size: 19,
              color: isDark ? Colors.white70 : const Color(0xFF315B40),
            ),
          ),
        ],
      ),
    );
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
    final ok = await AppStore.sendChatMessage(text, replyTo: _replyTo);
    if (!mounted) return;
    if (ok) {
      _textController.clear();
      _replyTo = null;
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
            if (_pendingNotifications.isNotEmpty)
              _buildIncomingNotification(isDark),
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
                      final isMe =
                          msg.senderUid ==
                          FirebaseAuth.instance.currentUser?.uid;
                      final time =
                          '${msg.sentAt.hour.toString().padLeft(2, '0')}:${msg.sentAt.minute.toString().padLeft(2, '0')}';
                      final isDeleted = msg.deletedAt != null;
                      final highlighted = _highlightedId == msg.id;
                      return SwipeToReply(
                        key: _keyFor(msg.id),
                        enabled: !isDeleted,
                        onReply: () => _startReply(msg),
                        child: GestureDetector(
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
                                  color: highlighted
                                      ? Colors.amber
                                      : (isDark
                                            ? const Color(0xFF334155)
                                            : Colors.grey.shade200),
                                  width: highlighted ? 2 : 1,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    msg.senderName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: isMe
                                          ? Colors.white
                                          : const Color(0xFF7C3AED),
                                      fontWeight: FontWeight.w900,
                                      fontSize: 13,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                  if (!isDeleted && msg.replyTo != null) ...[
                                    const SizedBox(height: 6),
                                    ReplyQuote(
                                      author: _replyAuthor(msg.replyTo!),
                                      text: msg.replyTo!.preview,
                                      onMine: isMe,
                                      isDark: isDark,
                                      onTap: () => _jumpToMessage(
                                        msg.replyTo!.messageId,
                                      ),
                                    ),
                                  ],
                                  if (isDeleted) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      'تم حذف هذه الرسالة',
                                      style: TextStyle(
                                        color: isMe
                                            ? Colors.white70
                                            : (isDark
                                                  ? const Color(0xFF94A3B8)
                                                  : Colors.grey.shade600),
                                        fontSize: 14,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  ] else if (msg.text.isNotEmpty) ...[
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
                                  if (!isDeleted &&
                                      msg.imageUrl != null &&
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
                                              if (progress == null)
                                                return child;
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
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            if (_replyTo != null)
              Container(
                key: const ValueKey('reply-bar'),
                color: isDark ? const Color(0xFF1E293B) : Colors.white,
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
                child: Row(
                  children: [
                    Icon(
                      Icons.reply,
                      size: 20,
                      color: isDark
                          ? const Color(0xFFA5B4FC)
                          : Colors.blue.shade700,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ReplyQuote(
                        author: 'الرد على ${_replyAuthor(_replyTo!)}',
                        text: _replyTo!.preview,
                        onMine: false,
                        isDark: isDark,
                      ),
                    ),
                    IconButton(
                      tooltip: 'إلغاء الرد',
                      onPressed: _cancelReply,
                      icon: const Icon(Icons.close, size: 20),
                    ),
                  ],
                ),
              ),
            Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : Colors.white,
                border: _replyTo != null
                    ? null
                    : Border(
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
                      focusNode: _inputFocus,
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
      final ok = await AppStore.sendChatMessage(
        '',
        imageUrl: url,
        replyTo: _replyTo,
      );
      if (!mounted) return;
      if (ok) {
        _replyTo = null;
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

  Future<void> _showMessageOptions(
    BuildContext context,
    ChatMessage msg,
  ) async {
    final isMe = msg.senderUid == FirebaseAuth.instance.currentUser?.uid;
    final isAdminUser = await AppStore.isAdmin;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (msg.deletedAt == null)
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('رد'),
                onTap: () {
                  Navigator.pop(ctx);
                  _startReply(msg);
                },
              ),
            if (isMe || isAdminUser) ...[
              ListTile(
                leading: const Icon(Icons.delete),
                title: const Text('حذف'),
                onTap: () {
                  Navigator.pop(ctx);
                  _deleteMessage(context, msg);
                },
              ),
            ],
            if (isMe) ...[
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('تعديل'),
                onTap: () {
                  Navigator.pop(ctx);
                  _editMessage(context, msg);
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

/// سحب الرسالة أفقياً يبدأ الرد عليها، كتطبيقات المحادثة.
class SwipeToReply extends StatefulWidget {
  const SwipeToReply({
    super.key,
    required this.child,
    required this.onReply,
    this.enabled = true,
  });

  static const double trigger = 56;
  static const double maxOffset = 80;

  final Widget child;
  final VoidCallback onReply;
  final bool enabled;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply> {
  double _offset = 0;
  bool _armed = false;

  void _update(DragUpdateDetails details) {
    final next = (_offset + details.delta.dx).clamp(
      -SwipeToReply.maxOffset,
      SwipeToReply.maxOffset,
    );
    final armed = next.abs() >= SwipeToReply.trigger;
    if (armed && !_armed) HapticFeedback.selectionClick();
    setState(() {
      _offset = next;
      _armed = armed;
    });
  }

  void _end([DragEndDetails? _]) {
    if (_armed) widget.onReply();
    setState(() {
      _offset = 0;
      _armed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final progress = (_offset.abs() / SwipeToReply.trigger).clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: _end,
      child: Stack(
        alignment: _offset >= 0
            ? AlignmentDirectional.centerStart
            : AlignmentDirectional.centerEnd,
        children: [
          if (_offset != 0)
            Opacity(
              opacity: progress,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: CircleAvatar(
                  radius: 15,
                  backgroundColor: Colors.blue.withValues(alpha: 0.15),
                  child: Icon(
                    Icons.reply,
                    size: 18,
                    color: Colors.blue.shade700,
                  ),
                ),
              ),
            ),
          AnimatedContainer(
            duration: Duration(milliseconds: _offset == 0 ? 180 : 0),
            transform: Matrix4.translationValues(_offset, 0, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

/// اقتباس الرسالة الأصلية داخل الرد وفوق خانة الكتابة.
class ReplyQuote extends StatelessWidget {
  const ReplyQuote({
    super.key,
    required this.author,
    required this.text,
    required this.onMine,
    required this.isDark,
    this.onTap,
  });

  final String author;
  final String text;
  final bool onMine;
  final bool isDark;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final accent = onMine ? Colors.white : const Color(0xFF7C3AED);
    final background = onMine
        ? Colors.white.withValues(alpha: 0.18)
        : (isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9));
    final textColor = onMine
        ? Colors.white70
        : (isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569));
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
          border: BorderDirectional(start: BorderSide(color: accent, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: accent,
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            ),
            Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: textColor, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
