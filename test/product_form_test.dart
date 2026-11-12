import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/screens/store_detail_screen.dart';
import 'package:untitled/services/store_directory_service.dart';

void main() {
  testWidgets('product form rejects empty description without submitting',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ProductFormScreen(storeKey: 's1')),
    );
    await tester.pumpAndSettle();

    // Tap save with nothing filled.
    await tester.tap(find.byKey(const Key('product-form-save')));
    await tester.pumpAndSettle();

    // Still on the form, showing the description validation error.
    expect(find.byType(ProductFormScreen), findsOneWidget);
    expect(find.text('اكتب وصف الجهاز'), findsOneWidget);
  });

  testWidgets('product form requires at least one image', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ProductFormScreen(storeKey: 's1')),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('product-form-desc')),
      'راوتر ممتاز للبيع',
    );
    await tester.tap(find.byKey(const Key('product-form-save')));
    await tester.pumpAndSettle();

    expect(find.text('أضف صورة واحدة للجهاز على الأقل'), findsOneWidget);
  });

  test('a store with an empty url is rejected (url required)', () {
    expect(
      StoreDirectoryService.validateSubmission(
        StoreSubmission(name: 'متجري', url: ''),
      ),
      isNotNull,
    );
  });
}
