import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/billing/revenuecat_service.dart';
import '../../core/network/api_error_message.dart';
import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../home/home_page.dart';
import 'auth_account_refresh.dart';
import 'auth_entry_layout.dart';
import 'auth_return_path.dart';
import 'email_verification_sheet.dart';

/// Signup already sends a code. Carry that fact into the central gate rather
/// than sending a duplicate when authentication changes the route.
class PendingEmailVerification {
  const PendingEmailVerification({
    required this.accountId,
    this.email,
    this.hint,
  });
  final String accountId;
  final String? email;
  final String? hint;
}

final pendingEmailVerificationProvider =
    StateProvider<PendingEmailVerification?>((_) => null);

bool needsAccountProfile(UserProfile profile) =>
    profile.displayName.trim().isEmpty ||
    profile.handle.trim().isEmpty ||
    profile.surfSkill.trim().isEmpty;

/// The router lands here while restoring a session; no private widget is built.
class AccountCheckPage extends ConsumerWidget {
  const AccountCheckPage({super.key, this.returnTo = '/'});
  final String returnTo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(meProvider);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (account.isLoading)
                    const CircularProgressIndicator()
                  else
                    const Icon(Icons.cloud_off_outlined, size: 36),
                  const SizedBox(height: 20),
                  Text(
                    account.isLoading
                        ? 'Loading your account…'
                        : 'Could not load your account. Your session is saved. Check your connection and try again.',
                    textAlign: TextAlign.center,
                  ),
                  if (!account.isLoading) ...[
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: () => ref.invalidate(meProvider),
                      child: const Text('Retry'),
                    ),
                    TextButton(
                      onPressed: () => context.go(loginForPath(returnTo)),
                      child: const Text('Go to sign in'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class VerificationGatePage extends ConsumerWidget {
  const VerificationGatePage({super.key, this.returnTo = '/'});
  final String returnTo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(meProvider);
    if (account.isLoading || account.hasError || account.valueOrNull == null) {
      return AccountCheckPage(returnTo: returnTo);
    }
    final profile = account.requireValue;
    return _VerificationAccount(
      key: ValueKey(profile.id),
      profile: profile,
      returnTo: safeAuthReturnPath(returnTo),
    );
  }
}

class _VerificationAccount extends ConsumerStatefulWidget {
  const _VerificationAccount({
    super.key,
    required this.profile,
    required this.returnTo,
  });
  final UserProfile profile;
  final String returnTo;

  @override
  ConsumerState<_VerificationAccount> createState() =>
      _VerificationAccountState();
}

class _VerificationAccountState extends ConsumerState<_VerificationAccount> {
  final _code = TextEditingController();
  EmailVerificationSession? _session;
  bool _busy = false;
  String? _sentTo;
  String? _error;

  bool get _sameAccount =>
      ref.read(meProvider).valueOrNull?.id == widget.profile.id;

  @override
  void initState() {
    super.initState();
    final pending = ref.read(pendingEmailVerificationProvider);
    if (pending?.accountId == widget.profile.id) {
      _sentTo = pending?.email ?? widget.profile.email;
    }
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<EmailVerificationSession> _ownerSession() async {
    if (!_sameAccount) {
      throw StateError('Your account changed. Please try again.');
    }
    final session = _session ??= await ref
        .read(emailVerificationApiProvider)
        .openSession(widget.profile.id);
    if (!_sameAccount) {
      throw StateError('Your account changed. Please try again.');
    }
    return session;
  }

  Future<void> _act(String action) async {
    if (_busy) return;
    if (action == 'confirm' &&
        !RegExp(r'^\d{6}$').hasMatch(_code.text.trim())) {
      setState(() => _error = 'Enter the six-digit code from your email.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await _ownerSession();
      bool verified;
      if (action == 'confirm') {
        await session.confirm(_code.text.trim());
        verified = true;
      } else if (action == 'refresh') {
        verified = await session.refreshVerified();
        if (!verified) {
          throw StateError(
            'Your email is not verified yet. Enter your code or send a new one.',
          );
        }
      } else {
        final dispatch = await session.requestCode();
        verified = dispatch.alreadyVerified;
        if (!verified && mounted && _sameAccount) {
          setState(() => _sentTo = dispatch.email);
          ref
              .read(pendingEmailVerificationProvider.notifier)
              .state = PendingEmailVerification(
            accountId: widget.profile.id,
            email: dispatch.email,
          );
        }
      }
      if (!mounted || !_sameAccount || !verified) return;
      ref.read(pendingEmailVerificationProvider.notifier).state = null;
      // Only a fresh /users/me for this token may open private routes.
      refreshAuthenticatedAccount(ref);
      final profile = await ref.read(meProvider.future);
      if (!mounted || profile.id != widget.profile.id) return;
      if (!profile.emailVerified) {
        throw StateError('Email verification was not confirmed. Try again.');
      }
      context.go(widget.returnTo);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leaveAccount({bool delete = false}) async {
    if (_busy || !_sameAccount) return;
    if (delete) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete account?'),
          content: const Text(
            'Permanently delete your Tydes account and its content. You can create a new account with the same email afterward. Cancel any active subscription through Manage subscription or your app store before deleting.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true || !_sameAccount) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (delete) {
        await (await _ownerSession()).deleteAccount();
      } else {
        await ref.read(surfRepositoryProvider).logout();
      }
      if (!mounted) return;
      // The verification gate must not initialize billing (which fetches a
      // private config). Clear an already-open billing identity only.
      if (ref.exists(revenueCatServiceProvider)) {
        await ref.read(revenueCatServiceProvider).logOut();
      }
      if (!mounted) return;
      ref.read(pendingEmailVerificationProvider.notifier).state = null;
      refreshAuthenticatedAccount(ref);
      context.go(loginForPath(widget.returnTo));
    } catch (error) {
      if (mounted) setState(() => _error = friendlyErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = ref.watch(pendingEmailVerificationProvider);
    final hint = pending?.accountId == widget.profile.id ? pending?.hint : null;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: AuthEntryLayout(
          title: 'Verify your email',
          subtitle:
              'One more step to open your Tydes account. Your profile and sign-in are saved.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.mark_email_unread_outlined, size: 40),
              const SizedBox(height: 18),
              Text(
                widget.profile.email,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Text(
                _sentTo == null
                    ? 'Enter a code you already received, or choose Send code. We’ll send a six-digit code to this address only when you ask.'
                    : 'Enter the six-digit code sent to $_sentTo. It expires in 15 minutes. Check your spam folder too.',
              ),
              if (hint != null) ...[const SizedBox(height: 12), Text(hint)],
              const SizedBox(height: 20),
              TextField(
                key: const ValueKey('email-verification-code'),
                controller: _code,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'Verification code',
                ),
                onSubmitted: (_) => _act('confirm'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 18),
              FilledButton(
                onPressed: _busy ? null : () => _act('confirm'),
                child: Text(_busy ? 'Please wait…' : 'Verify email'),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: _busy ? null : () => _act('send'),
                child: Text(_sentTo == null ? 'Send code' : 'Resend code'),
              ),
              TextButton(
                onPressed: _busy ? null : () => _act('refresh'),
                child: const Text('I already verified my email'),
              ),
              const Divider(height: 28),
              TextButton(
                onPressed: _busy ? null : () => _leaveAccount(),
                child: const Text('Sign out / use another account'),
              ),
              TextButton(
                onPressed: _busy ? null : () => context.go('/explore'),
                child: const Text('Explore as a guest'),
              ),
              TextButton(
                onPressed: _busy ? null : () => _leaveAccount(delete: true),
                child: const Text('Delete account'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
