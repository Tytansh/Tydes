// Local layout QA only. Never publish this entrypoint.
// flutter run -d chrome -t test/manual/alert_status_preview.dart
import 'package:flutter/material.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/alerts/alert_status.dart';

void main() => runApp(const _AlertStatusPreview());

class _AlertStatusPreview extends StatefulWidget {
  const _AlertStatusPreview();

  @override
  State<_AlertStatusPreview> createState() => _AlertStatusPreviewState();
}

class _AlertStatusPreviewState extends State<_AlertStatusPreview> {
  // Capture once so theme changes never alter the example's freshness state.
  final DateTime _now = DateTime.now();
  bool _dark = false;

  AlertModel _alert(String spotId, {required bool matched}) => AlertModel(
    id: 'local-layout-$spotId',
    spotId: spotId,
    waveEnabled: true,
    minWaveHeightM: 0.75,
    windEnabled: true,
    maxWindKts: 18,
    tideEnabled: true,
    tideType: 'high',
    tideOffsetHours: 0,
    enabled: true,
    status: matched ? 'triggered' : 'waiting',
    statusReason: matched ? null : 'Waiting on tide data.',
    lastEvaluatedAt: _now
        .subtract(const Duration(minutes: 3))
        .toIso8601String(),
    nextCheckAt: _now.add(const Duration(minutes: 57)).toIso8601String(),
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
    home: Scaffold(
      appBar: AppBar(
        title: const Text('Alert status — local preview'),
        actions: [
          const Text('Dark'),
          Switch(
            value: _dark,
            onChanged: (value) => setState(() => _dark = value),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _PreviewNotice(),
                const SizedBox(height: 28),
                const _SpotLabel('Bondi', 'Sydney, New South Wales, Australia'),
                const SizedBox(height: 14),
                AlertStatusBanner(
                  alert: _alert('local-bondi', matched: false),
                  now: _now,
                  compact: true,
                ),
                const SizedBox(height: 36),
                const _SpotLabel('Uluwatu', 'Bali, Indonesia'),
                const SizedBox(height: 14),
                AlertStatusBanner(
                  alert: _alert('local-uluwatu', matched: true),
                  now: _now,
                  compact: true,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _PreviewNotice extends StatelessWidget {
  const _PreviewNotice();

  @override
  Widget build(BuildContext context) => Text(
    'LOCAL LAYOUT PREVIEW — no live data',
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

class _SpotLabel extends StatelessWidget {
  const _SpotLabel(this.name, this.location);
  final String name;
  final String location;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(name, style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 5),
      Text(location, style: Theme.of(context).textTheme.bodyMedium),
    ],
  );
}
