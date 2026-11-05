import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';

void main() {
  setUp(AppStore.packages.clear);

  test('SAS packages are added unpriced and keep manual prices', () {
    AppStore.packages.addAll([
      PackagePlan(name: 'Fiber 35', price: 35000),
      PackagePlan(name: 'Old Plan', price: 20000, fromSas: true),
    ]);

    final added = AppStore.mergeSasPackages([
      'fiber 35',
      'Fiber 50',
      'Fiber 50',
      '',
      '—',
    ]);

    expect(added, 1);
    final byName = {for (final p in AppStore.packages) p.name: p};
    expect(byName['Fiber 35']!.price, 35000);
    expect(byName['Fiber 35']!.fromSas, isTrue);
    expect(byName['Fiber 50']!.price, 0);
    expect(byName['Fiber 50']!.fromSas, isTrue);
    // لم تعد في الساس: تبقى بسعرها وتظهر يدوية.
    expect(byName['Old Plan']!.price, 20000);
    expect(byName['Old Plan']!.fromSas, isFalse);
  });

  test('an empty SAS read changes nothing', () {
    AppStore.packages.add(PackagePlan(name: 'A', price: 1, fromSas: true));
    expect(AppStore.mergeSasPackages(const []), 0);
    expect(AppStore.packages.single.fromSas, isTrue);
  });

  test('the SAS flag survives JSON', () {
    final plan = PackagePlan.fromJson(
      PackagePlan(name: 'X', price: 5, fromSas: true).toJson(),
    );
    expect(plan.fromSas, isTrue);
    expect(PackagePlan.fromJson({'name': 'Y', 'price': 7}).fromSas, isFalse);
  });

  test('a partial list adds packages without unmarking others', () {
    AppStore.packages.add(
      PackagePlan(name: 'Unused', price: 9000, fromSas: true),
    );
    final added = AppStore.mergeSasPackages(['Fiber 50'], complete: false);
    expect(added, 1);
    expect(AppStore.packages.every((p) => p.fromSas), isTrue);
  });
}
