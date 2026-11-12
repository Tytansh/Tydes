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
import '../features/social/inbox_badges.dart';
import '../core/network/api_models.dart';
import '../core/network/surf_repository.dart';
import 'package:go_router/go_router.dart';
import 'router.dart';

class SurfTravelApp extends ConsumerStatefulWidget {
  const SurfTravelApp({
    super.key,
    this.enableAlertMonitor = true,
    this.enableInboxPolling = true,
  });

  final bool enableAlertMonitor;
  final bool enableInboxPolling;

  @override
  ConsumerState<SurfTravelApp> createState() => _SurfTravelAppState();
}

class _SurfTravelAppState extends ConsumerState<SurfTravelApp>
    with WidgetsBindingObserver {
  ProviderSubscription<AsyncValue<UserProfile>>? _accountSubscription;
  ProviderSubscription<String?>? _verificationSubscription;
  GoRouter? _router;
  AlertMonitor? _monitor;
  String? _monitorAccount;
  Timer? _inboxTimer;
  String? _inboxAccount;
  bool _inboxForeground = true;
  bool _checkingInbox = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.enableAlertMonitor || widget.enableInboxPolling) {
        _router = ref.read(appRouterProvider);
        _router!.routeInformationProvider.addListener(_syncMonitors);
        _accountSubscription = ref.listenManual(
          meProvider,
          (_, _) => _syncMonitors(),
          fireImmediately: true,
        );
        _verificationSubscription = ref.listenManual(
          emailVerificationRequiredTokenProvider,
          (_, _) => _syncMonitors(),
        );
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _inboxTimer?.cancel();
    if (widget.enableAlertMonitor || widget.enableInboxPolling) {
      _accountSubscription?.close();
      _verificationSubscription?.close();
      _router?.routeInformationProvider.removeListener(_syncMonitors);
      _monitor?.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inboxForeground = state == AppLifecycleState.resumed;
    _syncMonitors();
    if (widget.enableAlertMonitor &&
        _monitorAccount != null &&
        state == AppLifecycleState.resumed) {
      _monitor?.checkNow();
    }
  }

  void _syncMonitors() {
    if (_router == null) return;
    if (widget.enableAlertMonitor) _syncAlertMonitor();
    if (widget.enableInboxPolling) _syncInboxMonitor();
  }

  void _syncInboxMonitor() {
    if (!mounted) return;
    final path = _router!.routeInformationProvider.value.uri.path;
    final me = ref.read(meProvider);
    final profile = me.hasError || me.isLoading ? null : me.valueOrNull;
    final account =
        !_inboxForeground ||
            path == '/login' ||
            path == '/verify-email' ||
            path == '/account-check' ||
            path.startsWith('/explore') ||
            profile == null ||
            !profile.emailVerified ||
            ref.read(emailVerificationRequiredTokenProvider) != null ||
            profile.displayName.isEmpty ||
            profile.handle.isEmpty ||
            profile.surfSkill.isEmpty
        ? null
        : profile.id;
    if (account == _inboxAccount) return;
    _inboxTimer?.cancel();
    _inboxAccount = account;
    // Provider writes wait until the frame ends, including profile changes
    // caused by login. Old requests cannot enable another account's badge.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _inboxAccount != account) return;
      if (ref.read(inboxForegroundAccountProvider) == account) {
        // Hidden web tabs may not paint the frame that clears the owner.
        // Still request a fresh count immediately on returning to that tab.
        if (account != null) {
          ref.read(inboxCountsRefreshKeyProvider.notifier).state++;
        }
      } else {
        ref.read(inboxForegroundAccountProvider.notifier).state = account;
      }
    });
    if (account != null) {
      _inboxTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _refreshInboxCounts(account),
      );
    }
  }

  Future<void> _refreshInboxCounts(String account) async {
    if (!mounted ||
        !_inboxForeground ||
        _inboxAccount != account ||
        _checkingInbox ||
        ref.read(inboxUnreadCountsProvider).isLoading) {
      return;
    }
    _checkingInbox = true;
    try {
      final counts = await ref.refresh(inboxUnreadCountsProvider.future);
      if (counts.accountId != account) return;
    } catch (_) {
      // Preserve the last confirmed counts while offline; no invented zeroes.
    } finally {
      _checkingInbox = false;
    }
  }

  void _syncAlertMonitor() {
    if (!mounted) return;
    final path = _router!.routeInformationProvider.value.uri.path;
    final me = ref.read(meProvider);
    final profile = me.hasError || me.isLoading ? null : me.valueOrNull;
    final account =
        path == '/login' ||
            path == '/verify-email' ||
            path == '/account-check' ||
            path.startsWith('/explore') ||
            profile == null ||
            !profile.emailVerified ||
            ref.read(emailVerificationRequiredTokenProvider) != null ||
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
