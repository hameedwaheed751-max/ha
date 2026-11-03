import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'ping_view.dart';

/// Browsers cannot send ICMP, so the web ping times an HTTPS request to the
/// host instead, over a connection that is already open.
class PingScreen extends StatefulWidget {
  const PingScreen({super.key});

  @override
  State<PingScreen> createState() => _PingScreenState();
}

class _PingScreenState extends State<PingScreen> {
  static const _interval = Duration(seconds: 1);
  static const _timeout = Duration(seconds: 2);

  final _targetController = TextEditingController();
  bool _testing = false;
  int _run = 0;
  String? _error;
  List<PingAttempt> _attempts = const [];
  int _sent = 0;
  int _received = 0;
  String? _sasHost;

  @override
  void initState() {
    super.initState();
    loadSasPingHost().then((host) {
      if (mounted && host != null) setState(() => _sasHost = host);
    });
  }

  @override
  void dispose() {
    _run++;
    _targetController.dispose();
    super.dispose();
  }

  void _pingTarget(String host) {
    if (_testing) return;
    _targetController.text = host;
    _runPing();
  }

  /// Times one HTTPS request to [host]; throws [TimeoutException] when no
  /// reply arrives in time, or another error when the host is unreachable.
  Future<Duration> _probe(String host) async {
    final abort = web.AbortController();
    final timer = Timer(_timeout, () => abort.abort());
    final watch = Stopwatch()..start();
    try {
      // no-cors gives an opaque reply, which is enough to time the round trip
      // to any host without it allowing this site.
      await web.window
          .fetch(
            'https://$host/?netagent_ping=${DateTime.now().microsecondsSinceEpoch}'
                .toJS,
            web.RequestInit(
              method: 'HEAD',
              mode: 'no-cors',
              cache: 'no-store',
              signal: abort.signal,
            ),
          )
          .toDart;
      return watch.elapsed;
    } catch (_) {
      if (abort.signal.aborted) throw TimeoutException(null, _timeout);
      rethrow;
    } finally {
      timer.cancel();
    }
  }

  Future<void> _runPing() async {
    final host = normalizePingHost(_targetController.text);
    if (_testing) return;
    if (host.isEmpty) {
      setState(() => _error = 'أدخل IP أو اسم مضيف صحيحاً.');
      return;
    }
    FocusScope.of(context).unfocus();
    final run = ++_run;
    setState(() {
      _testing = true;
      _error = null;
      _attempts = const [];
      _sent = 0;
      _received = 0;
    });

    // The first request also looks up the name and opens the TLS
    // connection, so it is not counted.
    try {
      await _probe(host);
    } catch (_) {}

    final attempts = <PingAttempt>[];
    while (mounted && run == _run) {
      final started = DateTime.now();
      PingAttempt attempt;
      try {
        final duration = await _probe(host);
        attempt = PingAttempt(
          sequence: attempts.length + 1,
          address: host,
          details: 'HTTPS',
          duration: duration,
        );
      } on TimeoutException {
        attempt = PingAttempt(
          sequence: attempts.length + 1,
          error: 'انتهت مهلة الطلب',
        );
      } catch (_) {
        attempt = PingAttempt(
          sequence: attempts.length + 1,
          error: 'تعذر الوصول إلى المضيف عبر HTTPS',
        );
      }
      if (!mounted || run != _run) return;
      attempts.add(attempt);
      setState(() {
        _attempts = List.unmodifiable(attempts);
        _sent = attempts.length;
        _received = attempts.where((item) => item.received).length;
      });
      final wait = _interval - DateTime.now().difference(started);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
  }

  void _stopPing() {
    _run++;
    setState(() => _testing = false);
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
      quickTargets: pingQuickTargets(_sasHost),
      onQuickTarget: _pingTarget,
      idleHint: 'أدخل IP أو اسم المضيف لبدء Ping مستمر',
      note:
          'في المتصفح يُقاس زمن الاستجابة عبر HTTPS لأن المتصفح لا يسمح بـ '
          'ICMP، فقد يكون أعلى قليلاً من Ping التطبيق.',
    );
  }
}
