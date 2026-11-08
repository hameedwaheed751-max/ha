import 'dart:async';
import 'dart:io';

import 'package:dart_ping/dart_ping.dart';
import 'package:dart_ping_ios/dart_ping_ios.dart';
import 'package:flutter/material.dart';

import 'ping_view.dart';

class PingScreen extends StatefulWidget {
  const PingScreen({super.key});

  @override
  State<PingScreen> createState() => _PingScreenState();
}

class _PingScreenState extends State<PingScreen> {
  final _targetController = TextEditingController();
  bool _testing = false;
  String? _error;
  List<PingAttempt> _attempts = const [];
  int _sent = 0;
  int _received = 0;
  Ping? _activePing;
  List<(String, String)> _sasTargets = const [];

  int get _packetBytes => Platform.isWindows ? 32 : 64;

  @override
  void initState() {
    super.initState();
    loadSasPingTargets().then((targets) {
      if (mounted) setState(() => _sasTargets = targets);
    });
  }

  void _pingTarget(String host) {
    if (_testing) return;
    _targetController.text = host;
    _runPing();
  }

  @override
  void dispose() {
    final activePing = _activePing;
    if (activePing != null) unawaited(activePing.stop());
    _targetController.dispose();
    super.dispose();
  }

  Future<void> _runPing() async {
    final host = normalizePingHost(_targetController.text);
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
    final attempts = <PingAttempt>[];
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
            PingAttempt(
              sequence: attempts.length + 1,
              address: response.ip,
              details: '$_packetBytes bytes  TTL=${response.ttl ?? '--'}',
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
              PingAttempt(sequence: attempts.length + 1, error: 'لم يصل رد'),
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
    return PingView(
      controller: _targetController,
      testing: _testing,
      attempts: _attempts,
      sent: _sent,
      received: _received,
      error: _error,
      onRun: _runPing,
      onStop: _stopPing,
      quickTargets: pingQuickTargets(_sasTargets),
      onQuickTarget: _pingTarget,
      idleHint: 'أدخل IP أو اسم المضيف لبدء Ping مستمر',
    );
  }
}
