import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/sas_api_service.dart';

void main() {
  test('SAS debug logger is emitted without network activity', () {
    final messages = <String>[];

    runZoned(
      () {
      SasApiService(
        SasSettings(serverUrl: '', username: '', password: ''),
      );
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, message) => messages.add(message),
      ),
    );

    expect(
      messages,
      contains(contains('[SAS DEBUG][LOGGER READY]')),
    );
  });
}