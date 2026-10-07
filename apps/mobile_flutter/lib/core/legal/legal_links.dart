import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

const tydesPrivacyPolicyUrl = String.fromEnvironment(
  'PRIVACY_POLICY_URL',
  defaultValue: 'https://tydes.io/privacy',
);
const tydesTermsOfUseUrl = String.fromEnvironment(
  'TERMS_OF_USE_URL',
  defaultValue: 'https://tydes.io/terms',
);
const tydesSupportEmail = String.fromEnvironment(
  'SUPPORT_EMAIL',
  defaultValue: 'support@tydes.io',
);

Future<void> launchTydesPrivacyPolicy(BuildContext context) {
  return launchTydesExternalLink(context, tydesPrivacyPolicyUrl);
}

Future<void> launchTydesTermsOfUse(BuildContext context) {
  return launchTydesExternalLink(context, tydesTermsOfUseUrl);
}

Future<void> launchTydesSupportEmail(
  BuildContext context, {
  String subject = 'Tydes support',
  String body = 'Tell us what happened and we will help.',
}) async {
  final uri = Uri(
    scheme: 'mailto',
    path: tydesSupportEmail,
    queryParameters: {'subject': subject, 'body': body},
  );
  final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!launched && context.mounted) _showLegalLaunchError(context);
}

Future<void> launchTydesExternalLink(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) {
    _showLegalLaunchError(context);
    return;
  }
  final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!launched && context.mounted) _showLegalLaunchError(context);
}

void _showLegalLaunchError(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Could not open this link right now.')),
  );
}

class TydesLegalLinks extends StatelessWidget {
  const TydesLegalLinks({
    super.key,
    this.includeSupport = false,
    this.alignment = WrapAlignment.center,
    this.dense = false,
  });

  final bool includeSupport;
  final WrapAlignment alignment;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final style = TextButton.styleFrom(
      visualDensity: dense ? VisualDensity.compact : null,
      tapTargetSize: dense
          ? MaterialTapTargetSize.shrinkWrap
          : MaterialTapTargetSize.padded,
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10),
      minimumSize: Size(0, dense ? 32 : 40),
    );
    return Wrap(
      alignment: alignment,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 2,
      children: [
        TextButton(
          style: style,
          onPressed: () => launchTydesTermsOfUse(context),
          child: const Text('Terms'),
        ),
        TextButton(
          style: style,
          onPressed: () => launchTydesPrivacyPolicy(context),
          child: const Text('Privacy'),
        ),
        if (includeSupport)
          TextButton(
            style: style,
            onPressed: () => launchTydesSupportEmail(context),
            child: const Text('Support'),
          ),
      ],
    );
  }
}
