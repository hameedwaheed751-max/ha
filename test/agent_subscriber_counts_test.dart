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

  test('counts earthlink and fiberx, and synced sums all SAS providers', () {
    final counts = AgentSubscriberCounts.fromValue([
      {'user': 'a', 'source': 'sas'},
      {'user': 'b', 'source': 'ftth'},
      {'user': 'c', 'source': 'earthlink'},
      {'user': 'd', 'source': 'earthlink'},
      {'user': 'e', 'source': 'fiberx'},
      {'user': 'f', 'source': 'local'},
    ]);
    expect(counts.total, 6);
    expect(counts.sas, 1);
    expect(counts.ftth, 1);
    expect(counts.earthlink, 2);
    expect(counts.fiberx, 1);
    // المجموع الموحّد يشمل كل المزوّدات ولا يحسب المحلي.
    expect(counts.synced, 5);
  });

  test('a pure fiberx agent is not reported as zero-synced', () {
    final counts = AgentSubscriberCounts.fromValue([
      {'user': 'a', 'source': 'fiberx'},
      {'user': 'b', 'source': 'fiberx'},
    ]);
    expect(counts.sas, 0);
    expect(counts.synced, 2);
  });
}
