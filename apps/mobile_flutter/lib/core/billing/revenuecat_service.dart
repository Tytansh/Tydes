import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../network/api_models.dart';

final revenueCatServiceProvider = Provider<RevenueCatService>((ref) {
  return RevenueCatService();
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
  static const iosApiKey = String.fromEnvironment('REVENUECAT_IOS_API_KEY');
  static const androidApiKey = String.fromEnvironment(
    'REVENUECAT_ANDROID_API_KEY',
  );
  static const offeringId = String.fromEnvironment('REVENUECAT_OFFERING_ID');
  static const entitlementId = String.fromEnvironment(
    'REVENUECAT_ENTITLEMENT_ID',
    defaultValue: 'premium',
  );

  static bool _configured = false;
  static String? _loggedInUserId;

  bool get isAvailable => _platformApiKey.isNotEmpty;

  Future<void> configure() async {
    if (_configured) {
      return;
    }

    final apiKey = _platformApiKey;
    if (apiKey.isEmpty) {
      throw const RevenueCatUnavailableException(
        'RevenueCat is not configured for this build yet.',
      );
    }

    await Purchases.configure(PurchasesConfiguration(apiKey));
    _configured = true;
  }

  Future<void> logIn(UserProfile profile) async {
    await configure();
    if (_loggedInUserId != profile.id) {
      await Purchases.logIn(profile.id);
      _loggedInUserId = profile.id;
    }
    await Purchases.setEmail(profile.email);
    if (profile.displayName.trim().isNotEmpty) {
      await Purchases.setDisplayName(profile.displayName.trim());
    }
  }

  Future<RevenueCatPremiumOffer?> loadPremiumOffer() async {
    await configure();
    final offerings = await Purchases.getOfferings();
    final offering = offeringId.isNotEmpty
        ? offerings.getOffering(offeringId)
        : offerings.current;
    final package =
        offering?.monthly ??
        (offering?.availablePackages.isNotEmpty == true
            ? offering!.availablePackages.first
            : null);
    if (package == null) {
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
    return Purchases.restorePurchases();
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
      return '';
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
}
