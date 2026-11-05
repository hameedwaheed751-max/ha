import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:untitled/models.dart';
import 'package:untitled/screens/packages_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppStore.packages.clear();
    AppStore.subscribers.clear();
  });

  test(
    'remote package payloads do not overwrite a freshly changed local package list',
    () {
      AppStore.packages.clear();
      AppStore.addPackage(PackagePlan(name: 'برو', price: 10000));

      AppStore.applyPackagesPayload(<String, dynamic>{
        'pkg_0': {'name': 'قديم', 'price': 5000},
      }, fromRemote: true);

      expect(AppStore.packages.map((e) => e.name), ['برو']);
    },
  );

  testWidgets('adds a manual package, prices it, and deletes it', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: PackagesScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'برو');
    await tester.tap(find.text('إضافة'));
    await tester.pumpAndSettle();

    expect(find.text('برو'), findsOneWidget);
    expect(find.text('يدوية — غير موجودة في الساس'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '20000');
    await tester.pumpAndSettle();
    expect(AppStore.packages.single.price, 20000);
    await tester.tap(find.text('حفظ الأسعار'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(AppStore.packages, isEmpty);
  });

  testWidgets('SAS packages show unpriced and cannot be deleted', (
    tester,
  ) async {
    AppStore.mergeSasPackages(['Fiber 50']);
    await tester.pumpWidget(const MaterialApp(home: PackagesScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Fiber 50'), findsOneWidget);
    expect(find.text('من الساس — أدخل السعر'), findsOneWidget);
    expect(find.text('1 باقة بدون سعر'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });
}
