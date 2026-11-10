import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<void> copyPublicLink(BuildContext context, String url) async {
  try {
    await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Public link copied.')));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not copy the link. Please try again.'),
        ),
      );
    }
  }
}

class CopyPublicLinkButton extends StatelessWidget {
  const CopyPublicLinkButton({super.key, required this.url});
  final String url;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Copy public link',
    icon: const Icon(Icons.link),
    onPressed: () => copyPublicLink(context, url),
  );
}
