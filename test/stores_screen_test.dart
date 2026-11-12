import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/screens/stores_screen.dart';
import 'package:untitled/services/store_directory_service.dart';

Store _store({
  required String key,
  required String name,
  String ownerUid = 'other',
  bool approved = true,
}) =>
    Store(
      key: key,
      name: name,
      url: 'https://$key.example.com',
      ownerUid: ownerUid,
      ownerName: 'مكتب $name',
      approved: approved,
      updatedAt: 1,
    );

void main() {
  testWidgets('shows approved stores and tags the owner pending store',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StoresScreen(
          initialStores: [
            _store(key: 'alef', name: 'ألف'),
            _store(key: 'baa', name: 'باء', ownerUid: 'me', approved: false),
            _store(key: 'jeem', name: 'جيم', ownerUid: 'other', approved: false),
          ],
          currentUidOverride: 'me',
          isAdminOverride: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ألف'), findsOneWidget); // approved → visible
    expect(find.text('باء'), findsOneWidget); // my pending → visible
    expect(find.text('جيم'), findsNothing); // other's pending → hidden
    expect(find.text('قيد المراجعة'), findsWidgets); // my pending is tagged
  });

  testWidgets('add-store dialog rejects a blank name without writing',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StoresScreen(
          initialStores: const [],
          currentUidOverride: 'me',
          isAdminOverride: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('أضف متجري'));
    await tester.pumpAndSettle();
    expect(find.byType(StoreFormDialog), findsOneWidget);

    // Fill only the URL, leave the name blank, then submit.
    await tester.enterText(
      find.byKey(const Key('store-form-url')),
      'https://x.com',
    );
    await tester.tap(find.byKey(const Key('store-form-submit')));
    await tester.pumpAndSettle();

    // Dialog stays open with a validation error; nothing was submitted.
    expect(find.byType(StoreFormDialog), findsOneWidget);
    expect(
      StoreDirectoryService.validateSubmission(
        StoreSubmission(name: '', url: 'https://x.com'),
      ),
      isNotNull,
    );
  });
}
