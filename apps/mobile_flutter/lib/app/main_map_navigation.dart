import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/home/home_page.dart' show meProvider;
import 'router.dart' show currentTabProvider;

class MainMapFocus {
  const MainMapFocus({
    required this.accountId,
    required this.spotId,
    required this.revision,
  });

  final String accountId;
  final String? spotId;
  final int revision;
}

final mainMapFocusProvider = StateProvider<MainMapFocus?>((_) => null);

/// Map actions return to the existing shell instead of stacking another map.
/// A revision also refocuses the same beach after the user has panned away.
void openMainSpotsMap(BuildContext context, WidgetRef ref, {String? spotId}) {
  final profile = ref.read(meProvider).valueOrNull;
  if (profile == null || !profile.emailVerified) {
    context.go('/explore');
    return;
  }
  final previous = ref.read(mainMapFocusProvider);
  ref.read(mainMapFocusProvider.notifier).state = MainMapFocus(
    accountId: profile.id,
    spotId: spotId,
    revision: (previous?.revision ?? 0) + 1,
  );
  ref.read(currentTabProvider.notifier).state = 1;
  context.go('/');
}
