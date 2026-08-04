import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('buildEmptyAgentNodePayload creates an empty isolated agent node payload', () {
    final uid = 'test-account-${DateTime.now().millisecondsSinceEpoch}';

    final payload = AppStore.buildEmptyAgentNodePayload(uid: uid);
    final map = Map<String, dynamic>.from(payload);

    expect(map['subscribers'], isEmpty);
    expect(map['packages'], isEmpty);
    expect(map['messageTemplates'], isA<Map>());
    expect(map['settings'], isA<Map>());
    expect(map['profile'], isA<Map>());
    expect(map['profile']['currentAgentId'], uid);
  });
}
