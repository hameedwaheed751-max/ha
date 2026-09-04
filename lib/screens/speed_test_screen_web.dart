import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class SpeedTestScreen extends StatefulWidget {
  const SpeedTestScreen({super.key});

  @override
  State<SpeedTestScreen> createState() => _SpeedTestScreenState();
}

class _SpeedTestScreenState extends State<SpeedTestScreen> {
  static const _speedTestOrigin = 'https://speed.cloudflare.com';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadNetworkInfo();
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
    });

    try {
      final pingSamples = <double>[];
      for (var index = 0; index < 5; index++) {
        final stopwatch = Stopwatch()..start();
        final response = await client
            .get(_speedUri('/__down', {'bytes': '0'}))
            .timeout(const Duration(seconds: 8));
        stopwatch.stop();
        if (response.statusCode < 200 || response.statusCode >= 400) {
          throw Exception('خادم القياس أعاد الحالة ${response.statusCode}');
        }
        if (!_isCurrent(run)) return;
        pingSamples.add(stopwatch.elapsedMicroseconds / 1000);
        setState(() {
          _ping = pingSamples.reduce((a, b) => a + b) / pingSamples.length;
          _progress = 0.04 + ((index + 1) / 5) * 0.16;
        });
      }

      if (!_isCurrent(run)) return;
      setState(() {
        _stage = 'جاري اختبار التحميل...';
        _stageHint = 'تنزيل بيانات فعلية من خادم القياس';
        _progress = 0.20;
      });

      const downloadBytes = 8 * 1024 * 1024;
      final request = http.Request(
        'GET',
        _speedUri('/__down', {'bytes': '$downloadBytes'}),
      );
      final stopwatch = Stopwatch()..start();
      final streamedResponse = await client
          .send(request)
          .timeout(const Duration(seconds: 15));
      if (streamedResponse.statusCode < 200 ||
          streamedResponse.statusCode >= 400) {
        throw Exception(
          'تعذر بدء اختبار التحميل (${streamedResponse.statusCode})',
        );
      }
      var receivedBytes = 0;
      await for (final chunk in streamedResponse.stream.timeout(
        const Duration(seconds: 30),
      )) {
        receivedBytes += chunk.length;
        if (!_isCurrent(run)) return;
        final seconds =
            stopwatch.elapsedMicroseconds / Duration.microsecondsPerSecond;
        setState(() {
          if (seconds > 0) _download = receivedBytes * 8 / seconds / 1000000;
          _progress = 0.20 + (receivedBytes / downloadBytes).clamp(0, 1) * 0.42;
        });
      }
      stopwatch.stop();
      if (!_isCurrent(run)) return;
      final downloadSeconds =
          stopwatch.elapsedMicroseconds / Duration.microsecondsPerSecond;
      if (receivedBytes == 0 || downloadSeconds <= 0)
        throw Exception('لم تصل بيانات اختبار التحميل');
      setState(() {
        _download = receivedBytes * 8 / downloadSeconds / 1000000;
        _stage = 'جاري اختبار الرفع...';
        _stageHint = 'رفع بيانات فعلية إلى خادم القياس';
        _progress = 0.64;
      });

      const uploadBytes = 3 * 1024 * 1024;
      final uploadData = Uint8List(uploadBytes);
      for (var index = 0; index < uploadData.length; index += 4096) {
        uploadData[index] = index % 251;
      }
      final uploadWatch = Stopwatch()..start();
      final uploadResponse = await client
          .post(
            _speedUri('/__up'),
            headers: const {'Content-Type': 'application/octet-stream'},
            body: uploadData,
          )
          .timeout(const Duration(seconds: 45));
      uploadWatch.stop();
      if (uploadResponse.statusCode < 200 || uploadResponse.statusCode >= 400) {
        throw Exception('تعذر اختبار الرفع (${uploadResponse.statusCode})');
      }
      if (!_isCurrent(run)) return;
      final uploadSeconds =
          uploadWatch.elapsedMicroseconds / Duration.microsecondsPerSecond;
      if (uploadSeconds <= 0) throw Exception('تعذر حساب سرعة الرفع');
      setState(() {
        _upload = uploadBytes * 8 / uploadSeconds / 1000000;
        _progress = 1;
        _stage = 'اكتمل اختبار السرعة';
        _stageHint = 'النتائج مقاسة من اتصال المتصفح الحالي';
      });
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
        client.close();
        if (identical(_client, client)) _client = null;
      }
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
                                100,
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
                                100,
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
                    Align(
                      child: OutlinedButton.icon(
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
    if (progress > 0)
      canvas.drawArc(rect, startAngle, sweepAngle * progress, false, arc);
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
