import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:untitled/models.dart';
import 'package:untitled/screens/subscribers_screen.dart';

Subscriber _subscriber(String name, int daysLeft, {double price = 0}) {
  final now = DateTime.now();
  return Subscriber(
    user: '$name@test',
    name: name,
    phone: '',
    address: '',
    ip: '100.74.18.165',
    type: 'Normal',
    price: price,
    startDate: now.subtract(const Duration(days: 30)),
    endDate: now.add(Duration(days: daysLeft, hours: 1)),
  );
}

void main() {
  late List<Subscriber> saved;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    saved = List.of(AppStore.subscribers);
    AppStore.subscribers
      ..clear()
      ..addAll([
        _subscriber('سالم', 20),
        _subscriber('كريم', 2),
        _subscriber('ماهر', -5),
      ]);
  });

  tearDown(
    () => AppStore.subscribers
      ..clear()
      ..addAll(saved),
  );

  Future<void> pumpList(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: SubscribersScreen()));
    await tester.pump();
  }

  testWidgets('filter chips narrow the phone cards', (tester) async {
    await pumpList(tester);
    expect(find.text('سالم'), findsOneWidget);
    expect(find.text('ماهر'), findsOneWidget);

    await tester.ensureVisible(find.text('المنتهي (1)'));
    await tester.pump();
    await tester.tap(find.text('المنتهي (1)'));
    await tester.pump();

    expect(find.text('سالم'), findsNothing);
    expect(find.text('ماهر'), findsOneWidget);
  });

  testWidgets('cards label the action by subscription state', (tester) async {
    await pumpList(tester);
    expect(find.text('تجديد'), findsNWidgets(2));
    expect(find.text('تفعيل'), findsOneWidget);
    expect(find.text('قرب الانتهاء'), findsWidgets);
  });

  testWidgets('the view toggle switches to the table', (tester) async {
    await pumpList(tester);
    await tester.tap(find.byTooltip('عرض الجدول'));
    await tester.pump();

    expect(find.text('عمليات سريعة'), findsOneWidget);
    expect(find.text('تجديد'), findsNothing);
  });
}
