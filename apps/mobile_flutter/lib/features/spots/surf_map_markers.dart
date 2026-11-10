import 'package:flutter/material.dart';

import '../social/social_profile.dart';

Color surfMapDifficultyColor(String difficulty) => switch (difficulty) {
  'beginner' => const Color(0xFF4BAF74),
  'advanced' => const Color(0xFFD75A4A),
  _ => const Color(0xFF2E8FE8),
};

/// Static spot difficulty, not a live wave/forecast measurement.
class SurfMapSpotPin extends StatelessWidget {
  const SurfMapSpotPin({super.key, required this.difficulty, this.size = 28});
  final String difficulty;
  final double size;

  @override
  Widget build(BuildContext context) => Icon(
    Icons.location_on,
    color: surfMapDifficultyColor(difficulty),
    size: size,
  );
}

/// Shared visual only. Guest and signed-in maps keep their own data/permissions.
class SurfMapEventAvatar extends StatelessWidget {
  const SurfMapEventAvatar({
    super.key,
    required this.displayName,
    required this.avatarUrl,
    required this.spotName,
    required this.eventCount,
    required this.onTap,
    required this.tapKey,
  });

  final String displayName;
  final String? avatarUrl;
  final String spotName;
  final int eventCount;
  final VoidCallback onTap;
  final Key tapKey;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '$eventCount ${eventCount == 1 ? 'event' : 'events'} at $spotName',
    child: Semantics(
      button: true,
      label: 'Events at $spotName',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: tapKey,
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF079CA3), width: 2),
                ),
                child: TydesProfileAvatar(
                  displayName: displayName,
                  imageUrl: avatarUrl,
                  size: 40,
                ),
              ),
              Positioned(
                right: 0,
                bottom: 1,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Color(0xFF079CA3),
                    shape: BoxShape.circle,
                  ),
                  child: eventCount > 1
                      ? Text(
                          '$eventCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        )
                      : const Icon(Icons.event, color: Colors.white, size: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
