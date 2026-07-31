import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';

Subscriber _subscriber({double price = 100, double paid = 0}) {
  return Subscriber(
    user: 'u1',
    name: 'Test User',
    phone: '',
    address: '',
    ip: '',
    type: 'basic',
    price: price,
    paid: paid,
    startDate: DateTime(2026, 1, 1),
    endDate: DateTime(2026, 2, 1),
  );
}

void main() {
  test('partial payment reduces remaining automatically', () {
    final s = _subscriber(price: 100, paid: 20);

    final applied = s.applyPartialPayment(30, at: DateTime(2026, 7, 30));

    expect(applied, 30);
    expect(s.paid, 50);
    expect(s.remaining, 50);
    expect(s.payments.length, 1);
  });

  test('partial payment cannot exceed remaining', () {
    final s = _subscriber(price: 100, paid: 90);

    final applied = s.applyPartialPayment(50, at: DateTime(2026, 7, 30));

    expect(applied, 10);
    expect(s.paid, 100);
    expect(s.remaining, 0);
    expect(s.payments.length, 1);
  });

  test('setDebtAmounts clamps paid to subscription amount', () {
    final s = _subscriber(price: 120, paid: 30);

    s.setDebtAmounts(subscriptionAmount: 80, paidAmount: 150);

    expect(s.price, 80);
    expect(s.paid, 80);
    expect(s.remaining, 0);
  });

  test('registerInvoiceFromPayment stores invoice with month key', () {
    final s = _subscriber(price: 100, paid: 0);
    final at = DateTime(2026, 7, 30);

    s.registerInvoiceFromPayment(
      receiptNumber: 120,
      amount: 40,
      at: at,
      note: 'فاتورة تسديد جزئي',
    );

    expect(s.invoices.length, 1);
    expect(s.invoices.first.receiptNumber, 120);
    expect(s.invoices.first.monthKey, '2026-07');
    expect(s.invoices.first.amount, 40);
  });

  test('monthly totals are grouped by month', () {
    final s = _subscriber(price: 500, paid: 0);

    s.applyPartialPayment(100, at: DateTime(2026, 7, 1));
    s.applyPartialPayment(50, at: DateTime(2026, 7, 15));
    s.applyPartialPayment(80, at: DateTime(2026, 8, 5));

    s.registerInvoiceFromPayment(receiptNumber: 1, amount: 100, at: DateTime(2026, 7, 1));
    s.registerInvoiceFromPayment(receiptNumber: 2, amount: 50, at: DateTime(2026, 7, 15));
    s.registerInvoiceFromPayment(receiptNumber: 3, amount: 80, at: DateTime(2026, 8, 5));

    expect(s.monthlyPaidTotals['2026-07'], 150);
    expect(s.monthlyPaidTotals['2026-08'], 80);
    expect(s.monthlyInvoiceTotals['2026-07'], 150);
    expect(s.monthlyInvoiceTotals['2026-08'], 80);
  });
}
