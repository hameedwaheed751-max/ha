/// Download speed counted after a warm-up, so the slow start of a new
/// connection does not lower the result.
class ThroughputMeter {
  ThroughputMeter({required this.warmUp});

  final Duration warmUp;
  int _bytes = 0;
  int _measuredBytes = 0;

  void add(int bytes, Duration at) {
    _bytes += bytes;
    if (at >= warmUp) _measuredBytes += bytes;
  }

  /// Mbps up to [now]; before the warm-up ends, the average so far.
  double? mbps(Duration now) {
    if (now > warmUp && _measuredBytes > 0) {
      return _measuredBytes * 8 / (now - warmUp).inMicroseconds;
    }
    if (now > Duration.zero && _bytes > 0) {
      return _bytes * 8 / now.inMicroseconds;
    }
    return null;
  }
}

/// One upload connection. Its first request is the warm-up and only counts
/// when the connection finished nothing else.
class UploadConnectionMeter {
  int _requests = 0;
  int _firstBytes = 0;
  Duration _firstTime = Duration.zero;
  int _bytes = 0;
  Duration _time = Duration.zero;

  void add(int bytes, Duration took) {
    if (_requests++ == 0) {
      _firstBytes = bytes;
      _firstTime = took;
    } else {
      _bytes += bytes;
      _time += took;
    }
  }

  double? get mbps {
    if (_time > Duration.zero) return _bytes * 8 / _time.inMicroseconds;
    if (_firstTime > Duration.zero) {
      return _firstBytes * 8 / _firstTime.inMicroseconds;
    }
    return null;
  }

  /// The connections run side by side, so their speeds add up.
  static double? totalMbps(Iterable<UploadConnectionMeter> connections) {
    final rates = connections.map((meter) => meter.mbps).whereType<double>();
    return rates.isEmpty ? null : rates.reduce((a, b) => a + b);
  }
}

double medianOf(List<double> values) {
  final sorted = [...values]..sort();
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
}
