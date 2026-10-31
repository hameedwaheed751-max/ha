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

  group('local data ownership', () {
    test('a recorded owner only matches the same account', () {
      expect(
        AppStore.isLocalDataOwnedBy(
          storedOwnerUid: 'agent-a',
          storedEmail: 'b@example.com',
          uid: 'agent-b',
          email: 'b@example.com',
        ),
        isFalse,
      );
      expect(
        AppStore.isLocalDataOwnedBy(
          storedOwnerUid: 'agent-a',
          storedEmail: 'old@example.com',
          uid: 'agent-a',
          email: 'new@example.com',
        ),
        isTrue,
      );
    });

    test('data without an owner is matched by email and never guessed', () {
      expect(
        AppStore.isLocalDataOwnedBy(
          storedOwnerUid: null,
          storedEmail: ' Agent@Example.com ',
          uid: 'agent-a',
          email: 'agent@example.com',
        ),
        isTrue,
      );
      expect(
        AppStore.isLocalDataOwnedBy(
          storedOwnerUid: null,
          storedEmail: 'other@example.com',
          uid: 'agent-a',
          email: 'agent@example.com',
        ),
        isFalse,
      );
      expect(
        AppStore.isLocalDataOwnedBy(
          storedOwnerUid: null,
          storedEmail: '',
          uid: 'agent-a',
          email: 'agent@example.com',
        ),
        isFalse,
      );
    });

    test('another account cannot inherit cached data or its revision', () async {
      SharedPreferences.setMockInitialValues({
        AppStore.localDataOwnerKey: 'agent-a',
        'subscribers': '[{"user":"a-subscriber"}]',
        'subscribers_backup': '[{"user":"a-subscriber"}]',
        AppStore.subscribersRevisionKey: 9000,
        AppStore.dailyTaskEventsKey: '[{"type":"activation"}]',
        'sas_server_url': 'https://sas-a.example.com',
        'sas_manager_username': 'a-manager',
        'ftth_sas_username': 'a-ftth',
        'rememberMe': true,
      });

      await AppStore.claimLocalDataFor(
        uid: 'agent-b',
        email: 'b@example.com',
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppStore.localDataOwnerKey), 'agent-b');
      expect(prefs.getString('subscribers'), isNull);
      expect(prefs.getString('subscribers_backup'), isNull);
      expect(prefs.getInt(AppStore.subscribersRevisionKey), isNull);
      expect(prefs.getString(AppStore.dailyTaskEventsKey), isNull);
      expect(prefs.getString('sas_server_url'), isNull);
      expect(prefs.getString('sas_manager_username'), isNull);
      expect(prefs.getString('ftth_sas_username'), isNull);
      expect(prefs.getBool('rememberMe'), isTrue);
    });

    test('the same account keeps its cached data', () async {
      SharedPreferences.setMockInitialValues({
        AppStore.localDataOwnerKey: 'agent-a',
        'subscribers': '[{"user":"a-subscriber"}]',
        AppStore.subscribersRevisionKey: 9000,
      });

      await AppStore.claimLocalDataFor(
        uid: 'agent-a',
        email: 'a@example.com',
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('subscribers'), '[{"user":"a-subscriber"}]');
      expect(prefs.getInt(AppStore.subscribersRevisionKey), 9000);
    });
  });
}
