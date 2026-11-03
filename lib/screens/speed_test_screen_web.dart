import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/speed_measurement.dart';
import '../services/speed_test_history.dart';
import '../widgets/speed_test_extras.dart';

class SpeedTestScreen extends StatefulWidget {
  const SpeedTestScreen({super.key});

  @override
  State<SpeedTestScreen> createState() => _SpeedTestScreenState();
}

class _SpeedTestScreenState extends State<SpeedTestScreen> {
  static const _speedTestOrigin = 'https://speed.cloudflare.com';
  static const _pingRequests = 6;
  static const _phaseDuration = Duration(seconds: 10);
  static const _warmUp = Duration(seconds: 2);
  static const _downloadConnections = 4;
  static const _downloadRequestBytes = 25 * 1000 * 1000;
  static const _uploadConnections = 3;
  static const _uploadStartBytes = 256 * 1024;
  static const _uploadMaxBytes = 16 * 1024 * 1024;
  static final _uploadPayload = Uint8List(_uploadMaxBytes);

  http.Client? _client;
  bool _isTesting = false;
  int _testRun = 0;
  String _stage = 'جاهز لبدء الاختبار';
  String _stageHint = 'اضغط بدء الاختبار لقياس اتصال المتصفح الحقيقي';
  String? _error;
  String _publicIp = 'غير متاح';
  String _server = 'Cloudflare';
  double _progress = 0;
  double? _ping;
  double? _download;
  double? _upload;
  SpeedTestRecord? _lastResult;
  List<SpeedTestRecord> _history = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadNetworkInfo();
    });
    SpeedTestHistory.load().then((history) {
      if (mounted) setState(() => _history = history);
    });
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }

  bool _isCurrent(int run) => mounted && _isTesting && run == _testRun;

  Uri _speedUri(String path, [Map<String, String>? parameters]) {
    return Uri.parse('$_speedTestOrigin$path').replace(
      queryParameters: {
        ...?parameters,
        'cacheBust': DateTime.now().microsecondsSinceEpoch.toString(),
      },
    );
  }

  Future<void> _loadNetworkInfo() async {
    final client = http.Client();
    try {
      final response = await client
          .get(_speedUri('/meta'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200 || !mounted) return;
      final data = jsonDecode(response.body);
      if (data is! Map) return;
      setState(() {
        _publicIp = (data['clientIp'] ?? data['client_ip'] ?? 'غير متاح')
            .toString();
        final location = [data['city'], data['country']]
            .where(
              (value) => value != null && value.toString().trim().isNotEmpty,
            )
            .join(' - ');
        _server = location.isEmpty ? 'Cloudflare' : 'Cloudflare - $location';
      });
    } catch (_) {
      // Network metadata is optional and does not block the speed test.
    } finally {
      client.close();
    }
  }

  void _cancelTest() {
    if (!_isTesting) return;
    _client?.close();
    _client = null;
    setState(() {
      _testRun++;
      _isTesting = false;
      _stage = 'تم إلغاء الاختبار';
      _stageHint = 'يمكنك بدء اختبار جديد الآن';
      _progress = 0;
    });
  }

  Future<void> _startTest() async {
    if (_isTesting) return;
    _client?.close();
    final client = http.Client();
    _client = client;
    final run = ++_testRun;
    setState(() {
      _isTesting = true;
      _stage = 'جاري اختبار الاتصال...';
      _stageHint = 'قياس زمن الاستجابة عبر HTTP';
      _error = null;
      _progress = 0.02;
      _ping = null;
      _download = null;
      _upload = null;
      _lastResult = null;
    });

    try {
      // The first request also opens the TLS connection, so it is dropped.
      final pingSamples = <double>[];
      for (var index = 0; index < _pingRequests; index++) {
        final stopwatch = Stopwatch()..start();
        final response = await client
            .get(_speedUri('/__down', {'bytes': '0'}))
            .timeout(const Duration(seconds: 8));
        stopwatch.stop();
        if (response.statusCode < 200 || response.statusCode >= 400) {
          throw Exception('خادم القياس أعاد الحالة ${response.statusCode}');
        }
        if (!_isCurrent(run)) return;
        if (index > 0) pingSamples.add(stopwatch.elapsedMicroseconds / 1000);
        setState(() {
          if (pingSamples.isNotEmpty) _ping = medianOf(pingSamples);
          _progress = 0.02 + ((index + 1) / _pingRequests) * 0.08;
        });
      }

      if (!_isCurrent(run)) return;
      setState(() {
        _stage = 'جاري اختبار التحميل...';
        _stageHint = 'تنزيل بيانات فعلية عبر عدة اتصالات لمدة 10 ثوانٍ';
        _progress = 0.10;
      });
      final download = await _measureDownload(run);
      if (!_isCurrent(run)) return;
      setState(() {
        _download = download;
        _stage = 'جاري اختبار الرفع...';
        _stageHint = 'رفع بيانات فعلية عبر عدة اتصالات لمدة 10 ثوانٍ';
        _progress = 0.55;
      });

      final upload = await _measureUpload(run);
      if (!_isCurrent(run)) return;
      final result = SpeedTestRecord(
        at: DateTime.now(),
        ping: _ping ?? 0,
        download: _download ?? 0,
        upload: upload,
        server: _server,
      );
      setState(() {
        _upload = upload;
        _progress = 1;
        _stage = 'اكتمل اختبار السرعة';
        _stageHint = 'النتائج مقاسة من اتصال المتصفح الحالي';
        _lastResult = result;
      });
      final history = await SpeedTestHistory.add(result);
      if (mounted) setState(() => _history = history);
    } catch (error) {
      if (!_isCurrent(run)) return;
      setState(() {
        _stage = 'تعذر إكمال الاختبار';
        _stageHint = 'تحقق من الإنترنت والسماح بالاتصال بخادم Cloudflare';
        _error = error.toString().replaceFirst('Exception: ', '');
        _progress = 0;
      });
    } finally {
      if (mounted && run == _testRun) {
        setState(() => _isTesting = false);
        _client?.close();
        _client = null;
      }
    }
  }

  // Each phase gets its own client; closing it aborts every open request,
  // whether the phase ended or the test was cancelled.
  http.Client _phaseClient() {
    _client?.close();
    final client = http.Client();
    _client = client;
    return client;
  }

  Future<double> _measureDownload(int run) async {
    final client = _phaseClient();
    final meter = ThroughputMeter(warmUp: _warmUp);
    final watch = Stopwatch()..start();

    Future<void> connection() async {
      while (watch.elapsed < _phaseDuration && _isCurrent(run)) {
        final response = await client.send(
          http.Request(
            'GET',
            _speedUri('/__down', {'bytes': '$_downloadRequestBytes'}),
          ),
        );
        if (response.statusCode < 200 || response.statusCode >= 400) {
          throw Exception('تعذر بدء اختبار التحميل (${response.statusCode})');
        }
        await for (final chunk in response.stream) {
          meter.add(chunk.length, watch.elapsed);
          if (watch.elapsed >= _phaseDuration || !_isCurrent(run)) break;
        }
      }
    }

    final progress = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!_isCurrent(run)) return;
      setState(() {
        _download = meter.mbps(watch.elapsed);
        _progress =
            0.10 +
            (watch.elapsed.inMilliseconds / _phaseDuration.inMilliseconds)
                    .clamp(0, 1) *
                0.45;
      });
    });
    try {
      await _runUntilDeadline(
        List.generate(_downloadConnections, (_) => connection()),
        watch,
        client,
      );
    } finally {
      progress.cancel();
    }
    final mbps = meter.mbps(watch.elapsed);
    if (mbps == null || mbps <= 0) {
      throw Exception('لم تصل بيانات اختبار التحميل');
    }
    return mbps;
  }

  Future<double> _measureUpload(int run) async {
    final client = _phaseClient();
    final watch = Stopwatch()..start();
    final connections = List.generate(
      _uploadConnections,
      (_) => UploadConnectionMeter(),
    );

    Future<void> connection(UploadConnectionMeter meter) async {
      var size = _uploadStartBytes;
      while (watch.elapsed < _phaseDuration && _isCurrent(run)) {
        final body = Uint8List.sublistView(_uploadPayload, 0, size);
        final started = watch.elapsed;
        final response = await client.post(
          _speedUri('/__up'),
          headers: const {'Content-Type': 'application/octet-stream'},
          body: body,
        );
        if (response.statusCode < 200 || response.statusCode >= 400) {
          throw Exception('تعذر اختبار الرفع (${response.statusCode})');
        }
        meter.add(size, watch.elapsed - started);
        // Larger requests once the line is known to be fast, so request
        // overhead does not lower the result.
        if (size < _uploadMaxBytes) size *= 2;
      }
    }

    double? total() => UploadConnectionMeter.totalMbps(connections);
    final progress = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!_isCurrent(run)) return;
      setState(() {
        _upload = total();
        _progress =
            0.55 +
            (watch.elapsed.inMilliseconds / _phaseDuration.inMilliseconds)
                    .clamp(0, 1) *
                0.45;
      });
    });
    try {
      await _runUntilDeadline(
        [for (final meter in connections) connection(meter)],
        watch,
        client,
      );
    } finally {
      progress.cancel();
    }
    final mbps = total();
    if (mbps == null || mbps <= 0) throw Exception('تعذر حساب سرعة الرفع');
    return mbps;
  }

  // Waits for the connections until the phase ends, then aborts what is
  // still open. Errors from the abort itself are expected and ignored.
  Future<void> _runUntilDeadline(
    List<Future<void>> connections,
    Stopwatch watch,
    http.Client client,
  ) async {
    final deadline = Timer(_phaseDuration - watch.elapsed, client.close);
    try {
      await Future.wait(
        eagerError: true,
        connections.map(
          (connection) => connection.catchError((Object error) {
            if (watch.elapsed < _phaseDuration && client == _client) {
              throw error;
            }
          }),
        ),
      );
    } finally {
      deadline.cancel();
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF02091A),
        appBar: AppBar(
          backgroundColor: const Color(0xFF02091A),
          foregroundColor: Colors.white,
          title: const Text(
            'اختبار السرعة',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _progressPanel(),
                    const SizedBox(height: 18),
                    _networkPanel(),
                    const SizedBox(height: 28),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final gaugeWidth = (constraints.maxWidth - 16) / 3;
                        return Row(
                          children: [
                            SizedBox(
                              width: gaugeWidth,
                              child: _gauge(
                                'اختبار الاتصال',
                                _ping,
                                'ms',
                                200,
                                const Color(0xFFFF3D6E),
                                true,
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: gaugeWidth,
                              child: _gauge(
                                'التحميل',
                                _download,
                                'Mbps',
                                _speedScale(_download),
                                const Color(0xFFFFAA00),
                                false,
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: gaugeWidth,
                              child: _gauge(
                                'الرفع',
                                _upload,
                                'Mbps',
                                _speedScale(_upload),
                                const Color(0xFF26D8F6),
                                false,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 20),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFFFF829F),
                          fontSize: 12,
                        ),
                      ),
                    ],
                    const SizedBox(height: 28),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _isTesting ? _cancelTest : _startTest,
                          icon: Icon(
                            _isTesting
                                ? Icons.close_rounded
                                : Icons.speed_rounded,
                          ),
                          label: Text(
                            _isTesting
                                ? 'إلغاء الاختبار'
                                : (_ping == null
                                      ? 'بدء الاختبار'
                                      : 'إعادة الاختبار'),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(
                              color: Color(0xFF7C8BA8),
                              width: 1.4,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 28,
                              vertical: 14,
                            ),
                            textStyle: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (_lastResult != null && !_isTesting)
                          FilledButton.icon(
                            onPressed: () =>
                                shareSpeedTestResult(context, _lastResult!),
                            icon: const Icon(Icons.share_rounded),
                            label: const Text('مشاركة النتيجة'),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF0B4DC7),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 28,
                                vertical: 14,
                              ),
                              textStyle: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: LinearProgressIndicator(
                        value: _progress,
                        minHeight: 8,
                        backgroundColor: const Color(0xFF101C36),
                        color: const Color(0xFF23CFF1),
                      ),
                    ),
                    if (_history.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      SpeedTestHistoryPanel(records: _history),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _progressPanel() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF071D4E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF0B4DC7)),
      ),
      child: Column(
        children: [
          Icon(
            _isTesting ? Icons.speed_rounded : Icons.network_check_rounded,
            color: const Color(0xFF2498FF),
            size: 48,
          ),
          const SizedBox(height: 8),
          Text(
            _stage,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _stageHint,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFB7C8EE), fontSize: 12),
          ),
          const SizedBox(height: 10),
          Text(
            '${(_progress * 100).round()}%',
            style: const TextStyle(color: Color(0xFF55C8FF), fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _networkPanel() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
      decoration: BoxDecoration(
        color: const Color(0xFF0C1428),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF263451)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _networkItem(
              Icons.language_rounded,
              'عنوان IP العام',
              _publicIp,
            ),
          ),
          Container(width: 1, height: 42, color: const Color(0xFF263451)),
          Expanded(
            child: _networkItem(Icons.dns_outlined, 'خادم القياس', _server),
          ),
          Container(width: 1, height: 42, color: const Color(0xFF263451)),
          Expanded(
            child: _networkItem(
              Icons.public_rounded,
              'نوع الاتصال',
              'Web HTTP',
            ),
          ),
        ],
      ),
    );
  }

  Widget _networkItem(IconData icon, String label, String value) {
    return Column(
      children: [
        Icon(icon, color: const Color(0xFF24C8FF), size: 18),
        const SizedBox(height: 5),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          label,
          style: const TextStyle(color: Color(0xFF9BA8C2), fontSize: 10),
        ),
      ],
    );
  }

  Widget _gauge(
    String title,
    double? value,
    String unit,
    double maximum,
    Color color,
    bool lowerIsBetter,
  ) {
    final rating = _rating(value, lowerIsBetter);
    final ratingColor = switch (rating) {
      'ممتاز' => const Color(0xFF33D06C),
      'جيد' => const Color(0xFFFFCF25),
      'متوسط' => const Color(0xFFFF8A34),
      'ضعيف' => const Color(0xFFE74B55),
      _ => const Color(0xFF44516B),
    };
    return Column(
      children: [
        Text(
          title,
          maxLines: 1,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        TweenAnimationBuilder<double>(
          tween: Tween(end: value ?? 0),
          duration: const Duration(milliseconds: 350),
          builder: (context, animatedValue, child) => LayoutBuilder(
            builder: (context, constraints) {
              final diameter = math.min(150.0, constraints.maxWidth);
              return SizedBox(
                width: diameter,
                height: diameter,
                child: CustomPaint(
                  painter: _GaugePainter(
                    progress: (animatedValue / maximum).clamp(0, 1),
                    color: color,
                  ),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FittedBox(
                            child: Text(
                              value == null
                                  ? '--'
                                  : animatedValue.toStringAsFixed(1),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          Text(
                            unit,
                            style: const TextStyle(
                              color: Color(0xFFB8C2D8),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Container(
          constraints: const BoxConstraints(minWidth: 70),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: ratingColor,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            rating,
            maxLines: 1,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF07101E),
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ],
    );
  }

  // The smallest gauge scale that fits the speed, so fast lines don't pin it.
  double _speedScale(double? mbps) {
    for (final scale in const [100.0, 200.0, 500.0, 1000.0]) {
      if ((mbps ?? 0) <= scale) return scale;
    }
    return 2500;
  }

  String _rating(double? value, bool lowerIsBetter) {
    if (value == null) return 'بانتظار القياس';
    if (lowerIsBetter) {
      if (value <= 40) return 'ممتاز';
      if (value <= 80) return 'جيد';
      if (value <= 150) return 'متوسط';
      return 'ضعيف';
    }
    if (value >= 50) return 'ممتاز';
    if (value >= 20) return 'جيد';
    if (value >= 5) return 'متوسط';
    return 'ضعيف';
  }
}

class _GaugePainter extends CustomPainter {
  const _GaugePainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 12;
    const startAngle = math.pi * 0.75;
    const sweepAngle = math.pi * 1.5;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final track = Paint()
      ..color = const Color(0xFF263653)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    final arc = Paint()
      ..shader = SweepGradient(
        startAngle: startAngle,
        endAngle: startAngle + sweepAngle,
        colors: [color.withValues(alpha: 0.38), color],
        transform: const GradientRotation(startAngle),
      ).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, startAngle, sweepAngle, false, track);
    if (progress > 0) {
      canvas.drawArc(rect, startAngle, sweepAngle * progress, false, arc);
    }
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
