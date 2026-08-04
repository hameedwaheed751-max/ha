import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:untitled/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('clearForAccountSwitch clears local state and persisted data for a fresh account', () async {
    SharedPreferences.setMockInitialValues({
      'officeName': 'Old Office',
      'subscribers': '[]',
      'agentName': 'Old Agent',
      'messageTemplates': '{"activation":"old"}',
      'dailyTaskEvents': '[]',
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('officeName', 'Old Office');
    await prefs.setString('subscribers', '[]');
    await prefs.setString('agentName', 'Old Agent');
    await prefs.setString('messageTemplates', '{"activation":"old"}');
    await prefs.setString('dailyTaskEvents', '[]');

    AppStore.officeName = 'Old Office';
    AppStore.agentName = 'Old Agent';
    AppStore.subscribers.add(
      Subscriber(
        user: 'old-user',
        name: 'Old Subscriber',
        phone: '123',
        address: 'Old Address',
        ip: '0.0.0.0',
        type: 'basic',
        price: 50,
        startDate: DateTime.now(),
        endDate: DateTime.now().add(const Duration(days: 30)),
      ),
    );
    AppStore.dailyTaskEvents.add(
      DailyTaskEvent(
        type: 'activation',
        subscriberUser: 'old-user',
        subscriberName: 'Old Subscriber',
        at: DateTime.now(),
      ),
    );
    AppStore.messageTemplates['activation'] = 'old';

    await AppStore.clearForAccountSwitch(clearStorage: true);

    expect(AppStore.subscribers, isEmpty);
    expect(AppStore.dailyTaskEvents, isEmpty);
    expect(AppStore.agentName, isEmpty);
    expect(AppStore.officeName, isEmpty);
    expect(AppStore.messageTemplates['activation'], contains('تم تفعيل'));
    expect(prefs.getString('officeName'), isNull);
    expect(prefs.getString('subscribers'), isNull);
    expect(prefs.getString('messageTemplates'), isNull);
    expect(prefs.getString('dailyTaskEvents'), isNull);
  });
}
