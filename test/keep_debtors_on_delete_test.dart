import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:untitled/models.dart';
import 'package:untitled/screens/sas_settings_screen.dart';

Subscriber _sub(String user, {String source = 'sas', double debt = 0}) =>
    Subscriber(
      user: user,
      name: 'اسم $user',
      phone: '',
      address: '',
      ip: '',
      type: 'Fiber',
      price: debt,
      paid: 0,
      startDate: DateTime(2026, 10, 1),
      endDate: DateTime(2026, 11, 1),
      source: source,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppStore.subscribers.clear();
    AppStore.dailyTaskEvents.clear();
  });

  test(
    'deleting SAS subscribers can keep debtors as former subscribers',
    () async {
      AppStore.subscribers.addAll([
        _sub('paid1'),
        _sub('owes1', debt: 25000),
        _sub('local1', source: 'local', debt: 5000),
      ]);
      expect(AppStore.countToDelete(all: false), 2);
      expect(AppStore.debtorsAmong(all: false).map((s) => s.user), ['owes1']);
      expect(AppStore.debtorsAmong(all: true).length, 2);

      await AppStore.deleteSasSubscribersOnly(keepDebtors: true);

      expect(AppStore.subscribers.map((s) => s.user), ['owes1', 'local1']);
      final kept = AppStore.subscribers.first;
      expect(kept.isFormer, isTrue);
      expect(kept.remaining, 25000);
      // مشترك سابق لا يحذفه حذف الساس التالي.
      expect(AppStore.countToDelete(all: false), 0);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('subscribers'), contains('former'));
    },
  );

  test('deleting with debts removes debtors too', () async {
    AppStore.subscribers.addAll([_sub('paid1'), _sub('owes1', debt: 25000)]);
    await AppStore.deleteSasSubscribersOnly();
    expect(AppStore.subscribers, isEmpty);
  });

  test('delete all keeping debtors keeps a local debtor local', () async {
    AppStore.subscribers.addAll([
      _sub('paid1', source: 'local'),
      _sub('owes1', debt: 25000),
      _sub('local1', source: 'local', debt: 5000),
    ]);
    await AppStore.deleteAllSubscribers(keepDebtors: true);
    expect(AppStore.subscribers.map((s) => '${s.user}:${s.source}'), [
      'owes1:former',
      'local1:local',
    ]);
  });

  testWidgets('the dialog asks about debtors and shows their total', (
    tester,
  ) async {
    DeleteSubscribersChoice? choice;
    final debtors = [_sub('owes1', debt: 25000), _sub('owes2', debt: 10000)];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              choice = await showDialog<DeleteSubscribersChoice>(
                context: context,
                builder: (_) => DeleteSubscribersDialog(
                  all: false,
                  total: 40,
                  debtors: debtors,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('بينهم 2 مدين'), findsOneWidget);
    expect(find.textContaining('35,000 د.ع'), findsOneWidget);
    await tester.tap(find.text('حذف مع إبقاء المدينين'));
    await tester.pumpAndSettle();
    expect(choice, DeleteSubscribersChoice.keepDebtors);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حذف الجميع مع ديونهم'));
    await tester.pumpAndSettle();
    expect(choice, DeleteSubscribersChoice.deleteEverything);
  });

  testWidgets('without debtors the dialog is a plain delete', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DeleteSubscribersDialog(all: true, total: 3, debtors: []),
      ),
    );
    expect(find.text('حذف'), findsOneWidget);
    expect(find.text('حذف الجميع مع ديونهم'), findsNothing);
  });
}
