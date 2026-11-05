import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/services/trial_guard_service.dart';

void main() {
  test('phone formats of the same number share one fingerprint', () {
    final hashes = {
      for (final phone in [
        '07701234567',
        '+964 770 123 4567',
        '9647701234567',
        '٠٧٧٠١٢٣٤٥٦٧',
      ])
        TrialGuardService.phoneHash(phone),
    };
    expect(hashes, hasLength(1));
    expect(hashes.single, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(TrialGuardService.phoneHash('07701234568'), isNot(hashes.single));
  });

  test('SAS server spellings share one fingerprint', () {
    final a = TrialGuardService.sasHash(
      'https://www.Sas.Example.iq/admin',
      'Ali',
    );
    final b = TrialGuardService.sasHash('sas.example.iq', ' ali ');
    expect(a, b);
    expect(TrialGuardService.sasHash('sas.example.iq', 'omar'), isNot(a));
    // نفس الاسم في ساس مختلف بصمة أخرى.
    expect(TrialGuardService.sasHash('other.iq', 'ali'), isNot(a));
  });

  test('kinds never collide', () {
    expect(
      TrialGuardService.ftthHash('ali'),
      isNot(TrialGuardService.sasHash('', 'ali')),
    );
  });

  test('without Firebase the guard never blocks', () async {
    await TrialGuardService.ensureSasAllowed('sas.example.iq', 'ali');
    await TrialGuardService.ensureFtthAllowed('ali');
  });
}
