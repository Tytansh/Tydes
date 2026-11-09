import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/billing/revenuecat_service.dart';
import '../../core/legal/legal_links.dart';
import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../home/home_page.dart';
import '../spots/spot_detail_page.dart';

final plansProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchPlans(),
);

final premiumOfferProvider = FutureProvider<RevenueCatPremiumOffer?>((
  ref,
) async {
  final service = ref.watch(revenueCatServiceProvider);
  final profile = await ref.watch(meProvider.future);
  if (!service.isAvailable) {
    return null;
  }
  return service.loadPremiumOffer(profile);
});

final premiumPurchaseBusyProvider = StateProvider<bool>((ref) => false);
final premiumPurchasePendingProvider = StateProvider.family<bool, String>(
  (ref, userId) => false,
);

class PaywallPage extends ConsumerStatefulWidget {
  const PaywallPage({super.key});

  @override
  ConsumerState<PaywallPage> createState() => _PaywallPageState();
}

class _PaywallPageState extends ConsumerState<PaywallPage>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(meProvider);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ref.invalidate(meProvider);
  }

  Future<void> _buyPremium(BuildContext context, WidgetRef ref) async {
    final profile = ref.read(meProvider).valueOrNull;
    if (profile == null) {
      _showMessage(context, 'Sign in first, then come back to Premium.');
      return;
    }

    final service = ref.read(revenueCatServiceProvider);
    if (!service.isAvailable) {
      _showMessage(
        context,
        'Subscriptions are not available on this platform yet. You have not been charged.',
      );
      return;
    }

    ref.read(premiumPurchaseBusyProvider.notifier).state = true;
    try {
      final offer = await ref.read(premiumOfferProvider.future);
      if (offer == null) {
        throw StateError(
          'No RevenueCat premium package found. Check the default offering.',
        );
      }
      await service.purchasePremium(profile: profile, package: offer.package);
      ref.read(premiumPurchasePendingProvider(profile.id).notifier).state =
          true;
      // Once the store succeeds, a verification outage must never encourage a second purchase.
      UserProfile syncedProfile;
      try {
        syncedProfile = await ref
            .read(surfRepositoryProvider)
            .syncRevenueCatPremium();
      } catch (_) {
        if (context.mounted) {
          _showMessage(
            context,
            'Your purchase was received, but Premium could not be confirmed yet. Tap Check subscription or Restore purchases; do not buy again.',
          );
        }
        return;
      }
      if (syncedProfile.premium) {
        ref.read(premiumPurchasePendingProvider(profile.id).notifier).state =
            false;
      }
      _refreshPremiumState(ref);
      if (!context.mounted) {
        return;
      }
      _showMessage(
        context,
        syncedProfile.premium
            ? 'Premium is active.'
            : 'Purchase finished. Premium will activate once the store confirms it.',
      );
    } on RevenueCatPurchaseCancelledException {
      if (context.mounted) {
        _showMessage(context, 'Purchase canceled.');
      }
    } catch (error) {
      if (error is PlatformException &&
          PurchasesErrorHelper.getErrorCode(error) ==
              PurchasesErrorCode.paymentPendingError) {
        ref.read(premiumPurchasePendingProvider(profile.id).notifier).state =
            true;
      }
      if (context.mounted) {
        _showMessage(context, _friendlyError(error));
      }
    } finally {
      ref.read(premiumPurchaseBusyProvider.notifier).state = false;
    }
  }

  Future<void> _restorePurchases(BuildContext context, WidgetRef ref) async {
    final profile = ref.read(meProvider).valueOrNull;
    if (profile == null) {
      _showMessage(context, 'Sign in first, then restore purchases.');
      return;
    }

    final service = ref.read(revenueCatServiceProvider);
    ref.read(premiumPurchaseBusyProvider.notifier).state = true;
    try {
      // A signed-in web user can check purchases from Apple even before web checkout is enabled.
      if (service.isAvailable) await service.restorePurchases(profile);
      final syncedProfile = await ref
          .read(surfRepositoryProvider)
          .syncRevenueCatPremium();
      if (syncedProfile.premium) {
        ref.read(premiumPurchasePendingProvider(profile.id).notifier).state =
            false;
      }
      _refreshPremiumState(ref);
      if (!context.mounted) {
        return;
      }
      _showMessage(
        context,
        syncedProfile.premium
            ? 'Premium restored.'
            : 'No active Premium subscription was found.',
      );
    } catch (error) {
      if (context.mounted) {
        _showMessage(context, _friendlyError(error));
      }
    } finally {
      ref.read(premiumPurchaseBusyProvider.notifier).state = false;
    }
  }

  Future<void> _manageSubscription(BuildContext context, WidgetRef ref) async {
    final profile = ref.read(meProvider).valueOrNull;
    if (profile == null) return;
    ref.read(premiumPurchaseBusyProvider.notifier).state = true;
    try {
      final service = ref.read(revenueCatServiceProvider);
      final url = service.isAvailable
          ? await service.managementUrl(profile)
          : await ref
                .read(surfRepositoryProvider)
                .fetchSubscriptionManagementUrl();
      if (url == null) {
        if (context.mounted) {
          _showMessage(
            context,
            'Manage your subscription with the store where you purchased it. Complimentary Premium does not renew or charge you.',
          );
        }
        return;
      }
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw StateError('Could not open subscription management.');
      }
    } catch (_) {
      if (context.mounted) {
        _showMessage(
          context,
          'Could not open subscription management. Please use the store where you subscribed.',
        );
      }
    } finally {
      ref.read(premiumPurchaseBusyProvider.notifier).state = false;
    }
  }

  void _refreshPremiumState(WidgetRef ref) {
    ref.invalidate(meProvider);
    ref.invalidate(homeAdsProvider);
    ref.invalidate(dashboardProvider);
    ref.invalidate(spotForecastProvider);
    ref.invalidate(spotTideProvider);
    ref.invalidate(spotSurfWindowProvider);
    ref.invalidate(spotDetailBundleProvider);
  }

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _friendlyError(Object error) {
    if (error is PlatformException) {
      final code = PurchasesErrorHelper.getErrorCode(error);
      if (code == PurchasesErrorCode.paymentPendingError) {
        return 'Your payment is awaiting approval. Premium will activate after it is confirmed; do not buy again.';
      }
      if (code == PurchasesErrorCode.productAlreadyPurchasedError) {
        return 'You already have this subscription. Use Restore purchases or Check subscription.';
      }
    }
    return 'Could not confirm your subscription right now. Please try again or contact support.';
  }

  @override
  Widget build(BuildContext context) {
    final plans = ref.watch(plansProvider);
    final me = ref.watch(meProvider);
    final offer = ref.watch(premiumOfferProvider);
    final isBusy = ref.watch(premiumPurchaseBusyProvider);
    final profile = me.valueOrNull;
    final isPremium = profile?.premium ?? false;
    final awaitingConfirmation = ref.watch(
      premiumPurchasePendingProvider(profile?.id ?? ''),
    );
    final service = ref.watch(revenueCatServiceProvider);
    final config = ref.watch(billingConfigProvider);
    final checkoutReady =
        service.isAvailable &&
        !me.isLoading &&
        config.valueOrNull?['verification_ready'] == true &&
        offer.valueOrNull != null &&
        !offer.isLoading;
    final premiumPlan = plans.valueOrNull?.firstWhere(
      (plan) => plan.id == 'premium',
      orElse: () => BillingPlanModel(
        id: 'premium',
        name: 'Premium',
        priceUsdMonthly: 3.99,
        features: const [
          'Live data on every spot',
          'Best Time Today windows',
          'Tide-aware planning',
          'Ad-free experience',
        ],
      ),
    );
    final price =
        (offer.valueOrNull != null
            ? '${offer.valueOrNull!.price} / month'
            : null) ??
        (premiumPlan == null
            ? '\$3.99 / month'
            : '\$${premiumPlan.priceUsdMonthly.toStringAsFixed(2)} / month');
    final features =
        premiumPlan?.features ??
        const [
          'Live data on every spot',
          'Best Time Today windows',
          'Tide-aware planning',
          'Ad-free experience',
        ];

    return Scaffold(
      appBar: AppBar(title: const Text('Tydes Premium')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _HeroCard(
            isPremium: isPremium,
            price: price,
            loadingOffer: offer.isLoading,
            offerUnavailable: !service.isAvailable && !config.isLoading,
          ),
          const SizedBox(height: 16),
          _PremiumCard(
            features: features,
            isPremium: isPremium,
            isBusy: isBusy,
            checkoutReady: checkoutReady && !awaitingConfirmation,
            isWeb: service.isWeb,
            onBuy: () => _buyPremium(context, ref),
            onRestore: () => _restorePurchases(context, ref),
            onManage: () => _manageSubscription(context, ref),
          ),
          if (awaitingConfirmation && !isPremium) ...[
            const SizedBox(height: 8),
            const Text(
              'Waiting for payment confirmation. Use Check subscription or Restore purchases below; do not subscribe again.',
            ),
          ],
          if (!isPremium &&
              !awaitingConfirmation &&
              service.isAvailable &&
              (offer.hasError ||
                  config.hasError ||
                  (!config.isLoading &&
                      config.valueOrNull?['verification_ready'] != true) ||
                  (!offer.isLoading && offer.valueOrNull == null))) ...[
            const SizedBox(height: 8),
            const Text(
              'The monthly subscription could not be loaded. You have not been charged.',
            ),
            TextButton(
              onPressed: () {
                ref.invalidate(billingConfigProvider);
                ref.invalidate(premiumOfferProvider);
              },
              child: const Text('Retry loading subscription'),
            ),
          ],
          const SizedBox(height: 16),
          _PremiumLegalCard(isWeb: service.isWeb),
          const SizedBox(height: 16),
          _FreeCard(isCurrent: !isPremium),
          if (plans.hasError) ...[
            const SizedBox(height: 16),
            Text(
              'Could not load subscription details right now.',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (me.isLoading) ...[
            const SizedBox(height: 20),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }
}

class _PremiumLegalCard extends StatelessWidget {
  const _PremiumLegalCard({required this.isWeb});
  final bool isWeb;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFFFF8ED),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Subscription and safety notes',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              isWeb
                  ? 'Premium renews monthly unless canceled. The checkout shows your price and billing terms before you pay. Manage or cancel with the provider where you subscribed. Your subscription follows your Tydes account across devices.'
                  : 'Premium renews monthly through your app-store account unless canceled. Payment is charged to your store account at confirmation. Manage or cancel in your store subscription settings. Restore purchases checks for an active subscription.',
            ),
            const SizedBox(height: 10),
            const Text(
              'Forecasts, tides, alerts, and Best Time Today are planning estimates, not navigation or safety-critical advice. Check local hazards before paddling out.',
            ),
            const SizedBox(height: 6),
            const TydesLegalLinks(
              includeSupport: true,
              alignment: WrapAlignment.start,
              dense: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.isPremium,
    required this.price,
    required this.loadingOffer,
    required this.offerUnavailable,
  });

  final bool isPremium;
  final String price;
  final bool loadingOffer;
  final bool offerUnavailable;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isPremium ? 'Premium active' : 'Unlock every forecast',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w900,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isPremium
                ? 'You have live forecasts, tides, and Best Time Today across more breaks.'
                : 'Premium gives you fresh live wave, wind, tide, and best-window tools across Tydes.',
            style: TextStyle(color: scheme.onPrimaryContainer),
          ),
          const SizedBox(height: 16),
          Text(
            loadingOffer ? 'Loading store price...' : price,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w900,
              color: scheme.onPrimaryContainer,
            ),
          ),
          if (offerUnavailable) ...[
            const SizedBox(height: 10),
            Text(
              isPremium
                  ? 'Your Premium access works on this device.'
                  : 'Purchases are not available on this platform yet. If you already subscribed, sign in to the same Tydes account and check your subscription below.',
              style: TextStyle(color: scheme.onPrimaryContainer),
            ),
          ],
        ],
      ),
    );
  }
}

