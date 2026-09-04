import 'package:flutter/material.dart';
import 'package:flutter_network_speed_test/flutter_network_speed_test.dart'
    as network_test;

class PingScreen extends StatefulWidget {
  const PingScreen({super.key});

  @override
  State<PingScreen> createState() => _PingScreenState();
}

class _PingScreenState extends State<PingScreen> {
  final _targetController = TextEditingController();
  bool _testing = false;
  String? _error;
  List<double> _samples = const [];

  @override
  void dispose() {
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
    if (host.isEmpty || _testing) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _testing = true;
      _error = null;
      _samples = const [];
    });

    final samples = <double>[];
    try {
      final average = await network_test.testPing(
        url: host,
        numberOfPings: 5,
        onProgress: (milliseconds, _, _) {
          if (!mounted) return;
          samples.add(milliseconds.toDouble());
          setState(() => _samples = List.unmodifiable(samples));
        },
      );
      if (!mounted) return;
      if (average == null || samples.isEmpty) {
        throw Exception('لم يصل رد من الهدف');
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Exception: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final average = _samples.isEmpty
        ? null
        : _samples.reduce((a, b) => a + b) / _samples.length;
    final minimum = _samples.isEmpty
        ? null
        : _samples.reduce((a, b) => a < b ? a : b);
    final maximum = _samples.isEmpty
        ? null
        : _samples.reduce((a, b) => a > b ? a : b);
    return _PingPage(
      controller: _targetController,
      testing: _testing,
      methodLabel: 'ICMP Ping من هذا الجهاز',
      average: average,
      minimum: minimum,
      maximum: maximum,
      received: _samples.length,
      error: _error,
      onRun: _runPing,
    );
  }
}

class _PingPage extends StatelessWidget {
  const _PingPage({
    required this.controller,
    required this.testing,
    required this.methodLabel,
    required this.average,
    required this.minimum,
    required this.maximum,
    required this.received,
    required this.error,
    required this.onRun,
  });

  final TextEditingController controller;
  final bool testing;
  final String methodLabel;
  final double? average;
  final double? minimum;
  final double? maximum;
  final int received;
  final String? error;
  final VoidCallback onRun;

  String _value(double? value) =>
      value == null ? '--' : '${value.toStringAsFixed(1)} ms';

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('Ping')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: controller,
              enabled: !testing,
              keyboardType: TextInputType.url,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                labelText: 'IP أو اسم المضيف',
                hintText: '8.8.8.8',
                prefixIcon: Icon(Icons.language_rounded),
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => onRun(),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: testing ? null : onRun,
              icon: testing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_ping_rounded),
              label: Text(testing ? 'جاري القياس...' : 'ابدأ القياس'),
            ),
            const SizedBox(height: 18),
            Text(methodLabel, textAlign: TextAlign.center),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ResultTile(label: 'المتوسط', value: _value(average)),
                _ResultTile(label: 'الأدنى', value: _value(minimum)),
                _ResultTile(label: 'الأعلى', value: _value(maximum)),
                _ResultTile(label: 'الردود', value: '$received / 5'),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 16),
              Text(
                error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 150,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(label),
        ],
      ),
    );
  }
}
