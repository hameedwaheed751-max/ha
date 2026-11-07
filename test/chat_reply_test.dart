import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';
import 'package:untitled/screens/chat_screen.dart';

ChatMessage _message({String text = 'مرحبا', String? imageUrl}) => ChatMessage(
  id: 'm1',
  senderName: 'أحمد',
  senderEmail: '',
  senderUid: 'uid-a',
  text: text,
  sentAt: DateTime(2026, 11, 7, 10),
  imageUrl: imageUrl,
);

void main() {
  test('a reply round-trips through JSON and survives edit and delete', () {
    final original = _message(text: 'هل وصل الرصيد؟');
    final reply = ChatMessage(
      id: 'm2',
      senderName: 'علي',
      senderEmail: '',
      senderUid: 'uid-b',
      text: 'نعم وصل',
      sentAt: DateTime(2026, 11, 7, 10, 1),
      replyTo: ChatReply.of(original),
    );

    final decoded = ChatMessage.fromJson('m2', reply.toJson());
    expect(decoded.replyTo?.messageId, 'm1');
    expect(decoded.replyTo?.senderName, 'أحمد');
    expect(decoded.replyTo?.senderUid, 'uid-a');
    expect(decoded.replyTo?.preview, 'هل وصل الرصيد؟');

    final edited = decoded.copyWith(text: 'نعم', editedAt: DateTime.now());
    expect(edited.replyTo?.messageId, 'm1');
    final deleted = decoded.copyWith(deletedAt: DateTime.now());
    expect(deleted.replyTo?.messageId, 'm1');
    expect(deleted.text, 'نعم وصل');
  });

  test('reply preview is short, and an image reply says صورة', () {
    final long = ChatReply.of(_message(text: 'أ' * 300));
    expect(long.text.length, ChatReply.maxTextLength + 1);
    expect(long.text.endsWith('…'), isTrue);

    final image = ChatReply.of(_message(text: '', imageUrl: 'https://x/y.jpg'));
    expect(image.preview, 'صورة');
    expect(ChatReply.fromJson(null), isNull);
    expect(ChatReply.fromJson({'senderName': 'x'}), isNull);
    expect(ChatMessage.fromJson('m', {'text': 'a'}).replyTo, isNull);
  });

  testWidgets('swiping a message far enough starts a reply', (tester) async {
    var replies = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SwipeToReply(
              onReply: () => replies++,
              child: const SizedBox(
                width: 200,
                height: 60,
                child: Text('رسالة'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.drag(find.text('رسالة'), const Offset(20, 0));
    await tester.pumpAndSettle();
    expect(replies, 0);

    await tester.drag(find.text('رسالة'), const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(replies, 1);

    await tester.drag(find.text('رسالة'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(replies, 2);
  });

  testWidgets('a deleted message cannot be swiped', (tester) async {
    var replies = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SwipeToReply(
            enabled: false,
            onReply: () => replies++,
            child: const SizedBox(
              width: 200,
              height: 60,
              child: Text('محذوفة'),
            ),
          ),
        ),
      ),
    );
    await tester.drag(find.text('محذوفة'), const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(replies, 0);
  });

  testWidgets('the quote shows the author and opens the original', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReplyQuote(
            author: 'أحمد',
            text: 'هل وصل الرصيد؟',
            onMine: false,
            isDark: true,
            onTap: () => taps++,
          ),
        ),
      ),
    );
    expect(find.text('أحمد'), findsOneWidget);
    expect(find.text('هل وصل الرصيد؟'), findsOneWidget);
    await tester.tap(find.text('هل وصل الرصيد؟'));
    expect(taps, 1);
  });
}
