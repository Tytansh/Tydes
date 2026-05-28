import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n/app_strings.dart';
import '../core/theme/app_theme.dart';
import '../features/alerts/alert_monitor.dart';
import 'router.dart';

class SurfTravelApp extends ConsumerStatefulWidget {
  const SurfTravelApp({super.key, this.enableAlertMonitor = true});

  final bool enableAlertMonitor;

  @override
  ConsumerState<SurfTravelApp> createState() => _SurfTravelAppState();
}

class _SurfTravelAppState extends ConsumerState<SurfTravelApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.enableAlertMonitor) {
        ref.read(alertMonitorProvider).initialize();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.enableAlertMonitor) {
      ref.read(alertMonitorProvider).dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.enableAlertMonitor && state == AppLifecycleState.resumed) {
      ref.read(alertMonitorProvider).checkNow();
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    final locale = ref.watch(localeProvider);
    return MaterialApp.router(
      title: 'Surf Travel',
      theme: AppTheme.light(),
      routerConfig: router,
      locale: locale,
      supportedLocales: AppStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
    );
  }
}
