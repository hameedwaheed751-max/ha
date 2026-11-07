import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:untitled/models.dart';
import 'package:untitled/screens/chat_screen.dart';

ChatMessage _msg(String id, String text, {DateTime? deletedAt}) => ChatMessage(
  id: id,
  senderName: 'أحمد',
  senderEmail: '',
  senderUid: 'uid-a',
  text: text,
  sentAt: DateTime(2026, 11, 7, 10),
  deletedAt: deletedAt,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppStore.chatMessages
      ..clear()
      ..addAll([_msg('m2', 'ثانية'), _msg('m1', 'أولى')]);
  });
  tearDown(AppStore.chatMessages.clear);

  test('an edit from another device replaces the message in place', () {
    final before = AppStore.chatMessagesChange.value;
    AppStore.applyChatChange(_msg('m1', 'أولى معدلة'));
    expect(AppStore.chatMessages.map((m) => m.text), ['ثانية', 'أولى معدلة']);
    expect(AppStore.chatMessagesChange.value, before + 1);

    // A change for a message we never loaded does not add it.
    AppStore.applyChatChange(_msg('mx', 'غريبة'));
    expect(AppStore.chatMessages, hasLength(2));
  });

  test('a delete from another device shows as deleted', () {
    AppStore.applyChatChange(_msg('m2', 'ثانية', deletedAt: DateTime.now()));
    expect(AppStore.chatMessages.first.deletedAt, isNotNull);
  });

  test('a removed message leaves the list', () {
    AppStore.applyChatRemoval('m2');
    expect(AppStore.chatMessages.map((m) => m.id), ['m1']);
    final before = AppStore.chatMessagesChange.value;
    AppStore.applyChatRemoval('missing');
    expect(AppStore.chatMessagesChange.value, before);
  });

  test('seen time is saved so the unread count survives a restart', () async {
    AppStore.markChatSeen();
    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    final saved = DateTime.tryParse(prefs.getString('chat_last_seen') ?? '');
    expect(saved, isNotNull);
    expect(DateTime.now().difference(saved!).inSeconds, lessThan(5));
  });

  test('day labels say today, yesterday, or the date', () {
    final now = DateTime(2026, 11, 7, 15);
    expect(chatDayLabel(DateTime(2026, 11, 7, 1), now: now), 'اليوم');
    expect(chatDayLabel(DateTime(2026, 11, 6, 23), now: now), 'أمس');
    expect(chatDayLabel(DateTime(2026, 10, 30), now: now), '30/10/2026');
  });

  testWidgets('the day separator shows its label', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ChatDaySeparator(label: 'أمس'))),
    );
    expect(find.text('أمس'), findsOneWidget);
  });
}
