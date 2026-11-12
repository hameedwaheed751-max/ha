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
      ownerName: 'مكتب',
      description: 'جهاز ممتاز',
      images: const ['https://netagentiraq.duckdns.org/uploads/u1/a.jpg'],
      title: 'راوتر AX1500',
      price: 25000,
      currency: 'د.ع',
    );

void main() {
  testWidgets('purchases page shows devices and stores directly, plus add buttons',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PurchasesHomeScreen(
          initialStores: [_store()],
          initialProducts: [_device()],
          currentUidOverride: 'me',
          isAdminOverride: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Both add-actions and the device marketplace are on the same page.
    expect(find.byKey(const Key('purchases-add-device')), findsOneWidget);
    expect(find.byKey(const Key('purchases-add-store')), findsOneWidget);
    expect(find.text('أجهزة للبيع'), findsOneWidget);
    expect(find.text('راوتر AX1500'), findsOneWidget); // device post, no tap needed

    // The stores section is content on the same page (scroll to reach it).
    await tester.dragUntilVisible(
      find.text('متجر ألف'),
      find.byType(ListView),
      const Offset(0, -250),
    );
    expect(find.text('متجر ألف'), findsOneWidget); // store link
    expect(find.text('المتاجر'), findsOneWidget);
  });

  testWidgets('purchases page shows empty hints with no content', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: PurchasesHomeScreen(
          initialStores: [],
          initialProducts: [],
          currentUidOverride: 'me',
          isAdminOverride: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('لا توجد أجهزة معروضة بعد'), findsOneWidget);
    expect(find.text('لا توجد متاجر بعد'), findsOneWidget);
  });
}
