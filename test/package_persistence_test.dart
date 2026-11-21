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

  test('keeps local packages when the cloud revision is not newer', () {
    // انحدار: نسخة الجهاز = نسخة السحابة (بعد حفظ ناجح). يجب إبقاء المحلي
    // بأسعاره بدل تطبيق السحابة الأقدم/المساوية ومحو الأسعار المكتوبة.
    expect(
      AppStore.shouldAcceptRemotePackages(
        hasRemotePayload: true,
        allowBootstrap: false,
        remoteRevision: 100,
        localRevision: 100,
      ),
      isFalse,
    );
    expect(
      AppStore.shouldAcceptRemotePackages(
        hasRemotePayload: true,
        allowBootstrap: false,
        remoteRevision: 90,
        localRevision: 100,
      ),
      isFalse,
    );
  });

  test('accepts cloud packages only when newer or bootstrapping', () {
    expect(
      AppStore.shouldAcceptRemotePackages(
        hasRemotePayload: true,
        allowBootstrap: false,
        remoteRevision: 200,
        localRevision: 100,
      ),
      isTrue,
    );
    expect(
      AppStore.shouldAcceptRemotePackages(
        hasRemotePayload: true,
        allowBootstrap: true,
        remoteRevision: 0,
        localRevision: 100,
      ),
      isTrue,
    );
    // لا حمولة في السحابة → لا شيء يُقبل مهما كانت النسخة.
    expect(
      AppStore.shouldAcceptRemotePackages(
        hasRemotePayload: false,
        allowBootstrap: true,
        remoteRevision: 999,
        localRevision: 0,
      ),
      isFalse,
    );
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
