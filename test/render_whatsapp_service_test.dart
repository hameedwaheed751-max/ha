import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';
import 'package:untitled/services/render_whatsapp_service.dart';

void main() {
  test('uses the supported English-style debt placeholders in the default template', () {
    expect(AppStore.debtTemplate, contains('{{customer_name}}'));
    expect(AppStore.debtTemplate, contains('{{amount}}'));
    expect(AppStore.debtTemplate, contains('{{date}}'));
    expect(AppStore.debtTemplate, contains('{{agent_name}}'));

    final rendered = RenderWhatsAppService.applyTemplate(AppStore.debtTemplate, {
      'customer_name': 'أحمد',
      'amount': '25000',
      'date': '07/08/2026',
      'agent_name': 'مكتب بغداد',
    });

    expect(rendered, contains('مرحبا أحمد'));
    expect(rendered, contains('المبلغ: 25000 دينار عراقي'));
    expect(rendered, contains('التاريخ: 07/08/2026'));
    expect(rendered, contains('مكتب بغداد'));
  });
}
