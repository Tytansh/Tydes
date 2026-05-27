import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/billing/revenuecat_service.dart';
import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../home/home_page.dart';

final plansProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchPlans(),
);

final premiumOfferProvider = FutureProvider<RevenueCatPremiumOffer?>((ref) {
  final service = ref.watch(revenueCatServiceProvider);
  if (!service.isAvailable) {
    return Future.value();
  }
  return service.loadPremiumOffer();
});

final premiumPurchaseBusyProvider = StateProvider<bool>((ref) => false);

class PaywallPage extends ConsumerWidget {
  const PaywallPage({super.key});

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
        'RevenueCat keys are not in this build yet. Add the iOS/Android SDK keys before testing purchases.',
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
      final syncedProfile = await ref
          .read(surfRepositoryProvider)
          .syncRevenueCatPremium();
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
    if (!service.isAvailable) {
      _showMessage(
        context,
        'RevenueCat keys are not in this build yet. Add the iOS/Android SDK keys before restoring.',
      );
      return;
    }

    ref.read(premiumPurchaseBusyProvider.notifier).state = true;
    try {
      await service.restorePurchases(profile);
      final syncedProfile = await ref
          .read(surfRepositoryProvider)
          .syncRevenueCatPremium();
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

  void _refreshPremiumState(WidgetRef ref) {
    ref.invalidate(meProvider);
    ref.invalidate(homeAdsProvider);
    ref.invalidate(dashboardProvider);
  }

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _friendlyError(Object error) {
    final message = error.toString().replaceFirst('Bad state: ', '');
    if (message.contains('RevenueCat server API key')) {
      return 'Backend RevenueCat secret key is missing. Add it in Render before testing live purchases.';
    }
    return message;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plans = ref.watch(plansProvider);
    final me = ref.watch(meProvider);
    final offer = ref.watch(premiumOfferProvider);
    final isBusy = ref.watch(premiumPurchaseBusyProvider);
    final profile = me.valueOrNull;
    final isPremium = profile?.premium ?? false;
    final premiumPlan = plans.valueOrNull?.firstWhere(
      (plan) => plan.id == 'premium',
      orElse: () => BillingPlanModel(
        id: 'premium',
        name: 'Premium',
        priceUsdMonthly: 7.99,
        features: const [
          'Live data on every spot',
          'Best Time Today windows',
          'Tide-aware planning',
          'Ad-light experience',
        ],
      ),
    );
    final price =
        offer.valueOrNull?.price ??
        (premiumPlan == null
            ? '\$7.99 / month'
            : '\$${premiumPlan.priceUsdMonthly.toStringAsFixed(2)} / month');
    final features =
        premiumPlan?.features ??
        const [
          'Live data on every spot',
          'Best Time Today windows',
          'Tide-aware planning',
          'Ad-light experience',
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
            offerUnavailable: !ref.read(revenueCatServiceProvider).isAvailable,
          ),
          const SizedBox(height: 16),
          _PremiumCard(
            features: features,
            isPremium: isPremium,
            isBusy: isBusy,
            onBuy: () => _buyPremium(context, ref),
            onRestore: () => _restorePurchases(context, ref),
          ),
          const SizedBox(height: 16),
          _FreeCard(isCurrent: !isPremium),
          if (plans.hasError) ...[
            const SizedBox(height: 16),
            Text(
              'Could not load backend plans: ${plans.error}',
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
              'Store purchases are disabled until RevenueCat SDK keys are added to this build.',
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
    required this.onBuy,
    required this.onRestore,
  });

  final List<String> features;
  final bool isPremium;
  final bool isBusy;
  final VoidCallback onBuy;
  final VoidCallback onRestore;

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
              onPressed: isPremium || isBusy ? null : onBuy,
              child: isBusy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(isPremium ? 'Current plan' : 'Upgrade to Premium'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: isBusy ? null : onRestore,
              child: const Text('Restore purchases'),
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
