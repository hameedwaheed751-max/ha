import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../sas_api_service.dart';

/// One ping request and its reply, shared by the app and web screens.
class PingAttempt {
  const PingAttempt({
    required this.sequence,
    this.address,
    this.details,
    this.duration,
    this.error,
  });

  final int sequence;
  final String? address;

  /// A second line under the address, such as packet size and TTL.
  final String? details;
  final Duration? duration;
  final String? error;

  bool get received => duration != null && error == null;
}

/// The host part of an address, URL, or bare host name.
String normalizePingHost(String value) {
  final trimmed = value.trim();
  final uri = Uri.tryParse(
    trimmed.contains('://') ? trimmed : 'https://$trimmed',
  );
  return uri?.host.isNotEmpty == true ? uri!.host : trimmed;
}

/// خوادم كل ساسات الوكيل، كل خادم مرة واحدة.
Future<List<(String, String)>> loadSasPingTargets() async {
  try {
    final accounts = await SasSettings.loadAll();
    final seen = <String>{};
    final targets = <(String, String)>[];
    for (final account in accounts) {
      final host = normalizePingHost(account.serverUrl);
      if (host.isEmpty || !seen.add(host)) continue;
      final label = accounts.length > 1
          ? 'خادم ${account.displayName}'
          : 'خادم SAS';
      targets.add((label, host));
    }
    return targets;
  } catch (_) {
    return const [];
  }
}

List<(String, String)> pingQuickTargets(List<(String, String)> sasTargets) => [
  ...sasTargets,
  ('Google DNS', '8.8.8.8'),
  ('Cloudflare', '1.1.1.1'),
  ('Google', 'google.com'),
];

class PingView extends StatelessWidget {
  const PingView({
    super.key,
    required this.controller,
    required this.testing,
    required this.attempts,
    required this.sent,
    required this.received,
    required this.error,
    required this.onRun,
    required this.onStop,
    required this.quickTargets,
    required this.onQuickTarget,
    required this.idleHint,
    this.note,
  });

  final TextEditingController controller;
  final bool testing;
  final List<PingAttempt> attempts;
  final int sent;
  final int received;
  final String? error;
  final VoidCallback onRun;
  final VoidCallback onStop;
  final List<(String, String)> quickTargets;
  final ValueChanged<String> onQuickTarget;
  final String idleHint;

  /// A short line under the quick targets explaining how ping is measured.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final samples = attempts
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
    final lost = math.max(0, sent - received);
    final lossPercentage = sent == 0 ? 0.0 : lost * 100 / sent;
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
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final (label, host) in quickTargets)
                    ActionChip(
                      label: Text(label),
                      tooltip: host,
                      onPressed: testing ? null : () => onQuickTarget(host),
                    ),
                ],
              ),
            ),
            if (note != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(
                  note!,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: attempts.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          error ?? (testing ? 'بانتظار أول رد...' : idleHint),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: error == null
                                ? Theme.of(context).colorScheme.onSurfaceVariant
                                : Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: attempts.length,
                      itemBuilder: (context, index) => _AttemptRow(
                        attempt: attempts[attempts.length - 1 - index],
                      ),
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
  const _AttemptRow({required this.attempt});

  final PingAttempt attempt;

  @override
  Widget build(BuildContext context) {
    final duration = attempt.duration?.inMicroseconds;
    final details = attempt.received
        ? [
            attempt.address ?? '--',
            if (attempt.details != null) attempt.details!,
          ].join('\n')
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
              _Statistic(label: 'المرسلة', value: '$sent'),
              _Statistic(label: 'المستلمة', value: '$received'),
              _Statistic(label: 'المفقودة', value: '$lost'),
              _Statistic(
                label: 'نسبة الفقد',
                value: '${lossPercentage.toStringAsFixed(2)}%',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _Statistic(label: 'الأقل ms', value: _latency(minimum)),
              _Statistic(label: 'المتوسط ms', value: _latency(average)),
              _Statistic(label: 'الأعلى ms', value: _latency(maximum)),
              _Statistic(
                label: 'التذبذب ms',
                value: _latency(standardDeviation),
              ),
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
