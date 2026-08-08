import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/services/whatsapp_template_contract.dart';

void main() {
  const values = <String, String>{
    'customer_name': 'أحمد',
    'package_name': 'الباقة الذهبية',
    'paid_amount': '25000',
    'remaining_amount': '5000',
    'subscription_start': '01/08/2026',
    'subscription_end': '01/09/2026',
    'agent_name': 'الوكيل',
    'whatsapp_number': '9647900000000',
  };

  test('activated uses all approved named Meta parameters in order', () {
    final parameters = buildMetaTemplateParameters('activated', values);

    expect(
      parameters.map((parameter) => parameter.name),
      <String>[
        'customer_name',
        'package_name',
        'paid_amount',
        'remaining_amount',
        'subscription_start',
        'subscription_end',
        'agent_name',
        'whatsapp_number',
      ],
    );
    expect(
      parameters.first.toMetaJson(),
      <String, String>{
        'type': 'text',
        'parameter_name': 'customer_name',
        'text': 'أحمد',
      },
    );
  });

  test('expiring uses canonical subscription_end instead of legacy aliases', () {
    final names = buildMetaTemplateParameters('expiring', values)
        .map((parameter) => parameter.name)
        .toList();

    expect(
      names,
      <String>[
        'customer_name',
        'package_name',
        'subscription_end',
        'agent_name',
        'whatsapp_number',
      ],
    );
    expect(names, isNot(contains('subscription_end_date')));
  });

  test('debt templates use canonical payment and balance parameters', () {
    for (final templateName in <String>['debt_added', 'debt_paid']) {
      final names = buildMetaTemplateParameters(templateName, values)
          .map((parameter) => parameter.name)
          .toList();

      expect(
        names,
        <String>[
          'customer_name',
          'paid_amount',
          'remaining_amount',
          'agent_name',
          'whatsapp_number',
        ],
      );
      expect(names, isNot(containsAll(<String>['amount', 'date'])));
    }
  });

  test('missing required values fail before sending an invalid template', () {
    expect(
      () => buildMetaTemplateParameters(
        'activated',
        <String, String>{...values, 'customer_name': ''},
      ),
      throwsStateError,
    );
  });
}
