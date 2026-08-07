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

  test('remote package payloads do not overwrite a freshly changed local package list', () {
    AppStore.packages.clear();
    AppStore.addPackage(PackagePlan(name: 'برو', price: 10000));

    AppStore.applyPackagesPayload(
      <String, dynamic>{'pkg_0': {'name': 'قديم', 'price': 5000}},
      fromRemote: true,
    );

    expect(AppStore.packages.map((e) => e.name), ['برو']);
  });

  testWidgets('can add and delete a package from the screen', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PackagesScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), 'برو');
    await tester.enterText(find.byType(TextField).at(1), '20000');
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();

    expect(find.text('برو'), findsOneWidget);
    expect(find.text('السعر: 20000'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.text('لا توجد باقات، اضغط + للإضافة'), findsOneWidget);
  });
}
