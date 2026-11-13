import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';
import 'package:untitled/services/trial_guard_service.dart';

void main() {
  group('errorText', () {
    test('surfaces a UserFacingException message, not the generic one', () {
      const msg =
          'استُخدم رقم الهاتف هذا في باقة مجانية سابقة. اختر باقة مدفوعة.';
      expect(errorText(const TrialClaimedException(msg)), msg);
    });

    test('a StateError keeps its own message', () {
      expect(errorText(StateError('رسالة حالة')), 'رسالة حالة');
    });

    test('a truly unknown error falls back to the generic message', () {
      expect(
        errorText(Exception('boom')),
        'حدث خطأ غير متوقع، حاول مرة أخرى',
      );
    });
  });
}
