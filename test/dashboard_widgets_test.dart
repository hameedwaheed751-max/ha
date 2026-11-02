import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/screens/dashboard_widgets.dart';

void main() {
  testWidgets('DashboardSectionTitle renders title and icon', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DashboardSectionTitle(
            title: 'الوصول السريع',
            icon: Icons.bolt_rounded,
          ),
        ),
      ),
    );

    expect(find.text('الوصول السريع'), findsOneWidget);
    expect(find.byIcon(Icons.bolt_rounded), findsOneWidget);
  });

  testWidgets('DashboardStatTile shows its value and reacts to a tap', (
    tester,
  ) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DashboardStatTile(
            label: 'منتهي',
            value: '45',
            color: Colors.red,
            onTap: () => tapped++,
          ),
        ),
      ),
    );

    expect(find.text('منتهي'), findsOneWidget);
    await tester.tap(find.text('45'));
    expect(tapped, 1);
  });

  testWidgets('DashboardMetricCard renders value and title', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DashboardMetricCard(
            title: 'الرصيد',
            subtitle: 'مؤشر الرصيد',
            value: '1250',
            assetName: 'assets/reference/balance.png',
            color: Colors.green,
          ),
        ),
      ),
    );

    expect(find.text('الرصيد'), findsOneWidget);
    expect(find.text('1250'), findsOneWidget);
  });
}
