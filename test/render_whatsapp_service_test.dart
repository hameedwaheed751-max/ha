import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';
import 'package:untitled/services/render_whatsapp_service.dart';

void main() {
  test('normalizes common Iraqi WhatsApp phone formats', () {
    const expected = '9647900000000';

    expect(RenderWhatsAppService.normalizePhone('0790 000 0000'), expected);
    expect(RenderWhatsAppService.normalizePhone('+964 790 000 0000'), expected);
    expect(RenderWhatsAppService.normalizePhone('00964 790 000 0000'), expected);
    expect(RenderWhatsAppService.normalizePhone('790 000 0000'), expected);
    expect(RenderWhatsAppService.normalizePhone('96407900000000'), expected);
  });

  test('uses the canonical Meta debt placeholders in the default template', () {
    expect(AppStore.debtTemplate, contains('{{customer_name}}'));
    expect(AppStore.debtTemplate, contains('{{paid_amount}}'));
    expect(AppStore.debtTemplate, contains('{{remaining_amount}}'));
    expect(AppStore.debtTemplate, contains('{{agent_name}}'));
    expect(AppStore.debtTemplate, contains('{{whatsapp_number}}'));

    final rendered = RenderWhatsAppService.applyTemplate(AppStore.debtTemplate, {
      'customer_name': 'أحمد',
      'paid_amount': '25000',
      'remaining_amount': '5000',
      'agent_name': 'مكتب بغداد',
      'whatsapp_number': '9647900000000',
    });

    expect(rendered, contains('مرحبا أحمد'));
    expect(rendered, contains('المبلغ الواصل: 25000 دينار عراقي'));
    expect(rendered, contains('المبلغ المتبقي: 5000 دينار عراقي'));
    expect(rendered, contains('مكتب بغداد'));
    expect(rendered, contains('9647900000000'));
  });
}
