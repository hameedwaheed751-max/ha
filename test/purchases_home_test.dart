import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/screens/purchases_home_screen.dart';

void main() {
  testWidgets('purchases home shows the two separate entries', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PurchasesHomeScreen()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('purchases-stores')), findsOneWidget);
    expect(find.byKey(const Key('purchases-devices')), findsOneWidget);
    expect(find.text('أضف متجري'), findsOneWidget);
    expect(find.text('انشاء متجر'), findsOneWidget);
  });
}
