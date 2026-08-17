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

const Map<String, List<String>> metaTemplateParameterNames =
    <String, List<String>>{
  'activated_utility': <String>[
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
  'paid_utility': <String>[
    'customer_name',
    'remaining_amount',
    'agent_name',
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
    final value = variables[name]?.trim() ?? '';
    if (value.isEmpty) {
      throw StateError(
        'Meta template "$templateName" requires a non-empty "$name" value',
      );
    }
    return WhatsAppTemplateParameter(name: name, text: value);
  }).toList(growable: false);
}
