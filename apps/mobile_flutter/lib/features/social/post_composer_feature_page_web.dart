import 'package:flutter/material.dart';

import '../../core/network/api_models.dart';
import 'post_composer_library_loader.dart';
import 'post_composer_module.dart' deferred as composer;

final _composerLibrary = PostComposerLibraryLoader(composer.loadLibrary);

class PostComposerFeaturePage extends StatelessWidget {
  const PostComposerFeaturePage({super.key, required this.spots});

  final List<SpotModel> spots;

  @override
  Widget build(BuildContext context) => PostComposerLoadGate(
    loadLibrary: _composerLibrary.load,
    libraryLoaded: _composerLibrary.isLoaded,
    buildPage: (_) => composer.buildPostComposer(spots: spots),
  );
}

/// The loading shell is isolated from composer drafts/providers and retains its page
/// after loading. FutureBuilder ignores completion after the shell is removed.
class PostComposerLoadGate extends StatefulWidget {
  const PostComposerLoadGate({
    super.key,
    required this.loadLibrary,
    required this.buildPage,
    this.libraryLoaded = false,
  });

  final Future<void> Function() loadLibrary;
  final WidgetBuilder buildPage;
  final bool libraryLoaded;

  @override
  State<PostComposerLoadGate> createState() => _PostComposerLoadGateState();
}

class _PostComposerLoadGateState extends State<PostComposerLoadGate> {
  Future<void>? _loading;
  Widget? _page;

  @override
  void initState() {
    super.initState();
    if (!widget.libraryLoaded) _loading = widget.loadLibrary();
  }

  @override
  Widget build(BuildContext context) {
    // Keep the FutureBuilder in the tree after an asynchronous load. Removing
    // that parent on the next rebuild would remount the composer and lose its state.
    if (_loading == null) {
      return _page ??= widget.buildPage(context);
    }
    return FutureBuilder<void>(
      future: _loading,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          if (!snapshot.hasError) {
            return _page ??= widget.buildPage(context);
          }
          return _shell(
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off_outlined, size: 32),
                    const SizedBox(height: 12),
                    const Text(
                      'Could not load the post editor. Check your connection and try again.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => setState(() {
                        _loading = widget.loadLibrary();
                      }),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry post editor'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return _shell(
          const Center(
            child: SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      },
    );
  }

  // Opening Post must never temporarily remove its Close action while code
  // downloads or after a retryable load error. The loaded editor owns its UI.
  Widget _shell(Widget child) => Scaffold(
    body: SafeArea(
      child: Stack(
        children: [
          Positioned.fill(child: child),
          Positioned(
            top: 4,
            right: 12,
            child: IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    ),
  );
}
