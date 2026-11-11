import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:mobile_flutter/core/billing/revenuecat_service.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/network/demo_persistence.dart';
import 'package:mobile_flutter/core/network/demo_seed.dart';
import 'package:mobile_flutter/core/network/surf_repository.dart';
import 'package:mobile_flutter/core/theme/app_theme.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/paywall/paywall_page.dart';

const _package = Package(
  r'$rc_monthly',
  PackageType.monthly,
  StoreProduct(
    'tydes_premium_monthly',
    'Monthly access',
    'Tydes Premium',
    3.99,
    r'US$3.99',
    'USD',
    subscriptionPeriod: 'P1M',
  ),
  PresentedOfferingContext('premium', null, null),
);
const _customer = CustomerInfo(
  EntitlementInfos({}, {}),
  {},
  [],
  [],
  [],
  '2026-11-06',
  'buyer',
  {},
  '2026-11-06',
);

class _BillingRepository extends SurfRepository {
  _BillingRepository() : super(Dio(), DemoPersistence());
  var profile = DemoSeed.me.copyWith(id: 'buyer', premium: false);
  var syncCalls = 0;
  var failSync = false;

  @override
  Future<UserProfile> fetchMe() async => profile;

  @override
  Future<UserProfile> syncRevenueCatPremium() async {
    syncCalls++;
    if (failSync) throw StateError('Unavailable');
    profile = profile.copyWith(premium: true);
    return profile;
  }
}

class _BillingService extends RevenueCatService {
  _BillingService({this.available = true, this.cancel = false});
  final bool available;
  final bool cancel;
  final purchases = <String>[];

  @override
  bool get isAvailable => available;
  @override
  bool get isWeb => true;
  @override
  Future<CustomerInfo> purchasePremium({
    required UserProfile profile,
    required Package package,
  }) async {
    purchases.add(profile.id);
    if (cancel) throw const RevenueCatPurchaseCancelledException();
    return _customer;
  }

  @override
  Future<CustomerInfo> restorePurchases(UserProfile profile) async => _customer;
}

Future<void> _show(
  WidgetTester tester,
  _BillingRepository repo,
  _BillingService service, {
  bool productAvailable = true,
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        surfRepositoryProvider.overrideWithValue(repo),
        revenueCatServiceProvider.overrideWithValue(service),
        billingConfigProvider.overrideWith(
          (_) async => {'verification_ready': true},
        ),
        plansProvider.overrideWith((_) async => []),
        meProvider.overrideWith((_) async => repo.profile),
        premiumOfferProvider.overrideWith(
          (_) async => productAvailable
              ? const RevenueCatPremiumOffer(
                  package: _package,
                  title: 'Tydes Premium',
                  price: r'US$3.99',
                )
              : null,
        ),
      ],
      child: MaterialApp(theme: theme, home: const PaywallPage()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'subscription notes remain readable in ${dark ? 'dark' : 'light'} mode',
      (tester) async {
        final theme = dark ? AppTheme.dark() : AppTheme.light();
        await _show(
          tester,
          _BillingRepository(),
          _BillingService(),
          theme: theme,
        );
        final title = find.text('Subscription and safety notes');
        await tester.scrollUntilVisible(title, 300);
        final card = tester.widget<Card>(
          find.ancestor(of: title, matching: find.byType(Card)).first,
        );
        expect(
          card.color,
          dark
              ? theme.colorScheme.surfaceContainerHigh
              : const Color(0xFFFFF8ED),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'only verified purchases unlock the current account and show the store price',
    (tester) async {
      final repo = _BillingRepository();
      final service = _BillingService();
      await _show(tester, repo, service);
      expect(find.text(r'US$3.99 / month'), findsOneWidget);
      expect(find.text('Ad-free experience'), findsOneWidget);
      expect(find.text('Ad-light experience'), findsNothing);
      final buy = find.widgetWithText(FilledButton, 'Subscribe monthly');
      await tester.ensureVisible(buy);
      await tester.tap(buy);
      await tester.pumpAndSettle();
      expect(service.purchases, ['buyer']);
      expect(repo.syncCalls, 1);
      expect(find.text('Current plan'), findsOneWidget);
      expect(find.text('Manage subscription'), findsOneWidget);
    },
  );

  testWidgets(
    'missing checkout configuration disables purchases but preserves subscription checks',
    (tester) async {
      final repo = _BillingRepository();
      await _show(
        tester,
        repo,
        _BillingService(available: false),
        productAvailable: false,
      );
      final buy = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Subscribe monthly'),
      );
      expect(buy.onPressed, isNull);
      expect(find.text('Check subscription'), findsOneWidget);
      expect(find.textContaining('SDK keys'), findsNothing);
    },
  );

  testWidgets('a canceled purchase never syncs or enables Premium', (
    tester,
  ) async {
    final repo = _BillingRepository();
    await _show(tester, repo, _BillingService(cancel: true));
    final buy = find.widgetWithText(FilledButton, 'Subscribe monthly');
    await tester.ensureVisible(buy);
    await tester.tap(buy);
    await tester.pumpAndSettle();
    expect(repo.syncCalls, 0);
    expect(repo.profile.premium, isFalse);
    expect(find.text('Purchase canceled.'), findsOneWidget);
  });

  testWidgets(
    'store success followed by server failure prevents a duplicate purchase',
    (tester) async {
      final repo = _BillingRepository()..failSync = true;
      final service = _BillingService();
      await _show(tester, repo, service);
      final buy = find.widgetWithText(FilledButton, 'Subscribe monthly');
      await tester.ensureVisible(buy);
      await tester.tap(buy);
      await tester.pumpAndSettle();
      expect(repo.profile.premium, isFalse);
      expect(tester.widget<FilledButton>(buy).onPressed, isNull);
      expect(service.purchases, ['buyer']);
      repo.failSync = false;
      final check = find.text('Check subscription');
      await tester.ensureVisible(check);
      await tester.tap(check);
      await tester.pumpAndSettle();
      expect(repo.profile.premium, isTrue);
      expect(service.purchases, ['buyer']);
    },
  );
}
