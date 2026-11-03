import 'package:flutter_test/flutter_test.dart';
import 'package:untitled/services/speed_measurement.dart';

const _second = Duration(seconds: 1);

void main() {
  test('download ignores the slow first seconds of the connection', () {
    final meter = ThroughputMeter(warmUp: _second * 2);
    // Slow start: 1 MB in the first two seconds, then 12.5 MB a second (100 Mbps).
    meter.add(1000000, _second);
    for (var second = 2; second < 10; second++) {
      meter.add(12500000, _second * second);
    }
    expect(meter.mbps(_second * 10), closeTo(100, 0.01));
  });

  test('before the warm-up ends the average so far is shown', () {
    final meter = ThroughputMeter(warmUp: _second * 2);
    expect(meter.mbps(_second), isNull);
    meter.add(1250000, _second);
    expect(meter.mbps(_second), closeTo(10, 0.01));
  });

  test('upload drops each connection first request and adds them up', () {
    final first = UploadConnectionMeter()
      ..add(250000, _second) // warm-up: 2 Mbps
      ..add(2500000, _second); // 20 Mbps
    final second = UploadConnectionMeter()..add(1250000, _second); // only one
    expect(first.mbps, closeTo(20, 0.01));
    expect(second.mbps, closeTo(10, 0.01));
    expect(UploadConnectionMeter.totalMbps([first, second]), closeTo(30, 0.01));
    expect(UploadConnectionMeter.totalMbps([UploadConnectionMeter()]), isNull);
  });

  test('ping uses the median, so one slow reply does not skew it', () {
    expect(medianOf([20, 22, 21, 300, 19]), 21);
    expect(medianOf([20, 30]), 25);
  });
}
