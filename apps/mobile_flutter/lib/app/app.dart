import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n/app_strings.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/appearance_host.dart';
import '../core/theme/theme_preference.dart';
import '../features/alerts/alert_monitor.dart';
import '../features/home/home_page.dart';
import '../core/network/api_models.dart';
import 'package:go_router/go_router.dart';
import 'router.dart';

class SurfTravelApp extends ConsumerStatefulWidget {
  const SurfTravelApp({super.key, this.enableAlertMonitor = true});

  final bool enableAlertMonitor;

  @override
  ConsumerState<SurfTravelApp> createState() => _SurfTravelAppState();
}

class _SurfTravelAppState extends ConsumerState<SurfTravelApp>
    with WidgetsBindingObserver {
  ProviderSubscription<AsyncValue<UserProfile>>? _accountSubscription;
  GoRouter? _router;
  AlertMonitor? _monitor;
  String? _monitorAccount;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.enableAlertMonitor) {
        _router = ref.read(appRouterProvider);
        _router!.routeInformationProvider.addListener(_syncAlertMonitor);
        _accountSubscription = ref.listenManual(
          meProvider,
          (_, _) => _syncAlertMonitor(),
          fireImmediately: true,
        );
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.enableAlertMonitor) {
      _accountSubscription?.close();
      _router?.routeInformationProvider.removeListener(_syncAlertMonitor);
      _monitor?.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.enableAlertMonitor &&
        _monitorAccount != null &&
        state == AppLifecycleState.resumed) {
      _monitor?.checkNow();
    }
  }

  void _syncAlertMonitor() {
    if (!mounted) return;
    final path = _router!.routeInformationProvider.value.uri.path;
    final me = ref.read(meProvider);
    final profile = me.hasError || me.isLoading ? null : me.valueOrNull;
    final account =
        path == '/login' ||
            path.startsWith('/explore') ||
            profile == null ||
            profile.displayName.isEmpty ||
            profile.handle.isEmpty ||
            profile.surfSkill.isEmpty
        ? null
        : profile.id;
    if (account == _monitorAccount) return;
    _monitor?.dispose();
    _monitorAccount = account;
    if (account != null) {
      _monitor = ref.read(alertMonitorProvider);
      unawaited(_monitor!.initialize());
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    final locale = ref.watch(localeProvider);
    return MaterialApp.router(
      title: 'Tydes',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),
      builder: (context, child) => _AppearanceHost(child: child!),
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

class _AppearanceHost extends StatefulWidget {
  const _AppearanceHost({required this.child});
  final Widget child;

  @override
  State<_AppearanceHost> createState() => _AppearanceHostState();
}

class _AppearanceHostState extends State<_AppearanceHost> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncHostAppearance(Theme.of(context).brightness == Brightness.dark);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
