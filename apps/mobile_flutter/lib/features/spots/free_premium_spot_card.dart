import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_models.dart';

/// A shortcut to an already-selected entitlement, not a forecast request or a
/// second selection flow. Opening it uses the normal spot-detail access rules.
class FreePremiumSpotCard extends StatelessWidget {
  const FreePremiumSpotCard({super.key, required this.spot});

  final SpotModel spot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final location = <String>{
      spot.area.trim(),
      spot.region.trim(),
      spot.country.trim(),
    }.where((part) => part.isNotEmpty).join(' · ');

    void openForecast() => context.push('/spot/${spot.id}');

    return Card(
      key: const ValueKey('free-premium-spot-card'),
      color: colors.primaryContainer,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: openForecast,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.lock_open_rounded,
                    color: colors.onPrimaryContainer,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Your free Premium spot',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: colors.onPrimaryContainer,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                spot.name,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: colors.onPrimaryContainer,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (location.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  location,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onPrimaryContainer,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'Premium forecasts at this break, included with your free account.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                key: const ValueKey('free-premium-spot-open'),
                onPressed: openForecast,
                icon: const Icon(Icons.waves_rounded, size: 18),
                label: const Text('View forecast'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