class _PremiumCard extends StatelessWidget {
  const _PremiumCard({
    required this.features,
    required this.isPremium,
    required this.isBusy,
    required this.checkoutReady,
    required this.isWeb,
    required this.onBuy,
    required this.onRestore,
    required this.onManage,
  });

  final List<String> features;
  final bool isPremium;
  final bool isBusy;
  final bool checkoutReady;
  final bool isWeb;
  final VoidCallback onBuy;
  final VoidCallback onRestore;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Premium',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 14),
            ...features.map((feature) => _FeatureBullet(text: feature)),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: isPremium || isBusy || !checkoutReady ? null : onBuy,
              child: isBusy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(isPremium ? 'Current plan' : 'Subscribe monthly'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: isBusy ? null : onRestore,
              child: Text(isWeb ? 'Check subscription' : 'Restore purchases'),
            ),
            if (isPremium)
              TextButton.icon(
                onPressed: isBusy ? null : onManage,
                icon: const Icon(Icons.manage_accounts_outlined),
                label: const Text('Manage subscription'),
              ),
          ],
        ),
      ),
    );
  }
}

class _FreeCard extends StatelessWidget {
  const _FreeCard({required this.isCurrent});

  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            const Icon(Icons.waves_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                isCurrent
                    ? 'Free plan active: one live spot unlock plus cached estimates.'
                    : 'Free plan: cached estimates with one live spot unlock.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeatureBullet extends StatelessWidget {
  const _FeatureBullet({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(
            Icons.check_circle_rounded,
            size: 18,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
