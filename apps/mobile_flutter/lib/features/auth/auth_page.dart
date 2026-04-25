import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../core/network/surf_repository.dart';
import '../home/home_page.dart';
import '../spots/spot_detail_page.dart';

final authStateProvider = FutureProvider.autoDispose((ref) async {
  return ref.watch(surfRepositoryProvider).fetchMe();
});

class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key});

  @override
  ConsumerState<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends ConsumerState<AuthPage> {
  final _emailController = TextEditingController(text: 'demo@surftravel.app');
  bool _loading = false;
  bool _signupLoading = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _loading = true);
    final locale = ref.read(localeProvider).languageCode;
    await ref.read(surfRepositoryProvider).login(_emailController.text, locale);
    if (mounted) {
      ref.invalidate(authStateProvider);
      ref.invalidate(meProvider);
      ref.invalidate(dashboardProvider);
      ref.invalidate(homeAdsProvider);
      ref.invalidate(spotForecastProvider);
      ref.invalidate(spotTideProvider);
      ref.invalidate(spotDetailBundleProvider);
      setState(() => _loading = false);
      Navigator.of(context).pop();
    }
  }

  Future<void> _joinWaitlist() async {
    setState(() => _signupLoading = true);
    await ref.read(surfRepositoryProvider).joinWaitlist(_emailController.text);
    if (!mounted) return;
    setState(() => _signupLoading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${_emailController.text} added to the beta list'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Welcome back',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            const Text(
              'Use any demo email for a free account, include +premium to preview paid unlocks, or join the beta list so we can contact future users.',
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _emailController,
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _loading ? null : _submit,
              child: Text(_loading ? 'Signing in...' : 'Continue'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _signupLoading ? null : _joinWaitlist,
              child: Text(_signupLoading ? 'Joining...' : 'Join beta list'),
            ),
          ],
        ),
      ),
    );
  }
}
