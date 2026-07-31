import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:untitled/models.dart';
import 'package:untitled/sas_api_service.dart';
import 'package:untitled/sas_sync_service.dart';

class _FakeSasApiService extends SasApiService {
  _FakeSasApiService(this._usersResponse, [this._sessionsResponse]) : super(SasSettings(serverUrl: 'https://example.com', username: 'u', password: 'p'));

  final dynamic _usersResponse;
  final List<Map<String, dynamic>>? _sessionsResponse;

  @override
  Future<dynamic> fetchUsers() async => _usersResponse;

  @override
  Future<List<Map<String, dynamic>>> fetchConnectedSessions() async => _sessionsResponse ?? const [];

  @override
  List<Map<String, dynamic>> extractUsers(dynamic response) {
    if (response is List) {
      return response.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
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

  test('extracts package from nested profile data when syncing SAS subscribers', () async {
    final api = _FakeSasApiService([
      {
        'username': 'user3',
        'firstname': 'Test User 3',
        'expiration': '2030-01-01',
        'profile': {
          'profile_name': 'SAS Gold',
        },
      }
    ]);

    final result = await SasSyncService.sync(api);

    expect(result.added, 1);
    expect(AppStore.subscribers.single.type, 'SAS Gold');
    expect(AppStore.subscribers.single.packageDisplay, 'SAS Gold');
  });

  test('uses IP from nested last session data when syncing SAS subscribers', () async {
    final api = _FakeSasApiService([
      {
        'username': 'user1',
        'firstname': 'Test User',
        'expiration': '2030-01-01',
        'last_session': {
          'ip': '192.168.1.55',
        },
      }
    ]);

    final result = await SasSyncService.sync(api);

    expect(result.added, 1);
    expect(AppStore.subscribers.single.ip, '192.168.1.55');
  });

  test('uses IP from SAS sessions endpoint for the matching subscriber', () async {
    final api = _FakeSasApiService(
      [
        {
          'username': 'user2',
          'firstname': 'Test User 2',
          'expiration': '2030-01-01',
        }
      ],
      [
        {
          'username': 'user2',
          'framed_ip_address': '10.10.10.20',
        }
      ],
    );

    final result = await SasSyncService.sync(api);

    expect(result.added, 1);
    expect(AppStore.subscribers.single.ip, '10.10.10.20');
  });

  test('ignores invalid numeric session IP values like 200', () async {
    final api = _FakeSasApiService(
      [
        {
          'username': 'user5',
          'firstname': 'Test User 5',
          'expiration': '2030-01-01',
        }
      ],
      [
        {
          'username': 'user5',
          'ip': '200',
        }
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
        'last_session': {
          'nas_ip': '172.16.0.10',
        },
      }
    ]);

    final result = await SasSyncService.sync(api);

    expect(result.added, 1);
    expect(AppStore.subscribers.single.ip, '172.16.0.10');
  });

  test('uses client_ip from SAS sessions endpoint for the matching subscriber', () async {
    final api = _FakeSasApiService(
      [
        {
          'username': 'user4',
          'firstname': 'Test User 4',
          'expiration': '2030-01-01',
        }
      ],
      [
        {
          'username': 'user4',
          'client_ip': '192.168.100.5',
        }
      ],
    );

    final result = await SasSyncService.sync(api);

    expect(result.added, 1);
    expect(AppStore.subscribers.single.ip, '192.168.100.5');
  });
}
