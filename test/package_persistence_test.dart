import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:untitled/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppStore.packages.clear();
    AppStore.subscribers.clear();
    AppStore.messageTemplates.clear();
  });

  test('packages persist across save and reload from Firebase-style payload', () async {
    AppStore.packages.addAll([
      PackagePlan(name: 'أساسي', price: 10000),
      PackagePlan(name: 'برو', price: 20000),
    ]);

    await AppStore.save();

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('packages');
    expect(raw, isNotNull);
    final decoded = jsonDecode(raw!);
    expect(decoded, isA<List>());

    AppStore.packages.clear();
    AppStore.packages.applyPayload(decoded);

    expect(AppStore.packages.map((e) => e.name), ['أساسي', 'برو']);
    expect(AppStore.packages.map((e) => e.price), [10000.0, 20000.0]);

    AppStore.packages.clear();
    AppStore.packages.applyPayload({
      'pkg_0': {'name': 'أساسي', 'price': 10000},
      'pkg_1': {'name': 'برو', 'price': 20000},
    });

    expect(AppStore.packages.map((e) => e.name), ['أساسي', 'برو']);
  });

  test('add and remove package operations update the store list', () async {
    AppStore.addPackage(PackagePlan(name: 'أساسي', price: 10000));
    AppStore.addPackage(PackagePlan(name: 'برو', price: 20000));

    expect(AppStore.packages.length, 2);
    expect(AppStore.packages.map((e) => e.name), ['أساسي', 'برو']);

    AppStore.removePackage(AppStore.packages.first);
    expect(AppStore.packages.length, 1);
    expect(AppStore.packages.single.name, 'برو');
  });
}
