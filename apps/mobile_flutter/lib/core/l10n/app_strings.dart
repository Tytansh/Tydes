import 'package:flutter/material.dart';

class AppStrings {
  AppStrings(this.locale);

  final Locale locale;

  static const supportedLocales = [Locale('en'), Locale('id')];

  static AppStrings of(BuildContext context) {
    final locale = Localizations.localeOf(context);
    return AppStrings(locale);
  }

  String get appName =>
      locale.languageCode == 'id' ? 'Perjalanan Ombak' : 'Surf Travel';
  String get welcome => locale.languageCode == 'id'
      ? 'Rencanakan trip ombak berikutnya.'
      : 'Plan your next wave-driven trip.';
  String get home => locale.languageCode == 'id' ? 'Feed' : 'Feed';
  String get spots => locale.languageCode == 'id' ? 'Spot' : 'Spots';
  String get trips => locale.languageCode == 'id' ? 'Travel' : 'Travel';
  String get alerts => locale.languageCode == 'id' ? 'Peringatan' : 'Alerts';
  String get profile => locale.languageCode == 'id' ? 'Profil' : 'Profile';
  String get premium => locale.languageCode == 'id' ? 'Premium' : 'Premium';
  String get signIn => locale.languageCode == 'id' ? 'Masuk' : 'Sign in';
}
