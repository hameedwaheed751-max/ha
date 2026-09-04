import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_network_speed_test/flutter_network_speed_test.dart';

class SpeedTestScreen extends StatefulWidget {
  const SpeedTestScreen({super.key});

  @override
  State<SpeedTestScreen> createState() => _SpeedTestScreenState();
}

class _SpeedTestScreenState extends State<SpeedTestScreen> {
  bool _isTesting = false;
  bool _cancelled = false;
  int _testRun = 0;
  String _stage = 'جاهز لبدء الاختبار';
  String _stageHint = 'اضغط بدء الاختبار لقياس اتصالك الحقيقي';
  String? _error;
  String _localIp = 'غير متاح';
  String _networkName = 'غير متاح';
  String _connectionType = 'غير متاح';
  double _overallProgress = 0;
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

  Future<void> _loadNetworkInfo() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final usable = interfaces
          .where((item) => item.addresses.isNotEmpty)
          .toList();
      if (!mounted || usable.isEmpty) return;
      setState(() {
        _networkName = usable.first.name;
        _localIp = usable.first.addresses.first.address;
        _connectionType = _typeOfInterface(usable.first.name);
      });
    } catch (_) {}
  }

  String _typeOfInterface(String name) {
    final normalized = name.toLowerCase();
    if (normalized.contains('wlan') ||
        normalized.contains('wifi') ||
        normalized.contains('wi-fi')) {
      return 'Wi-Fi';
    }
    if (normalized.contains('rmnet') ||
        normalized.contains('ccmni') ||
        normalized.contains('pdp') ||
        normalized.contains('cell')) {
      return 'بيانات الهاتف';
    }
    if (normalized.contains('eth')) return 'Ethernet';
    return 'اتصال شبكي';
  }

  bool _isCurrentRun(int run) => mounted && !_cancelled && run == _testRun;

  void _cancelTest() {
    if (!_isTesting) return;
    setState(() {
      _cancelled = true;
      _testRun++;
      _isTesting = false;
      _stage = 'تم إلغاء الاختبار';
      _stageHint = 'يمكنك بدء اختبار جديد الآن';
      _overallProgress = 0;
    });
  }

  Future<void> _startTest() async {
    if (_isTesting) return;
    final run = ++_testRun;
    setState(() {
      _isTesting = true;
      _cancelled = false;
      _stage = 'جاري اختيار أفضل خادم...';
      _stageHint = 'يرجى الانتظار، قد يستغرق الاختبار عدة ثوانٍ';
      _error = null;
      _overallProgress = 0;
      _ping = null;
      _download = null;
      _upload = null;
    });

    final speedTest = SpeedTest(
      const SpeedTestArgs(
        duration: Duration(seconds: 10),
        httpTimeout: Duration(seconds: 8),
        progressInterval: Duration(milliseconds: 200),
        numberOfPings: 5,
      ),
    );

    try {
      await speedTest.init();
      if (!_isCurrentRun(run)) return;
      setState(() {
        _stage = 'جاري اختبار الاتصال...';
        _stageHint = 'قياس زمن الاستجابة الحقيقي';
        _overallProgress = 0.04;
      });

      final ping = await speedTest.testPing(
        onProgress: (milliseconds, progress, index) {
          if (!_isCurrentRun(run)) return;
          setState(() {
            _ping = milliseconds.toDouble();
            _overallProgress = 0.04 + progress.clamp(0, 1) * 0.16;
          });
        },
      );
      if (!_isCurrentRun(run)) return;
      setState(() {
        _ping = ping;
        _stage = 'جاري اختبار التحميل...';
        _stageHint = 'جارٍ تنزيل بيانات الاختبار من أفضل خادم';
        _overallProgress = 0.20;
      });

      final download = await speedTest.testDownloadSpeed(
        onProgress: (mbps, progress, time) {
          if (!_isCurrentRun(run)) return;
          setState(() {
            _download = mbps;
            _overallProgress = 0.20 + progress.clamp(0, 1) * 0.42;
          });
        },
      );
      if (!_isCurrentRun(run)) return;
      setState(() {
        _download = download;
        _stage = 'جاري اختبار الرفع...';
        _stageHint = 'جارٍ رفع بيانات الاختبار إلى أفضل خادم';
        _overallProgress = 0.62;
      });

      final upload = await speedTest.testUploadSpeed(
        onProgress: (mbps, progress, time) {
          if (!_isCurrentRun(run)) return;
          setState(() {
            _upload = mbps;
            _overallProgress = 0.62 + progress.clamp(0, 1) * 0.38;
          });
        },
      );
      if (!_isCurrentRun(run)) return;
      setState(() {
        _upload = upload;
        _stage = 'اكتمل اختبار السرعة';
        _stageHint = 'النتائج المعروضة مقاسة من اتصالك الحالي';
        _overallProgress = 1;
      });
    } catch (error) {
      if (!_isCurrentRun(run)) return;
      setState(() {
        _stage = 'تعذر إكمال الاختبار';
        _stageHint = 'تحقق من اتصال الإنترنت ثم أعد المحاولة';
        _error = error.toString();
        _overallProgress = 0;
      });
    } finally {
      if (_isCurrentRun(run)) setState(() => _isTesting = false);
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
          elevation: 0,
          title: const Text(
            'اختبار السرعة',
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          centerTitle: true,
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
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
                        return Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          runSpacing: 24,
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
                              : Icons.refresh_rounded,
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
                    const SizedBox(height: 28),
                    Text(
                      _isTesting ? 'جارٍ إجراء الاختبار...' : _stage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFAAB5CC),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: LinearProgressIndicator(
                        value: _overallProgress,
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
    final percent = (_overallProgress * 100).round();
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF071D4E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF0B4DC7)),
        boxShadow: const [BoxShadow(color: Color(0x550847BE), blurRadius: 26)],
      ),
      child: Column(
        children: [
          Icon(
            _isTesting ? Icons.speed_rounded : Icons.network_check_rounded,
            color: const Color(0xFF2498FF),
            size: 52,
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
          const SizedBox(height: 12),
          Text(
            '$percent%',
            style: const TextStyle(color: Color(0xFF55C8FF), fontSize: 16),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _overallProgress,
              minHeight: 7,
              backgroundColor: const Color(0xFF102A60),
              color: const Color(0xFF25A8FF),
            ),
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
            child: _networkItem(Icons.language_rounded, 'عنوان IP', _localIp),
          ),
          Container(width: 1, height: 42, color: const Color(0xFF263451)),
          Expanded(
            child: _networkItem(
              Icons.signal_cellular_alt_rounded,
              'واجهة الشبكة',
              _networkName,
            ),
          ),
          Container(width: 1, height: 42, color: const Color(0xFF263451)),
          Expanded(
            child: _networkItem(
              Icons.public_rounded,
              'نوع الاتصال',
              _connectionType,
            ),
          ),
        ],
      ),
    );
  }

  Widget _networkItem(IconData icon, String label, String value) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: const Color(0xFF24C8FF), size: 18),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
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
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        TweenAnimationBuilder<double>(
          tween: Tween(end: value ?? 0),
          duration: const Duration(milliseconds: 450),
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
                      padding: const EdgeInsets.all(18),
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
                                fontSize: 29,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          FittedBox(
                            child: Text(
                              unit,
                              style: const TextStyle(
                                color: Color(0xFFB8C2D8),
                                fontSize: 14,
                              ),
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
          constraints: const BoxConstraints(minWidth: 72),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: ratingColor,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            rating,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF07101E),
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
