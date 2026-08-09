import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';

void main() {
  setUp(AppStore.subscribers.clear);
  tearDown(AppStore.subscribers.clear);

  test('prefers SAS package values when available', () {
    final subscriber = Subscriber(
      user: 'user1',
      name: 'Ahmed',
      phone: '',
      address: '',
      ip: '',
      type: 'باقة محلية',
      price: 0,
      startDate: DateTime.now(),
      endDate: DateTime.now().add(const Duration(days: 30)),
      sasData: {
        'profile_name': 'SAS Gold',
        'package_name': 'SAS Premium',
      },
    );

    expect(subscriber.packageDisplay, 'SAS Gold');
  });

  test('falls back to the stored type when SAS package is missing', () {
    final subscriber = Subscriber(
      user: 'user2',
      name: 'Ali',
      phone: '',
      address: '',
      ip: '',
      type: 'باقة محلية',
      price: 0,
      startDate: DateTime.now(),
      endDate: DateTime.now().add(const Duration(days: 30)),
      sasData: {'status': 'active'},
    );

    expect(subscriber.packageDisplay, 'باقة محلية');
  });

  test('copies SAS profile_name into the subscriber type when loading from JSON', () {
    final subscriber = Subscriber.fromJson({
      'user': 'user3',
      'name': 'Sara',
      'phone': '',
      'address': '',
      'ip': '',
      'type': '',
      'price': 0,
      'startDate': DateTime.now().toIso8601String(),
      'endDate': DateTime.now().add(const Duration(days: 30)).toIso8601String(),
      'sasData': {'profile_name': 'Normal'},
    });

    expect(subscriber.type, 'Normal');
    expect(subscriber.packageDisplay, 'Normal');
  });

  test('updates package display and SAS metadata when package changes', () {
    final subscriber = Subscriber(
      user: 'user4',
      name: 'Omar',
      phone: '',
      address: '',
      ip: '',
      type: 'Old Plan',
      price: 0,
      startDate: DateTime.now(),
      endDate: DateTime.now().add(const Duration(days: 30)),
      sasData: {},
    );

    subscriber.setPackageValue('New Plan');

    expect(subscriber.type, 'New Plan');
    expect(subscriber.packageDisplay, 'New Plan');
    expect(subscriber.sasData['profile_name'], 'New Plan');
    expect(subscriber.sasData['package_name'], 'New Plan');
  });

  test('builds Firebase debts node from current unpaid subscribers only', () {
    final debtor = Subscriber(
      user: 'debtor1',
      name: 'Debtor',
      phone: '9647900000000',
      address: '',
      ip: '',
      type: 'Gold',
      price: 30000,
      paid: 10000,
      startDate: DateTime(2026, 8, 1),
      endDate: DateTime(2026, 9, 1),
      payments: <PaymentRecord>[
        PaymentRecord(
          amount: 10000,
          at: DateTime(2026, 8, 1),
          note: 'دفعة أولى',
        ),
      ],
    );
    final settled = Subscriber(
      user: 'settled1',
      name: 'Settled',
      phone: '',
      address: '',
      ip: '',
      type: 'Normal',
      price: 25000,
      paid: 25000,
      startDate: DateTime(2026, 8, 1),
      endDate: DateTime(2026, 9, 1),
    );
    AppStore.subscribers.addAll(<Subscriber>[debtor, settled]);

    final debts = AppStore.buildDebtsPayload();

    expect(debts, hasLength(1));
    final debt = Map<String, dynamic>.from(debts.values.single as Map);
    expect(debt['user'], 'debtor1');
    expect(debt['subscriptionAmount'], 30000);
    expect(debt['paidAmount'], 10000);
    expect(debt['remainingAmount'], 20000);
    expect(debt['payments'], hasLength(1));
  });
}
