import 'package:flutter/widgets.dart';

// Native Google login requires platform credentials and accompanying App Store
// sign-in choices. Do not display an unusable web button in a native release.
class GoogleSignInButton extends StatelessWidget {
  const GoogleSignInButton({
    super.key,
    required this.enabled,
    required this.onCredential,
  });

  final bool enabled;
  final Future<void> Function(
    String credential,
    String challengeId,
    String verifier,
  )
  onCredential;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
