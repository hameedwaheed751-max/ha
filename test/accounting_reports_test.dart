import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';
import 'package:untitled/sas_api_service.dart';

void main() {
  test('monthly accounting keeps sales and SAS deductions independent', () {
    final summary = AccountingMonthlySummary.fromRecords(
      activations: [
        AccountingActivationRecord(
          subscriberUser: 'subscriber-1',
          subscriberName: 'مشترك',
          packageName: 'باقة',
          saleAmount: 30000,
          sasDeduction: 22000,
          at: DateTime(2026, 3, 10),
        ),
        AccountingActivationRecord(
          subscriberUser: 'subscriber-2',
          subscriberName: 'مشترك آخر',
          packageName: 'باقة أخرى',
          saleAmount: 45000,
          sasDeduction: 31000,
          at: DateTime(2026, 3, 11),
        ),
      ],
    );

    expect(summary.sasDeductions, 53000);
    expect(summary.subscriberSales, 75000);
    expect(summary.profit, 22000);
    expect(summary.activationCount, 2);
  });

  test('activation accounting record preserves optional SAS balances', () {
    final original = AccountingActivationRecord(
      subscriberUser: 'subscriber-1',
      subscriberName: 'مشترك',
      packageName: 'باقة',
      saleAmount: 30000,
      sasDeduction: 22000,
      at: DateTime.utc(2026, 3, 10, 12),
      sasBalanceBefore: 218999,
      sasBalanceAfter: 196999,
    );

    final restored = AccountingActivationRecord.fromJson(original.toJson());

    expect(restored.saleAmount, 30000);
    expect(restored.sasDeduction, 22000);
    expect(restored.profit, 8000);
    expect(restored.sasBalanceBefore, 218999);
    expect(restored.sasBalanceAfter, 196999);
  });

  test('partial paid amount does not change activation sale profit', () {
    const partialPaidAmount = 500.0;
    final subscriptionAmount = 30000.0;
    final sasPackagePrice = 22000.0;
    final record = AccountingActivationRecord(
      subscriberUser: 'subscriber-1',
      subscriberName: 'مشترك',
      packageName: 'Normal',
      saleAmount: subscriptionAmount,
      sasDeduction: sasPackagePrice,
      at: DateTime(2026, 9, 3),
    );

    expect(partialPaidAmount, isNot(record.saleAmount));
    expect(record.profit, 8000);
  });

  test('legacy accounting records still load their stored sale amount', () {
    final record = AccountingActivationRecord.fromJson({
      'subscriberUser': 'subscriber-1',
      'subscriberName': 'مشترك',
      'packageName': 'Normal',
      'paidAmount': 30000,
      'sasDeduction': 22000,
      'at': '2026-09-03T11:10:01',
    });

    expect(record.saleAmount, 30000);
    expect(record.profit, 8000);
    expect(record.needsSaleAmountMigration, isTrue);
  });

  test('SAS financial report payload matches the captured HAR contract', () {
    final journal = SasApiService.buildFinancialReportPayload(
      SasFinancialReportType.managerJournal,
      page: 3,
      count: 25,
      search: 'purchase',
    );
    final activations = SasApiService.buildFinancialReportPayload(
      SasFinancialReportType.activations,
    );

    expect(journal['page'], 3);
    expect(journal['count'], 25);
    expect(journal['sortBy'], 'created_at');
    expect(journal['direction'], 'desc');
    expect(journal['search'], 'purchase');
    expect(
      journal['columns'],
      containsAll(['created_at', 'amount', 'balance', 'operation']),
    );
    expect(activations['sortBy'], 'id');
    expect(
      activations['columns'],
      containsAll(['price', 'user_price', 'activation_method']),
    );
  });

  test('SAS journal classifies deposits and purchases automatically', () {
    final month = SasManagerJournalMonth(
      entries: [
        SasManagerJournalEntry.fromJson({
          'id': 1,
          'created_at': '2026-09-01 09:00:00',
          'cr': 'manager',
          'dr': '_system_',
          'amount': '100000.00',
          'operation': 'إيداع',
          'balance': '300000.00',
        }),
        SasManagerJournalEntry.fromJson({
          'id': 2,
          'created_at': '2026-09-03 11:10:01',
          'cr': '_system_',
          'dr': 'manager',
          'amount': '22000.00',
          'operation': 'purchase',
          'balance': '278000.00',
        }),
      ],
    );

    expect(month.deposits, 100000);
    expect(month.deductions, 22000);
    expect(month.latestBalance, 278000);
  });

  test('SAS financial pages read nested pagination metadata', () {
    final page = SasApiService.parseFinancialReportResponse(
      {
        'data': {
          'data': [
            {'id': 21, 'operation': 'purchase'},
          ],
          'meta': {'current_page': 2, 'last_page': 7, 'total': 61},
        },
      },
      requestedPage: 2,
      requestedCount: 10,
    );

    expect(page.rows, hasLength(1));
    expect(page.rows.single['id'], 21);
    expect(page.currentPage, 2);
    expect(page.lastPage, 7);
    expect(page.total, 61);
  });

  test('SAS activation rows support activation-specific response lists', () {
    final page = SasApiService.parseFinancialReportResponse(
      {
        'result': {
          'activations': [
            {'id': 91, 'created_at': '2026-09-03 10:00:00', 'price': '22000'},
          ],
        },
        'pagination': {'currentPage': 1, 'totalPages': 3, 'totalCount': 25},
      },
      requestedPage: 1,
      requestedCount: 10,
    );

    expect(page.rows, hasLength(1));
    expect(page.rows.single['id'], 91);
    expect(page.lastPage, 3);
    expect(page.total, 25);
  });
}
