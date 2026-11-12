import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/screens/store_detail_screen.dart';
import 'package:untitled/services/product_service.dart';

Product _device({String key = 'p1', String owner = 'u1', String title = 'راوتر'}) =>
    Product(
      key: key,
      storeKey: owner,
      ownerUid: owner,
      ownerName: 'مكتب',
      description: 'جهاز ممتاز للبيع',
      images: const ['https://netagentiraq.duckdns.org/uploads/u1/a.jpg'],
      title: title,
      price: 25000,
      currency: 'د.ع',
    );

void main() {
  testWidgets('devices marketplace lists devices and shows the add button',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DevicesScreen(
          initialProducts: [_device(title: 'راوتر AX1500')],
          currentUidOverride: 'me',
          isAdminOverride: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('راوتر AX1500'), findsOneWidget);
    expect(find.byKey(const Key('devices-add')), findsOneWidget);
    expect(find.text('أضف جهازاً'), findsOneWidget);
  });

  testWidgets('devices marketplace shows an empty state with no devices',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DevicesScreen(
          initialProducts: [],
          currentUidOverride: 'me',
          isAdminOverride: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('لا توجد أجهزة معروضة بعد'), findsOneWidget);
  });
}
