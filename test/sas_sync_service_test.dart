import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:untitled/models.dart';
import 'package:untitled/sas_api_service.dart';
import 'package:untitled/sas_sync_service.dart';

class _FakeSasApiService extends SasApiService {
  _FakeSasApiService(this._usersResponse, [this._sessionsResponse])
    : super(
        SasSettings(
          serverUrl: 'https://example.com',
          username: 'u',
          password: 'p',
        ),
      );

  final dynamic _usersResponse;
  final List<Map<String, dynamic>>? _sessionsResponse;

  @override
  Future<dynamic> fetchUsers() async => _usersResponse;

  @override
  Future<List<Map<String, dynamic>>> fetchConnectedSessions() async =>
      _sessionsResponse ?? const [];

  @override
  List<Map<String, dynamic>> extractUsers(dynamic response) {
    if (response is List) {
      return response
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }
}

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    AppStore.subscribers.clear();
  });

  test(
    'extracts package from nested profile data when syncing SAS subscribers',
    () async {
      final api = _FakeSasApiService([
        {
          'username': 'user3',
          'firstname': 'Test User 3',
          'expiration': '2030-01-01',
          'profile': {'profile_name': 'SAS Gold'},
        },
      ]);

      final result = await SasSyncService.sync(api);

      expect(result.added, 1);
      expect(AppStore.subscribers.single.type, 'SAS Gold');
      expect(AppStore.subscribers.single.packageDisplay, 'SAS Gold');
    },
  );

  test(
    'uses IP from nested last session data when syncing SAS subscribers',
    () async {
      final api = _FakeSasApiService([
        {
          'username': 'user1',
          'firstname': 'Test User',
          'expiration': '2030-01-01',
          'last_session': {'ip': '192.168.1.55'},
        },
      ]);

      final result = await SasSyncService.sync(api);

      expect(result.added, 1);
      expect(AppStore.subscribers.single.ip, '192.168.1.55');
    },
  );

  test(
    'uses IP from SAS sessions endpoint for the matching subscriber',
    () async {
      final api = _FakeSasApiService(
        [
          {
            'username': 'user2',
            'firstname': 'Test User 2',
            'expiration': '2030-01-01',
          },
        ],
        [
          {'username': 'user2', 'framed_ip_address': '10.10.10.20'},
        ],
      );

      final result = await SasSyncService.sync(api);

      expect(result.added, 1);
      expect(AppStore.subscribers.single.ip, '10.10.10.20');
    },
  );

  test('ignores invalid numeric session IP values like 200', () async {
    final api = _FakeSasApiService(
      [
        {
          'username': 'user5',
          'firstname': 'Test User 5',
          'expiration': '2030-01-01',
        },
      ],
      [
        {'username': 'user5', 'ip': '200'},
      ],
    );

    final result = await SasSyncService.sync(api);

    expect(result.added, 1);
    expect(AppStore.subscribers.single.ip, '');
  });

  test('uses IP from nested nas_ip when syncing SAS subscribers', () async {
    final api = _FakeSasApiService([
      {
        'username': 'user3',
        'firstname': 'Test User 3',
        'expiration': '2030-01-01',
        'last_session': {'nas_ip': '172.16.0.10'},
      },
    ]);

    final result = await SasSyncService.sync(api);

    expect(result.added, 1);
    expect(AppStore.subscribers.single.ip, '172.16.0.10');
  });

  test(
    'uses client_ip from SAS sessions endpoint for the matching subscriber',
    () async {
      final api = _FakeSasApiService(
        [
          {
            'username': 'user4',
            'firstname': 'Test User 4',
            'expiration': '2030-01-01',
          },
        ],
        [
          {'username': 'user4', 'client_ip': '192.168.100.5'},
        ],
      );

      final result = await SasSyncService.sync(api);

      expect(result.added, 1);
      expect(AppStore.subscribers.single.ip, '192.168.100.5');
    },
  );

  test(
    'preserves the latest activation day across repeated SAS syncs',
    () async {
      final activationDay = DateTime(2026, 9, 3);
      final subscriber = Subscriber(
        user: 'activated-user',
        name: 'Activated User',
        phone: '',
        address: '',
        ip: '',
        type: 'Normal',
        price: 30000,
        startDate: DateTime(2024, 1, 1),
        endDate: DateTime(2030, 1, 1),
        sasId: '42',
      );
      subscriber.markActivationDate(at: activationDay);
      AppStore.subscribers.add(subscriber);

      final api = _FakeSasApiService([
        {
          'id': 42,
          'username': 'activated-user',
          'firstname': 'Activated User',
          'start_date': '2024-01-01',
          'expiration': '2030-01-01',
          'active': 1,
        },
      ]);

      await SasSyncService.sync(api);
      await SasSyncService.sync(api);

      expect(AppStore.subscribers.single.startDate, activationDay);
      expect(
        AppStore.subscribers.single.sasData['local_activation_date'],
        activationDay.toIso8601String(),
      );
    },
  );

  test(
    'prefers the SAS activation date over the account creation date',
    () async {
      final api = _FakeSasApiService([
        {
          'id': 43,
          'username': 'sas-date-user',
          'firstname': 'SAS Date User',
          'activation_date': '2026-09-03T08:30:00',
          'created_at': '2023-02-10T12:00:00',
          'expiration': '2030-01-01',
          'active': 1,
        },
      ]);

      await SasSyncService.sync(api);

      expect(
        AppStore.subscribers.single.startDate,
        DateTime(2026, 9, 3, 8, 30),
      );
    },
  );

  test('reads the activation date from a nested SAS response', () {
    final date = SasSyncService.activationDateFromSas({
      'data': {
        'user': {'activated_at': '2026-09-03T14:20:00'},
      },
    });

    expect(date, DateTime(2026, 9, 3, 14, 20));
  });
}
