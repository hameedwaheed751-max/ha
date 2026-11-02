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

  test('a connected session marks the subscriber online', () async {
    final api = _FakeSasApiService(
      [
        {'id': 7, 'username': 'user7', 'expiration': '2030-01-01'},
      ],
      [
        {'username': 'user7', 'framedipaddress': '10.0.0.7'},
      ],
    );

    await SasSyncService.sync(api);

    expect(AppStore.subscribers.single.isOnline, isTrue);
  });

  test('a session id equal to another user id does not move its IP', () async {
    final api = _FakeSasApiService(
      [
        {'id': 5, 'username': 'first', 'expiration': '2030-01-01'},
        {'id': 9, 'username': 'second', 'expiration': '2030-01-01'},
      ],
      [
        {'id': 5, 'username': 'second', 'framedipaddress': '10.0.0.9'},
      ],
    );

    await SasSyncService.sync(api);

    final first = AppStore.subscribers.firstWhere((s) => s.user == 'first');
    final second = AppStore.subscribers.firstWhere((s) => s.user == 'second');
    expect(second.ip, '10.0.0.9');
    expect(first.ip, isNot('10.0.0.9'));
  });

  test('the subscriber IP wins over the server IP in one record', () async {
    final api = _FakeSasApiService([
      {
        'username': 'user8',
        'expiration': '2030-01-01',
        'last_session': {'nas_ip': '172.16.0.1', 'ip': '10.0.0.8'},
      },
    ]);

    await SasSyncService.sync(api);

    expect(AppStore.subscribers.single.ip, '10.0.0.8');
  });

  test('the full SAS name survives a sync', () async {
    final api = _FakeSasApiService([
      {
        'username': 'user6',
        'firstname': 'أحمد',
        'lastname': 'علي',
        'expiration': '2030-01-01',
      },
      {
        'username': 'user9',
        'firstname': 'سعد',
        'lastname': '-',
        'expiration': '2030-01-01',
      },
    ]);

    await SasSyncService.sync(api);

    expect(AppStore.subscribers.map((s) => s.name), ['أحمد علي', 'سعد']);
  });

  test('a second sync with no changes reports nothing updated', () async {
    final api = _FakeSasApiService([
      {
        'id': 11,
        'username': 'stable',
        'firstname': 'Stable',
        'start_date': '2024-01-01T08:30:00',
        'expiration': '2030-01-01',
        'active': 1,
      },
    ]);

    await SasSyncService.sync(api);
    await SasSyncService.sync(api);
    final result = await SasSyncService.sync(api);

    expect(result.updated, 0);
  });

  group('single subscriber refresh', () {
    Subscriber subscriber() {
      final s = Subscriber(
        user: 'single',
        name: 'Single',
        phone: '',
        address: '',
        ip: '',
        type: 'Normal',
        price: 0,
        startDate: DateTime(2026, 1, 1),
        endDate: DateTime(2026, 2, 1),
        sasId: '21',
        active: false,
      );
      s.markActivationDate(at: DateTime(2026, 11, 1));
      return s;
    }

    test('reads a response wrapped in data', () {
      final s = subscriber();

      SasSyncService.applyUserSnapshot(s, {
        'status': 200,
        'data': {
          'id': 21,
          'username': 'single',
          'expiration': '2030-06-01 10:00:00',
          'enabled': 1,
          'last_session': {'framedipaddress': '10.0.0.21'},
        },
      });

      expect(s.endDate, DateTime(2030, 6, 1, 10));
      expect(s.isActive, isTrue);
      expect(s.ip, '10.0.0.21');
      expect(s.sasData.containsKey('data'), isFalse);
    });

    test('keeps the activation day and the end date it did not receive', () {
      final s = subscriber();

      SasSyncService.applyUserSnapshot(s, {
        'id': 21,
        'username': 'single',
        'activation_date': '2024-01-01',
      });

      expect(s.endDate, DateTime(2026, 2, 1));
      expect(s.sasData['activation_date'], s.sasData['local_activation_date']);
    });

    test('ignores an empty response', () {
      final s = subscriber();

      SasSyncService.applyUserSnapshot(s, null);

      expect(s.endDate, DateTime(2026, 2, 1));
    });

    test('shows the IP once the subscriber connects', () async {
      final s = subscriber();
      final api = _FakeSasApiService(const [], [
        {'username': 'single', 'framedipaddress': '10.0.0.21'},
      ]);

      await SasSyncService.refreshConnection(api, s);

      expect(s.ip, '10.0.0.21');
      expect(s.isOnline, isTrue);
    });

    test('leaves a subscriber who has not connected', () async {
      final s = subscriber();

      await SasSyncService.refreshConnection(_FakeSasApiService(const []), s);

      expect(s.ip, '');
      expect(s.sasOnline, isFalse);
    });
  });

  group('quick connection refresh', () {
    Subscriber add(String user, {String ip = '', String source = 'sas'}) {
      final s = Subscriber(
        user: user,
        name: user,
        phone: '',
        address: '',
        ip: ip,
        type: 'Normal',
        price: 0,
        startDate: DateTime(2026, 1, 1),
        endDate: DateTime(2030, 1, 1),
        source: source,
        sasData: const {'online': 1},
      );
      AppStore.subscribers.add(s);
      return s;
    }

    test('updates who is connected and keeps the last known IP', () async {
      final connected = add('on');
      final offline = add('off', ip: '10.0.0.2');

      final online = await SasSyncService.refreshConnections(
        _FakeSasApiService(const [], [
          {'username': 'on', 'framedipaddress': '10.0.0.1'},
        ]),
      );

      expect(online, 1);
      expect(connected.isOnline, isTrue);
      expect(connected.ip, '10.0.0.1');
      expect(offline.isOnline, isFalse);
      expect(offline.ip, '10.0.0.2');
    });

    test('an empty reply leaves everyone as they were', () async {
      final subscriber = add('on');

      final online = await SasSyncService.refreshConnections(
        _FakeSasApiService(const []),
      );

      expect(online, isNull);
      expect(subscriber.isOnline, isTrue);
    });

    test('FTTH subscribers are left alone', () async {
      final ftth = add('fiber', source: 'ftth');

      await SasSyncService.refreshConnections(
        _FakeSasApiService(const [], [
          {'username': 'other', 'framedipaddress': '10.0.0.1'},
        ]),
      );

      expect(ftth.isOnline, isTrue);
    });

    test('a full sync takes over from the quick refresh', () async {
      final subscriber = add('fresh')..liveOnline = false;

      await SasSyncService.sync(
        _FakeSasApiService([
          {'username': 'fresh', 'online': 1, 'expiration': '2030-01-01'},
        ]),
      );

      expect(subscriber.liveOnline, isNull);
      expect(subscriber.isOnline, isTrue);
    });
  });

  test('saving tells open screens the subscribers changed', () async {
    final before = AppStore.subscribersChange.value;

    await AppStore.save();

    expect(AppStore.subscribersChange.value, greaterThan(before));
  });

  test('reads the activation date from a nested SAS response', () {
    final date = SasSyncService.activationDateFromSas({
      'data': {
        'user': {'activated_at': '2026-09-03T14:20:00'},
      },
    });

    expect(date, DateTime(2026, 9, 3, 14, 20));
  });
}
