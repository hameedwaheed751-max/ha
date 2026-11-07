import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:untitled/models.dart';
import 'package:untitled/sas_api_service.dart';
import 'package:untitled/sas_sync_service.dart';
import 'package:untitled/screens/extra_sas_section.dart';

/// ساس وهمي: الأساسي بمعرف فارغ، والإضافي بمعرفه.
class _FakeSas extends SasApiService {
  _FakeSas(String account, this.users, {this.sessions = const []})
    : super(
        SasSettings(
          serverUrl: 'https://$account.example.com',
          username: 'm',
          password: 'p',
          accountId: account,
          label: account.isEmpty ? '' : 'ساس $account',
        ),
      );

  final List<Map<String, dynamic>> users;
  final List<Map<String, dynamic>> sessions;

  @override
  Future<dynamic> fetchUsers() async => users;

  @override
  List<Map<String, dynamic>> extractUsers(dynamic response) =>
      List<Map<String, dynamic>>.from(response as List);

  @override
  Future<List<Map<String, dynamic>>> fetchConnectedSessions() async => sessions;

  @override
  Future<List<Map<String, dynamic>>> fetchParents() async => const [];

  @override
  Future<List<Map<String, dynamic>>> fetchProfiles({int? managerId}) async =>
      const [];
}

Map<String, dynamic> _row(String id, String user, String name) => {
  'id': id,
  'username': user,
  'firstname': name,
  'expiration': '2030-01-01',
};

Subscriber _sub(
  String user, {
  String source = 'sas',
  String account = '',
  String sasId = '',
  double debt = 0,
}) => Subscriber(
  user: user,
  name: user,
  phone: '',
  address: '',
  ip: '',
  type: '',
  price: debt,
  startDate: DateTime(2026, 10, 1),
  endDate: DateTime(2026, 11, 1),
  source: source,
  sasId: sasId,
  sasAccount: account,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppStore.subscribers.clear();
    AppStore.packages.clear();
    SasSettings.labels.clear();
  });

  test('the account id round-trips and old records stay primary', () {
    final s = _sub('a', account: 'sas2');
    expect(Subscriber.fromJson(s.toJson()).sasAccount, 'sas2');
    expect(_sub('b').toJson().containsKey('sasAccount'), isFalse);
    expect(Subscriber.fromJson({'user': 'old'}).sasAccount, '');
  });

  test('the same username in two SAS stays two subscribers', () async {
    await SasSyncService.sync(_FakeSas('', [_row('7', 'ali', 'علي أ')]));
    SasSettings.labels['k2'] = 'ساس k2';
    await SasSyncService.sync(_FakeSas('k2', [_row('7', 'ali', 'علي ب')]));

    expect(AppStore.subscribers.length, 2);
    final primary = AppStore.subscribers.firstWhere((s) => s.sasAccount == '');
    final extra = AppStore.subscribers.firstWhere((s) => s.sasAccount == 'k2');
    expect(primary.name, 'علي أ');
    expect(extra.name, 'علي ب');

    // مزامنة الأساسي ثانيةً لا تمس مشترك الساس الآخر بنفس اليوزر والمعرف.
    await SasSyncService.sync(_FakeSas('', [_row('7', 'ali', 'علي أ2')]));
    expect(primary.name, 'علي أ2');
    expect(extra.name, 'علي ب');
    expect(extra.sasAccount, 'k2');
  });

  test('a primary-only agent syncs exactly as before', () async {
    AppStore.subscribers.add(_sub('local1', source: 'local'));
    final result = await SasSyncService.sync(
      _FakeSas('', [_row('1', 'local1', 'محلي'), _row('2', 'new', 'جديد')]),
    );
    expect(result.added, 1);
    expect(result.updated, 1);
    expect(AppStore.subscribers.every((s) => s.sasAccount.isEmpty), isTrue);
    expect(AppStore.subscribers.first.source, 'sas');
  });

  test('an extra SAS adopts a former debtor with the same username', () async {
    AppStore.subscribers.add(
      _sub('owes', source: Subscriber.formerSource, debt: 20000),
    );
    await SasSyncService.sync(_FakeSas('k2', [_row('9', 'owes', 'مدين')]));
    final s = AppStore.subscribers.single;
    expect(s.source, 'sas');
    expect(s.sasAccount, 'k2');
    expect(s.remaining, 20000);
  });

  test('refreshing connections of one SAS leaves the other alone', () async {
    final primary = _sub('p1', sasId: '1')..sasOnline = true;
    final extra = _sub('e1', account: 'k2', sasId: '1')..sasOnline = true;
    AppStore.subscribers.addAll([primary, extra]);

    await SasSyncService.refreshConnections(
      _FakeSas(
        'k2',
        const [],
        sessions: [
          {'username': 'other', 'framedipaddress': '10.0.0.9'},
        ],
      ),
    );
    expect(extra.sasOnline, isFalse);
    expect(primary.sasOnline, isTrue);
  });

  test('deleting an extra SAS removes only its subscribers', () async {
    AppStore.subscribers.addAll([
      _sub('p1'),
      _sub('e1', account: 'k2'),
      _sub('e2', account: 'k2', debt: 5000),
    ]);
    expect(AppStore.countToDelete(all: false), 1);
    expect(AppStore.countToDelete(all: false, account: 'k2'), 2);
    expect(
      AppStore.debtorsAmong(all: false, account: 'k2').map((s) => s.user),
      ['e2'],
    );

    await AppStore.deleteSasSubscribersOnly(account: 'k2', keepDebtors: true);
    expect(AppStore.subscribers.map((s) => s.user), ['p1', 'e2']);
    final kept = AppStore.subscribers.last;
    expect(kept.isFormer, isTrue);
    expect(kept.sasAccount, '');
  });

  testWidgets('on the free trial adding a second SAS asks for a paid plan', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExtraSasSection(
            planAllowsExtra: () => false,
            loadAccounts: () async => const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('إضافة ساس آخر'));
    await tester.pumpAndSettle();
    expect(find.text('تحتاج إلى خطة مدفوعة'), findsOneWidget);
    expect(find.text(ExtraSasSection.paidPlanMessage), findsOneWidget);
    expect(find.byType(ExtraSasDialog), findsNothing);
  });

  testWidgets('on a paid plan the extra SAS form opens', (tester) async {
    AppStore.sasUsername = 'main';
    addTearDown(() => AppStore.sasUsername = '');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExtraSasSection(
            planAllowsExtra: () => true,
            loadAccounts: () async => [
              SasSettings(
                serverUrl: 'https://two.example.com',
                username: 'm2',
                password: 'p',
                accountId: 'k2',
                label: 'ساس الكرادة',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('ساس الكرادة'), findsOneWidget);
    await tester.tap(find.text('إضافة ساس آخر'));
    await tester.pumpAndSettle();
    expect(find.byType(ExtraSasDialog), findsOneWidget);
    expect(find.text('تحتاج إلى خطة مدفوعة'), findsNothing);
  });
}
