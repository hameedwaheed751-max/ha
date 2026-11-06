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

  test('a remote snapshot with a newer subscriber revision but an older '
      'packages revision keeps the local prices', () {
    AppStore.packages.clear();
    AppStore.packagesRevision = 2000;
    AppStore.mergeSasPackages(['Fiber 50']);
    AppStore.packages.single.price = 25000;

    final snapshot = {
      'settings': {'subscribersRevision': 3000, 'packagesRevision': 1000},
      'packagesList': [
        {'name': 'Fiber 50', 'price': 0, 'sas': true},
      ],
    };
    AppStore.applyPackagesPayload(
      snapshot['packagesList'],
      fromRemote: true,
      remoteRevision: AppStore.remotePackagesRevision(snapshot, 3000),
    );
    expect(AppStore.packages.single.price, 25000);

    // نسخة أحدث فعلاً تُطبَّق، ثم لا تعود نسخة أقدم منها.
    AppStore.applyPackagesPayload(
      [
        {'name': 'Fiber 50', 'price': 30000, 'sas': true},
      ],
      fromRemote: true,
      remoteRevision: 4000,
    );
    expect(AppStore.packages.single.price, 30000);
    expect(AppStore.packagesRevision, 4000);
    AppStore.packagesRevision = 0;
  });

  testWidgets('no manual add; Arabic digits price saves automatically', (
    tester,
  ) async {
    AppStore.mergeSasPackages(['Fiber 50']);
    await tester.pumpWidget(const MaterialApp(home: PackagesScreen()));
    await tester.pumpAndSettle();

    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byIcon(Icons.add), findsNothing);

    await tester.enterText(find.byType(TextField), '٢٥٠٠٠');
    await tester.pump();
    expect(find.text('25000'), findsOneWidget);
    expect(AppStore.packages.single.price, 25000);

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('حفظ الأسعار'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('packages'), contains('25000'));
  });

  testWidgets('an old non-SAS package can still be deleted', (tester) async {
    AppStore.addPackage(PackagePlan(name: 'قديمة', price: 5000));
    await tester.pumpWidget(const MaterialApp(home: PackagesScreen()));
    await tester.pumpAndSettle();

    expect(find.text('غير موجودة في الساس'), findsOneWidget);
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
