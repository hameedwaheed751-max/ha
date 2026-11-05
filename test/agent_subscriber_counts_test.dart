import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/services/subscription_request_service.dart';

void main() {
  test('counts SAS-synced subscribers from a list or a map', () {
    final list = AgentSubscriberCounts.fromValue([
      {'user': 'a', 'source': 'sas'},
      {'user': 'b', 'source': 'sas'},
      {'user': 'c', 'source': 'ftth'},
      {'user': 'd', 'source': 'local'},
      null,
    ]);
    expect(list.total, 4);
    expect(list.sas, 2);
    expect(list.ftth, 1);

    final map = AgentSubscriberCounts.fromValue({
      '0': {'source': 'sas'},
      '5': {'source': 'local'},
    });
    expect(map.total, 2);
    expect(map.sas, 1);
  });

  test('an agent with no subscribers counts as zero', () {
    final empty = AgentSubscriberCounts.fromValue(null);
    expect(empty.total, 0);
    expect(empty.sas, 0);
  });
}
