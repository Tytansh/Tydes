import 'package:flutter/material.dart';

import 'admin_feature_library_loader.dart';
import 'admin_feature_module.dart' deferred as admin;

final _adminLibrary = AdminFeatureLibraryLoader(admin.loadLibrary);

class AdminFeaturePage extends StatelessWidget {
  const AdminFeaturePage({super.key});

  @override
  Widget build(BuildContext context) => AdminFeatureLoadGate(
    loadLibrary: _adminLibrary.load,
    libraryLoaded: _adminLibrary.isLoaded,
    buildPage: (_) => admin.buildAdminFeature(),
  );
}

/// Retains the mounted page after loading. Account data stays with the existing
/// account-scoped router/provider lifecycle, never in the shared code loader.
class AdminFeatureLoadGate extends StatefulWidget {
  const AdminFeatureLoadGate({
    super.key,
    required this.loadLibrary,
    required this.buildPage,
    this.libraryLoaded = false,
  });

  final Future<void> Function() loadLibrary;
  final WidgetBuilder buildPage;
  final bool libraryLoaded;

  @override
  State<AdminFeatureLoadGate> createState() => _AdminFeatureLoadGateState();
}

class _AdminFeatureLoadGateState extends State<AdminFeatureLoadGate> {
  Future<void>? _loading;
  Widget? _page;

  @override
  void initState() {
    super.initState();
    if (!widget.libraryLoaded) _loading = widget.loadLibrary();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading == null) return _page ??= widget.buildPage(context);
    return FutureBuilder<void>(
      future: _loading,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          if (!snapshot.hasError) return _page ??= widget.buildPage(context);
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off_outlined, size: 32),
                    const SizedBox(height: 12),
                    const Text(
                      'Could not load admin tools. Check your connection and try again.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => setState(() {
                        _loading = widget.loadLibrary();
                      }),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry admin tools'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return const Scaffold(
          body: Center(
            child: SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      },
    );
  }
}
