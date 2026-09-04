import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/runtime_app_config.dart';

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

  String? _targetHost(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final candidate = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    final uri = Uri.tryParse(candidate);
    if (uri == null || uri.host.isEmpty) return null;
    return uri.host;
  }

  Uri _proxyPingUri(String host) {
    final configuredProxy =
        readRuntimeAppConfig('sasWebProxyUrl') ??
        'https://ha-0cs7.onrender.com';
    final proxyBase = configuredProxy.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$proxyBase/ping-target').replace(
      queryParameters: {
        'target': 'https://$host',
        '_ping': DateTime.now().microsecondsSinceEpoch.toString(),
      },
    );
  }

  Future<void> _runPing() async {
    final targetHost = _targetHost(_targetController.text);
    if (_testing) return;
    if (targetHost == null) {
      setState(() => _error = 'أدخل IP أو اسم مضيف صحيحاً.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _testing = true;
      _error = null;
      _samples = const [];
    });

    final client = http.Client();
    final samples = <double>[];
    try {
      for (var index = 0; index < 5; index++) {
        final headers = <String, String>{};
        final proxyToken = readRuntimeAppConfig('sasProxyToken')?.trim() ?? '';
        if (proxyToken.isNotEmpty) headers['X-Proxy-Token'] = proxyToken;
        final response = await client
            .get(_proxyPingUri(targetHost), headers: headers)
            .timeout(const Duration(seconds: 12));
        final decoded = jsonDecode(response.body);
        if (response.statusCode != 200 || decoded is! Map) {
          throw Exception('خدمة القياس أعادت HTTP ${response.statusCode}');
        }
        if (decoded['ok'] != true) {
          throw Exception(
            (decoded['error'] ?? 'لم يصل رد من الهدف').toString(),
          );
        }
        final latency = decoded['latencyMs'];
        final milliseconds = latency is num
            ? latency.toDouble()
            : double.tryParse(latency?.toString() ?? '');
        if (milliseconds == null) {
          throw Exception('رد خدمة القياس لا يحتوي زمناً صالحاً');
        }
        if (!mounted) return;
        samples.add(milliseconds);
        setState(() => _samples = List.unmodifiable(samples));
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error =
              'تعذر قياس الهدف عبر خدمة Web: '
              '${error.toString().replaceFirst('Exception: ', '')}';
        });
      }
    } finally {
      client.close();
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
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('Ping')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _targetController,
              enabled: !_testing,
              keyboardType: TextInputType.url,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                labelText: 'IP أو اسم المضيف',
                hintText: '8.8.8.8',
                prefixIcon: Icon(Icons.language_rounded),
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _runPing(),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _testing ? null : _runPing,
              icon: _testing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_ping_rounded),
              label: Text(_testing ? 'جاري القياس...' : 'ابدأ القياس'),
            ),
            const SizedBox(height: 18),
            const Text(
              'HTTP Latency من خادم Web إلى الهدف (ليس ICMP من الجهاز)',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ResultTile(label: 'المتوسط', value: _value(average)),
                _ResultTile(label: 'الأدنى', value: _value(minimum)),
                _ResultTile(label: 'الأعلى', value: _value(maximum)),
                _ResultTile(label: 'الردود', value: '${_samples.length} / 5'),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _value(double? value) =>
      value == null ? '--' : '${value.toStringAsFixed(1)} ms';
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
