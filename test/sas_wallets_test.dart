import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';
import 'package:untitled/sas_api_service.dart';
import 'package:untitled/screens/sas_settings_screen.dart';
import 'package:untitled/screens/sas_wallet_breakdown.dart';
import 'package:untitled/services/sas_wallets.dart';

SasSettings _account(String id, {String password = 'p', String label = ''}) =>
    SasSettings(
      serverUrl: 'https://$id.example.com',
      username: 'm',
      password: password,
      accountId: id,
      label: label.isNotEmpty ? label : (id.isEmpty ? 'الأساسي' : 'ساس $id'),
      company: id.isEmpty ? 'الأفق' : '',
    );

Subscriber _sub(
  String user, {
  String account = '',
  String sasId = '',
  Map<String, String> sasIds = const {},
  String source = 'sas',
}) => Subscriber(
  user: user,
  name: user,
  phone: '',
  address: '',
  ip: '',
  type: 'Fiber',
  price: 0,
  paid: 0,
  startDate: DateTime(2026, 11, 1),
  endDate: DateTime(2026, 12, 1),
  source: source,
  sasId: sasId,
  sasAccount: account,
  sasIds: Map<String, String>.from(sasIds),
);

void main() {
  test('each SAS is read through a subscriber of its own', () async {
    final asked = <String, int>{};
    final wallets = await SasWallets.load(
      loadAccounts: () async => [_account(''), _account('k2')],
      subscribers: [
        _sub('a', sasId: '11'),
        _sub('b', account: 'k2', sasId: '22'),
      ],
      fetchWallet: (account, userId) async {
        asked[account.accountId] = userId;
        return {
          'balance': account.isPrimary ? '250,000' : 100000,
          'reward_points': account.isPrimary ? 5 : '7',
        };
      },
    );

    expect(asked, {'': 11, 'k2': 22});
    expect(wallets.several, isTrue);
    expect(wallets.totalBalance, 350000);
    expect(wallets.totalRewardPoints, 12);
  });

  test('a subscriber in two SAS gives each its own id', () {
    final shared = _sub('s', sasId: '11', sasIds: {'k2': '99'});
    expect(SasWallets.userIdIn([shared], ''), 11);
    expect(SasWallets.userIdIn([shared], 'k2'), 99);
    expect(SasWallets.userIdIn([shared], 'k3'), isNull);
  });

  test('an old primary subscriber is found by its stored SAS id', () {
    final old = _sub('o')..sasData['id'] = '44';
    expect(SasWallets.userIdIn([old], ''), 44);
  });

  test('one failing SAS keeps the others and explains itself', () async {
    final wallets = await SasWallets.load(
      loadAccounts: () async => [
        _account(''),
        _account('k2'),
        _account('k3', password: ''),
      ],
      subscribers: [_sub('a', sasId: '11')],
      fetchWallet: (account, userId) async => {'balance': 1000},
    );

    expect(wallets.totalBalance, 1000);
    expect(wallets.items[1].error, contains('زامن'));
    expect(wallets.items[2].error, contains('على هذا الجهاز'));
  });

  test('no balance read means no total', () async {
    final wallets = await SasWallets.load(
      loadAccounts: () async => [_account('')],
      subscribers: [_sub('a', sasId: '11')],
      fetchWallet: (account, userId) async => throw Exception('down'),
    );
    expect(wallets.totalBalance, isNull);
    expect(wallets.items.single.error, contains('down'));
  });

  testWidgets('the breakdown lists every SAS with its balance', (tester) async {
    final wallets = SasWallets([
      SasWallet(account: _account(''), balance: 250000),
      SasWallet(account: _account('k2'), error: 'x'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SasWalletBreakdown(wallets: wallets)),
      ),
    );
    expect(find.text('الأفق — الأساسي'), findsOneWidget);
    expect(find.text(moneyText(250000)), findsOneWidget);
    expect(find.text('ساس k2'), findsOneWidget);
    expect(find.text('غير متاح'), findsOneWidget);
  });

  testWidgets('with several SAS the agent picks one', (tester) async {
    SasSettings? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => picked = await pickSasAccount(
              context,
              loadAccounts: () async => [_account(''), _account('k2')],
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pick-account-k2')));
    await tester.pumpAndSettle();
    expect(picked?.accountId, 'k2');
  });

  testWidgets('with one SAS nothing is asked', (tester) async {
    SasSettings? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => picked = await pickSasAccount(
              context,
              loadAccounts: () async => [_account('')],
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(picked?.isPrimary, isTrue);
  });
}
