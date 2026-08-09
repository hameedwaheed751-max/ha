class WhatsAppTemplateParameter {
  const WhatsAppTemplateParameter({
    required this.name,
    required this.text,
  });

  final String name;
  final String text;

  Map<String, String> toMetaJson() => <String, String>{
        'type': 'text',
        'parameter_name': name,
        'text': text,
      };
}

const List<String> canonicalMetaVariableNames = <String>[
  'customer_name',
  'package_name',
  'paid_amount',
  'remaining_amount',
  'subscription_start',
  'subscription_end',
  'agent_name',
  'whatsapp_number',
  'debt_amount',
  'notification_date',
];

const Map<String, String> metaParameterValueNames = <String, String>{
  'اسم المشترك': 'customer_name',
  'مبلغ الدين': 'debt_amount',
  'التاريخ': 'notification_date',
  'اسم الوكيل': 'agent_name',
};

const Map<String, List<String>> metaTemplateParameterNames =
    <String, List<String>>{
  'activated': <String>[
    'customer_name',
    'package_name',
    'paid_amount',
    'remaining_amount',
    'subscription_start',
    'subscription_end',
    'agent_name',
    'whatsapp_number',
  ],
  'expiring': <String>[
    'customer_name',
    'package_name',
    'subscription_end',
    'agent_name',
    'whatsapp_number',
  ],
  'debt_added': <String>[
    'اسم المشترك',
    'مبلغ الدين',
    'التاريخ',
    'اسم الوكيل',
  ],
  'debt_paid': <String>[
    'customer_name',
    'paid_amount',
    'remaining_amount',
    'agent_name',
    'whatsapp_number',
  ],
};

List<WhatsAppTemplateParameter> buildMetaTemplateParameters(
  String templateName,
  Map<String, String> variables,
) {
  final names = metaTemplateParameterNames[templateName];
  if (names == null) {
    throw ArgumentError.value(
      templateName,
      'templateName',
      'No Meta parameter contract is defined for this template',
    );
  }

  return names.map((name) {
    final valueName = metaParameterValueNames[name] ?? name;
    final value = variables[valueName]?.trim() ?? '';
    if (value.isEmpty) {
      throw StateError(
        'Meta template "$templateName" requires a non-empty "$name" value',
      );
    }
    return WhatsAppTemplateParameter(name: name, text: value);
  }).toList(growable: false);
}
