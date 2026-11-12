import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/screens/purchases_home_screen.dart';
import 'package:untitled/services/product_service.dart';
import 'package:untitled/services/store_directory_service.dart';

Store _store() => Store(
      key: 's1',
      name: 'متجر ألف',
      url: 'https://alef.example.com',
      ownerUid: 'other',
      ownerName: 'مكتب ألف',
      approved: true,
      updatedAt: 1,
    );

Product _device() => Product(
      key: 'p1',
      storeKey: 'u1',
      ownerUid: 'u1',
      ownerName: 'مكتب النور',
      description: 'جهاز ممتاز',
      images: const ['https://netagentiraq.duckdns.org/uploads/u1/a.jpg'],
      title: 'راوتر AX1500',
      price: 25000,
      currency: 'د.ع',
    );

Widget _app({int tab = 0}) => MaterialApp(
      home: PurchasesHomeScreen(
        initialStores: [_store()],
        initialProducts: [_device()],
        currentUidOverride: 'me',
        isAdminOverride: false,
        initialTab: tab,
      ),
    );

void main() {
  testWidgets('two tabs; stores tab shows only stores + add-store FAB',
      (tester) async {
    await tester.pumpWidget(_app(tab: 0));
    await tester.pumpAndSettle();

    expect(find.text('المتاجر'), findsOneWidget);
    expect(find.text('أجهزة للبيع'), findsOneWidget);

    // Stores tab content only.
    expect(find.text('متجر ألف'), findsOneWidget);
    expect(find.text('راوتر AX1500'), findsNothing);
    expect(find.byKey(const Key('purchases-add-store')), findsOneWidget);
    expect(find.byKey(const Key('purchases-add-device')), findsNothing);
  });

  testWidgets('devices tab shows device posts with the publisher name on top',
      (tester) async {
    await tester.pumpWidget(_app(tab: 1));
    await tester.pumpAndSettle();

    // Devices tab content only — a social-style post: publisher + image + title.
    expect(find.text('راوتر AX1500'), findsOneWidget);
    expect(find.text('مكتب النور'), findsOneWidget); // publisher (agent) name
    expect(find.text('متجر ألف'), findsNothing);
    expect(find.byKey(const Key('purchases-add-device')), findsOneWidget);
    expect(find.byKey(const Key('purchases-add-store')), findsNothing);
  });

  testWidgets('tapping a tab switches which content is shown', (tester) async {
    await tester.pumpWidget(_app(tab: 0));
    await tester.pumpAndSettle();
    expect(find.text('راوتر AX1500'), findsNothing);

    await tester.tap(find.text('أجهزة للبيع'));
    await tester.pumpAndSettle();
    expect(find.text('راوتر AX1500'), findsOneWidget);
  });
}
