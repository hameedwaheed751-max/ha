import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping_ios/dart_ping_ios.dart';
import 'package:flutter/material.dart';

class _PingAttempt {
  const _PingAttempt({
    required this.sequence,
    this.address,
    this.ttl,
    this.duration,
    this.error,
  });

  final int sequence;
  final String? address;
  final int? ttl;
  final Duration? duration;
  final String? error;

  bool get received => duration != null && error == null;
}

class PingScreen extends StatefulWidget {
  const PingScreen({super.key});

  @override
  State<PingScreen> createState() => _PingScreenState();
}

class _PingScreenState extends State<PingScreen> {
  final _targetController = TextEditingController();
  bool _testing = false;
  String? _error;
  List<_PingAttempt> _attempts = const [];
  int _sent = 0;
  int _received = 0;
  Ping? _activePing;

  @override
  void dispose() {
    final activePing = _activePing;
    if (activePing != null) unawaited(activePing.stop());
    _targetController.dispose();
    super.dispose();
  }

  String _normalizeHost(String value) {
    final trimmed = value.trim();
    final uri = Uri.tryParse(
      trimmed.contains('://') ? trimmed : 'https://$trimmed',
    );
    return uri?.host.isNotEmpty == true ? uri!.host : trimmed;
  }

  Future<void> _runPing() async {
    final host = _normalizeHost(_targetController.text);
    if (_testing) return;
    if (host.isEmpty) {
      setState(() => _error = 'أدخل IP أو اسم مضيف صحيحاً.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _testing = true;
      _error = null;
      _attempts = const [];
      _sent = 0;
      _received = 0;
    });

    if (Platform.isIOS) DartPingIOS.register();
    final attempts = <_PingAttempt>[];
    var sent = 0;
    var received = 0;
    try {
      final ping = Ping(host, timeout: 2);
      _activePing = ping;
      await for (final data in ping.stream) {
        if (!mounted) return;
        final response = data.response;
        if (response != null) {
          attempts.add(
            _PingAttempt(
              sequence: attempts.length + 1,
              address: response.ip,
              ttl: response.ttl,
              duration: response.time,
              error: data.error == null ? null : _errorLabel(data.error!),
            ),
          );
          sent = attempts.length;
          received = attempts.where((attempt) => attempt.received).length;
        } else if (data.error != null && data.summary == null) {
          _error = _errorLabel(data.error!);
        }
        final summary = data.summary;
        if (summary != null) {
          sent = summary.transmitted;
          received = summary.received;
          while (attempts.length < sent) {
            attempts.add(
              _PingAttempt(sequence: attempts.length + 1, error: 'لم يصل رد'),
            );
          }
        }
        setState(() {
          _attempts = List.unmodifiable(attempts);
          _sent = sent;
          _received = received;
        });
      }
      if (sent == 0 && attempts.isEmpty) {
        throw Exception('لم يتمكن النظام من إرسال طلبات ICMP إلى الهدف');
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      _activePing = null;
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _stopPing() async {
    final ping = _activePing;
    if (ping == null) return;
    try {
      await ping.stop();
    } catch (_) {
      if (mounted) setState(() => _testing = false);
    }
  }

  String _errorLabel(PingError error) {
    switch (error.error) {
      case ErrorType.requestTimedOut:
        return 'انتهت مهلة الطلب';
      case ErrorType.unknownHost:
        return 'تعذر العثور على المضيف';
      case ErrorType.timeToLiveExceeded:
        return 'انتهت قيمة TTL قبل الوصول';
      case ErrorType.noReply:
        return 'لم يصل رد';
      case ErrorType.unknown:
        return error.message ?? 'حدث خطأ غير معروف';
    }
  }

  @override
  Widget build(BuildContext context) {
    final samples = _attempts
        .where((attempt) => attempt.received)
        .map((attempt) => attempt.duration!.inMicroseconds / 1000)
        .toList();
    final average = samples.isEmpty
        ? null
        : samples.reduce((a, b) => a + b) / samples.length;
    final minimum = samples.isEmpty
        ? null
        : samples.reduce((a, b) => a < b ? a : b);
    final maximum = samples.isEmpty
        ? null
        : samples.reduce((a, b) => a > b ? a : b);
    final standardDeviation = samples.isEmpty
        ? null
        : math.sqrt(
            samples
                    .map((sample) => math.pow(sample - average!, 2))
                    .reduce((a, b) => a + b) /
                samples.length,
          );
    final lost = math.max(0, _sent - _received);
    final lossPercentage = _sent == 0 ? 0.0 : lost * 100 / _sent;
    return _PingPage(
      controller: _targetController,
      testing: _testing,
      attempts: _attempts,
      average: average,
      minimum: minimum,
      maximum: maximum,
      standardDeviation: standardDeviation,
      sent: _sent,
      received: _received,
      lost: lost,
      lossPercentage: lossPercentage,
      error: _error,
      onRun: _runPing,
      onStop: _stopPing,
    );
  }
}

class _PingPage extends StatelessWidget {
  const _PingPage({
    required this.controller,
    required this.testing,
    required this.attempts,
    required this.average,
    required this.minimum,
    required this.maximum,
    required this.standardDeviation,
    required this.sent,
    required this.received,
    required this.lost,
    required this.lossPercentage,
    required this.error,
    required this.onRun,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool testing;
  final List<_PingAttempt> attempts;
  final double? average;
  final double? minimum;
  final double? maximum;
  final double? standardDeviation;
  final int sent;
  final int received;
  final int lost;
  final double lossPercentage;
  final String? error;
  final VoidCallback onRun;
  final VoidCallback onStop;

  int get _packetBytes => Platform.isWindows ? 32 : 64;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('Ping')),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      enabled: !testing,
                      keyboardType: TextInputType.url,
                      textDirection: TextDirection.ltr,
                      decoration: const InputDecoration(
                        hintText: 'IP أو اسم المضيف',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) {
                        if (!testing) onRun();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (testing)
                    TextButton.icon(
                      onPressed: onStop,
                      icon: const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      label: const Text('إيقاف'),
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                    )
                  else
                    FilledButton.icon(
                      onPressed: onRun,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('ابدأ'),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: attempts.isEmpty
                  ? Center(
                      child: Text(
                        error ??
                            (testing
                                ? 'بانتظار أول رد ICMP...'
                                : 'أدخل IP أو اسم المضيف لبدء Ping مستمر'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: error == null
                              ? Theme.of(context).colorScheme.onSurfaceVariant
                              : Theme.of(context).colorScheme.error,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: attempts.length,
                      itemBuilder: (context, index) {
                        final attempt = attempts[attempts.length - 1 - index];
                        return _AttemptRow(
                          attempt: attempt,
                          packetBytes: _packetBytes,
                        );
                      },
                    ),
            ),
            _StatisticsPanel(
              sent: sent,
              received: received,
              lost: lost,
              lossPercentage: lossPercentage,
              minimum: minimum,
              average: average,
              maximum: maximum,
              standardDeviation: standardDeviation,
            ),
          ],
        ),
      ),
    );
  }
}

class _AttemptRow extends StatelessWidget {
  const _AttemptRow({required this.attempt, required this.packetBytes});

  final _PingAttempt attempt;
  final int packetBytes;

  @override
  Widget build(BuildContext context) {
    final duration = attempt.duration?.inMicroseconds;
    final details = attempt.received
        ? '${attempt.address ?? '--'}\n$packetBytes bytes  TTL=${attempt.ttl ?? '--'}'
        : attempt.error ?? 'لم يصل رد';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 14,
            height: 14,
            color: attempt.received
                ? Colors.greenAccent.shade700
                : Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 42,
            child: Text(
              '#${attempt.sequence}',
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: Text(
              details,
              textDirection: TextDirection.ltr,
              style: TextStyle(
                color: attempt.received
                    ? null
                    : Theme.of(context).colorScheme.error,
              ),
            ),
          ),
          if (attempt.received)
            Text(
              '${(duration! / 1000).toStringAsFixed(3)} ms',
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
        ],
      ),
    );
  }
}

class _StatisticsPanel extends StatelessWidget {
  const _StatisticsPanel({
    required this.sent,
    required this.received,
    required this.lost,
    required this.lossPercentage,
    required this.minimum,
    required this.average,
    required this.maximum,
    required this.standardDeviation,
  });

  final int sent;
  final int received;
  final int lost;
  final double lossPercentage;
  final double? minimum;
  final double? average;
  final double? maximum;
  final double? standardDeviation;

  String _latency(double? value) =>
      value == null ? '--' : value.toStringAsFixed(3);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _Statistic(label: 'Sent', value: '$sent'),
              _Statistic(label: 'Received', value: '$received'),
              _Statistic(label: 'Lost', value: '$lost'),
              _Statistic(
                label: 'Loss',
                value: '${lossPercentage.toStringAsFixed(2)}%',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _Statistic(label: 'Min', value: _latency(minimum)),
              _Statistic(label: 'Avg', value: _latency(average)),
              _Statistic(label: 'Max', value: _latency(maximum)),
              _Statistic(label: 'Stddev', value: _latency(standardDeviation)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Statistic extends StatelessWidget {
  const _Statistic({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              textDirection: TextDirection.ltr,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
