import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../network/api_models.dart';
import '../network/surf_repository.dart';

final billingConfigProvider = FutureProvider<Map<String, dynamic>>((ref) {
  return ref.watch(surfRepositoryProvider).fetchBillingConfig();
});

final revenueCatServiceProvider = Provider<RevenueCatService>((ref) {
  final config = ref.watch(billingConfigProvider).valueOrNull;
  return RevenueCatService(webApiKey: config?['web_api_key'] as String? ?? '');
});

class RevenueCatUnavailableException implements Exception {
  const RevenueCatUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

class RevenueCatPurchaseCancelledException implements Exception {
  const RevenueCatPurchaseCancelledException();
}

class RevenueCatPremiumOffer {
  const RevenueCatPremiumOffer({
    required this.package,
    required this.title,
    required this.price,
  });

  final Package package;
  final String title;
  final String price;
}

class RevenueCatService {
  RevenueCatService({String webApiKey = ''}) : _webApiKey = webApiKey;

  final String _webApiKey;
  bool get isWeb => kIsWeb;
  // RevenueCat SDK keys are public client identifiers intended to ship in the
  // app. The environment value remains available for alternate build targets.
  static const iosApiKey = String.fromEnvironment(
    'REVENUECAT_IOS_API_KEY',
    defaultValue: 'appl_NQxXFQIZnLNDhqfKDSIcIDTvmnO',
  );
  static const androidApiKey = String.fromEnvironment(
    'REVENUECAT_ANDROID_API_KEY',
  );
  static const offeringId = String.fromEnvironment(
    'REVENUECAT_OFFERING_ID',
    defaultValue: 'premium',
  );
  static const packageId = String.fromEnvironment(
    'REVENUECAT_PACKAGE_ID',
    defaultValue: r'$rc_monthly',
  );
  static const entitlementId = String.fromEnvironment(
    'REVENUECAT_ENTITLEMENT_ID',
    defaultValue: 'premium',
  );

  static bool _configured = false;
  static String? _loggedInUserId;

  bool get isAvailable => _platformApiKey.isNotEmpty;

  Future<void> configure({String? appUserId}) async {
    if (_configured) {
      return;
    }

    final apiKey = _platformApiKey;
    if (apiKey.isEmpty) {
      throw const RevenueCatUnavailableException(
        'RevenueCat is not configured for this build yet.',
      );
    }

    await Purchases.configure(
      PurchasesConfiguration(apiKey)..appUserID = appUserId,
    );
    _loggedInUserId = appUserId;
    _configured = true;
  }

  Future<void> logIn(UserProfile profile) async {
    await configure(appUserId: profile.id);
    if (_loggedInUserId != profile.id) {
      await Purchases.logIn(profile.id);
      _loggedInUserId = profile.id;
    }
    await Purchases.setEmail(profile.email);
    if (profile.displayName.trim().isNotEmpty) {
      await Purchases.setDisplayName(profile.displayName.trim());
    }
  }

  Future<RevenueCatPremiumOffer?> loadPremiumOffer(UserProfile profile) async {
    // Offerings and checkout must use the authenticated TYDES account on every platform.
    await logIn(profile);
    final offerings = await Purchases.getOfferings();
    final offering = offeringId.isNotEmpty
        ? offerings.getOffering(offeringId)
        : offerings.current;
    final packages = offering?.availablePackages ?? const <Package>[];
    final configuredPackage = _packageWithIdentifier(packages, packageId);
    final package = configuredPackage;
    if (package == null || package.packageType != PackageType.monthly) {
      return null;
    }

    final product = package.storeProduct;
    return RevenueCatPremiumOffer(
      package: package,
      title: product.title,
      price: product.priceString,
    );
  }

  Future<CustomerInfo> purchasePremium({
    required UserProfile profile,
    required Package package,
  }) async {
    await logIn(profile);
    try {
      final current = await Purchases.getCustomerInfo();
      if (current.entitlements.active.containsKey(entitlementId)) {
        return current;
      }
      final result = await Purchases.purchase(
        PurchaseParams.package(package, customerEmail: profile.email),
      );
      return result.customerInfo;
    } on PlatformException catch (error) {
      final code = PurchasesErrorHelper.getErrorCode(error);
      if (code == PurchasesErrorCode.purchaseCancelledError) {
        throw const RevenueCatPurchaseCancelledException();
      }
      rethrow;
    }
  }

  Future<CustomerInfo> restorePurchases(UserProfile profile) async {
    await logIn(profile);
    return isWeb ? Purchases.getCustomerInfo() : Purchases.restorePurchases();
  }

  Future<Uri?> managementUrl(UserProfile profile) async {
    await logIn(profile);
    final info = await Purchases.getCustomerInfo();
    final url = Uri.tryParse(info.managementURL ?? '');
    return url?.scheme == 'https' && url!.host.isNotEmpty ? url : null;
  }

  Future<void> logOut() async {
    if (!_configured) {
      return;
    }
    try {
      await Purchases.logOut();
    } catch (_) {
      // RevenueCat throws when logging out an anonymous user; logout should
      // still continue locally in that case.
    }
    _loggedInUserId = null;
  }

  String get _platformApiKey {
    if (kIsWeb) {
      return _webApiKey;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return iosApiKey;
      case TargetPlatform.android:
        return androidApiKey;
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        return '';
    }
  }

  Package? _packageWithIdentifier(List<Package> packages, String identifier) {
    if (identifier.isEmpty) {
      return null;
    }
    for (final package in packages) {
      if (package.identifier == identifier) {
        return package;
      }
    }
    return null;
  }
}
