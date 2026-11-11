import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/legal/legal_links.dart';
import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../home/home_page.dart';
import '../alerts/alert_state.dart';
import '../social/social_profile.dart';
import '../social/direct_messages_page.dart';
import '../social/notifications_page.dart';
import '../social/inbox_badges.dart';
import '../spots/spot_detail_page.dart';
import '../spots/spots_page.dart';
import 'google_sign_in_button.dart';
import 'auth_return_path.dart';
import 'auth_entry_layout.dart';

Color _authMuted(BuildContext context, Color light) =>
    Theme.of(context).brightness == Brightness.dark
    ? Theme.of(context).colorScheme.onSurfaceVariant
    : light;

final authStateProvider = FutureProvider.autoDispose((ref) async {
  return ref.watch(surfRepositoryProvider).fetchMe();
});

enum _AuthMode { signIn, signUp }

class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key, this.initialProfile, this.returnTo = '/'});

  final UserProfile? initialProfile;
  final String returnTo;

  @override
  ConsumerState<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends ConsumerState<AuthPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _verificationCodeController = TextEditingController();

  _AuthMode _mode = _AuthMode.signIn;
  bool _loading = false;
  bool _verificationPending = false;
  String? _verificationEmail;
  String? _verificationHint;
  String? _errorText;
  bool _obscurePassword = true;
  UserProfile? _profileSetup;

  @override
  void initState() {
    super.initState();
    _profileSetup = widget.initialProfile;
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _verificationCodeController.dispose();
    super.dispose();
  }

  void _setMode(_AuthMode mode) {
    if (_loading) return;
    setState(() {
      _mode = mode;
      _errorText = null;
      _verificationPending = false;
      _verificationEmail = null;
      _verificationHint = null;
      _verificationCodeController.clear();
    });
  }

  void _refreshAfterAuth() {
    ref.read(inboxForegroundAccountProvider.notifier).state = null;
    ref.invalidate(inboxUnreadCountsProvider);
    ref.invalidate(directMessageThreadsProvider);
    ref.invalidate(socialNotificationsProvider);
    ref.invalidate(alertsProvider);
    ref.invalidate(authStateProvider);
    ref.invalidate(meProvider);
    ref.invalidate(dashboardProvider);
    ref.invalidate(homeAdsProvider);
    ref.invalidate(spotForecastsBySpotProvider);
    ref.invalidate(spotCardForecastProvider);
    ref.invalidate(spotTideProvider);
    ref.invalidate(spotSurfWindowProvider);
    ref.invalidate(spotDetailBundleProvider);
    ref.invalidate(favoriteSpotIdsProvider);
    ref.invalidate(followedUserIdsProvider);
    ref.invalidate(followerUserIdsProvider);
    ref.invalidate(blockedUserIdsProvider);
    ref.invalidate(hiddenFollowingUserIdsProvider);
    ref.invalidate(hiddenFollowerUserIdsProvider);
    ref.invalidate(socialRelationshipHydrationProvider);
    ref.read(socialRefreshKeyProvider.notifier).state++;
  }

  Future<void> _finishAuth(UserProfile profile) async {
    if (!mounted) return;
    if (_needsProfileSetup(profile)) {
      setState(() {
        _profileSetup = profile;
        _verificationPending = false;
        _errorText = null;
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    _refreshAfterAuth();
    // Do not navigate with the previous account's retained AsyncValue. Wait
    // until the new session has a fresh profile, for Google and email alike.
    final currentProfile = await ref.read(meProvider.future);
    if (!mounted) return;
    if (_needsProfileSetup(currentProfile)) {
      await _finishAuth(currentProfile);
      return;
    }
    final destination = safeAuthReturnPath(widget.returnTo);
    final fromGuest = destination.startsWith('/explore');
    ref.read(currentTabProvider.notifier).state = fromGuest
        ? (destination == '/explore/events' ? 2 : 1)
        : 0;
    context.go(fromGuest ? '/' : destination);
  }

  Future<void> _useAnotherAccount() async {
    setState(() => _loading = true);
    await ref.read(surfRepositoryProvider).logout();
    if (!mounted) return;
    _refreshAfterAuth();
    setState(() {
      _profileSetup = null;
      _verificationPending = false;
      _verificationEmail = null;
      _errorText = null;
      _loading = false;
    });
  }

  bool _validateEmailAndPassword({bool requireConfirmation = false}) {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _errorText = 'Enter a valid email address.');
      return false;
    }
    if (password.length < 8) {
      setState(() => _errorText = 'Password must be at least 8 characters.');
      return false;
    }
    if (requireConfirmation && password != _confirmPasswordController.text) {
      setState(() => _errorText = 'Passwords do not match.');
      return false;
    }
    return true;
  }

  Future<void> _submitSignIn() async {
    if (!_validateEmailAndPassword()) return;
    setState(() {
      _loading = true;
      _errorText = null;
    });
    try {
      final locale = ref.read(localeProvider).languageCode;
      final profile = await ref
          .read(surfRepositoryProvider)
          .login(
            _emailController.text.trim(),
            locale,
            password: _passwordController.text,
          );
      await _finishAuth(profile);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = _friendlyAuthError(error);
      });
    }
  }

  Future<void> _submitGoogle(
    String credential,
    String challengeId,
    String verifier,
  ) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _errorText = null;
    });
    try {
      final result = await ref
          .read(surfRepositoryProvider)
          .loginWithGoogle(
            credential: credential,
            challengeId: challengeId,
            verifier: verifier,
            locale: ref.read(localeProvider).languageCode,
            allowSignup: _mode == _AuthMode.signUp,
          );
      if (!mounted) return;
      if (result.verificationRequired) {
        setState(() {
          _loading = false;
          _verificationPending = true;
          _verificationEmail = result.verificationSentTo;
          _verificationHint = result.verificationHint;
        });
        return;
      }
      await _finishAuth(result.user);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = _friendlyAuthError(error);
      });
    }
  }

  Future<void> _submitSignup() async {
    if (!_validateEmailAndPassword(requireConfirmation: true)) return;
    setState(() {
      _loading = true;
      _errorText = null;
    });
    try {
      final locale = ref.read(localeProvider).languageCode;
      final result = await ref
          .read(surfRepositoryProvider)
          .signup(
            email: _emailController.text.trim(),
            password: _passwordController.text,
            locale: locale,
          );
      if (!mounted) return;
      if (result.verificationRequired) {
        setState(() {
          _loading = false;
          _verificationPending = true;
          _verificationEmail =
              result.verificationSentTo ?? _emailController.text.trim();
          _verificationHint = result.verificationHint;
        });
        return;
      }
      await _finishAuth(result.user);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = _friendlyAuthError(error);
      });
    }
  }

  Future<void> _verifyEmail() async {
    final code = _verificationCodeController.text.trim();
    final email = _verificationEmail ?? _emailController.text.trim();
    if (code.length < 4) {
      setState(() => _errorText = 'Enter the verification code.');
      return;
    }
    setState(() {
      _loading = true;
      _errorText = null;
    });
    try {
      final profile = await ref
          .read(surfRepositoryProvider)
          .verifyEmail(email: email, code: code);
      await _finishAuth(profile);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = _friendlyAuthError(error);
      });
    }
  }

  Future<void> _openPasswordReset() async {
    final profile = await showModalBottomSheet<UserProfile>(
      context: context,
      isScrollControlled: true,
      builder: (context) =>
          _PasswordResetSheet(initialEmail: _emailController.text.trim()),
    );
    if (!mounted || profile == null) return;
    await _finishAuth(profile);
  }

  Widget _buildAuthFormContent({
    required bool isSignup,
    required String actionLabel,
  }) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_verificationPending) ...[
          _AuthModeToggle(mode: _mode, onChanged: _setMode),
          const SizedBox(height: 22),
          GoogleSignInButton(enabled: !_loading, onCredential: _submitGoogle),
          TextField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: 'Email',
              prefixIcon: Icon(Icons.email_outlined),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            autofillHints: const [AutofillHints.password],
            decoration: InputDecoration(
              labelText: 'Password',
              helperText: isSignup ? 'Use at least 8 characters.' : null,
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              ),
            ),
          ),
          if (!isSignup)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _loading ? null : _openPasswordReset,
                child: const Text('Forgot password?'),
              ),
            ),
          if (isSignup) ...[
            const SizedBox(height: 14),
            TextField(
              controller: _confirmPasswordController,
              obscureText: _obscurePassword,
              autofillHints: const [AutofillHints.newPassword],
              decoration: const InputDecoration(
                labelText: 'Confirm password',
                prefixIcon: Icon(Icons.lock_reset_rounded),
              ),
            ),
          ],
        ] else ...[
          TextField(
            controller: _verificationCodeController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Verification code',
              prefixIcon: Icon(Icons.mark_email_read_outlined),
            ),
          ),
          if (_verificationHint != null) ...[
            const SizedBox(height: 10),
            _AuthNotice(text: _verificationHint!),
          ],
          const SizedBox(height: 8),
          TextButton(
            onPressed: _loading
                ? null
                : () {
                    setState(() {
                      _verificationPending = false;
                      _errorText = null;
                    });
                  },
            child: const Text('Use a different email'),
          ),
        ],
        if (_errorText != null) ...[
          const SizedBox(height: 14),
          _AuthError(text: _errorText!),
        ],
        const SizedBox(height: 24),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: dark
                ? theme.colorScheme.primary
                : const Color(0xFF073F43),
            foregroundColor: dark ? theme.colorScheme.onPrimary : Colors.white,
            minimumSize: const Size.fromHeight(56),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: _loading
              ? null
              : _verificationPending
              ? _verifyEmail
              : isSignup
              ? _submitSignup
              : _submitSignIn,
          child: Text(actionLabel),
        ),
        if (!_verificationPending) ...[
          const SizedBox(height: 24),
          Text(
            'Just looking around?',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _authMuted(context, const Color(0xFF5A6F77)),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const ValueKey('explore-as-guest'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              backgroundColor: dark
                  ? theme.colorScheme.surfaceContainerHigh
                  : const Color(0xFFE9F3F0),
              foregroundColor: dark
                  ? theme.colorScheme.primary
                  : const Color(0xFF164D59),
              side: BorderSide(
                color: dark
                    ? theme.colorScheme.outlineVariant
                    : const Color(0xFFD2E4DE),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              textStyle: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
            onPressed: _loading ? null : () => context.go('/explore'),
            icon: const Icon(Icons.map_outlined, size: 20),
            label: const Text('Explore the map'),
          ),
          const SizedBox(height: 7),
          Text(
            'No account needed',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _authMuted(context, const Color(0xFF5A6F77)),
              fontSize: 11,
            ),
          ),
        ],
        const SizedBox(height: 24),
        _AuthLegalNote(isSignup: isSignup),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isSignup = _mode == _AuthMode.signUp;
    final setup = _profileSetup;
    final title = setup != null
        ? 'Create your profile'
        : _verificationPending
        ? 'Verify your email'
        : isSignup
        ? 'Create account'
        : 'Welcome back';
    final subtitle = setup != null
        ? 'Choose your name, @tag, and surf level. Location and bio are optional.'
        : _verificationPending
        ? 'Enter the code sent to ${_verificationEmail ?? 'your email'} to finish creating your account.'
        : isSignup
        ? 'Build your surf profile'
        : 'Your spots, your crew, your next session.';
    final actionLabel = _loading
        ? 'Working...'
        : _verificationPending
        ? 'Verify email'
        : isSignup
        ? 'Create account'
        : 'Sign in';

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Theme.of(context).brightness == Brightness.dark
            ? Theme.of(context).scaffoldBackgroundColor
            : const Color(0xFFF9FAF7),
        body: AuthEntryLayout(
          title: title,
          subtitle: subtitle,
          child: setup != null
              ? _ProfileSetupForm(
                  key: ValueKey(setup.id),
                  profile: setup,
                  onCompleted: _finishAuth,
                  onUseAnotherAccount: _useAnotherAccount,
                )
              : _buildAuthFormContent(
                  isSignup: isSignup,
                  actionLabel: actionLabel,
                ),
        ),
      ),
    );
  }
}

class _AuthLegalNote extends StatelessWidget {
  const _AuthLegalNote({required this.isSignup});

  final bool isSignup;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          isSignup
              ? 'By creating an account, you agree to Tydes Terms and Privacy Policy.'
              : kIsWeb
              ? 'By continuing with Google, you agree to Tydes Terms and Privacy Policy.'
              : 'Need help or want to review Tydes policies?',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: _authMuted(context, const Color(0xFF5E6A68)),
            height: 1.35,
          ),
        ),
        const SizedBox(height: 2),
        const TydesLegalLinks(
          includeSupport: true,
          includeAbout: true,
          dense: true,
        ),
      ],
    );
  }
}

class _AuthModeToggle extends StatelessWidget {
  const _AuthModeToggle({required this.mode, required this.onChanged});

  final _AuthMode mode;
  final ValueChanged<_AuthMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).brightness == Brightness.dark
                ? Theme.of(context).colorScheme.outlineVariant
                : const Color(0xFFDEE6E5),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _AuthModeButton(
              label: 'Sign in',
              icon: Icons.login_rounded,
              selected: mode == _AuthMode.signIn,
              onTap: () => onChanged(_AuthMode.signIn),
            ),
          ),
          Expanded(
            child: _AuthModeButton(
              label: 'Sign up',
              icon: Icons.person_add_alt_1_rounded,
              selected: mode == _AuthMode.signUp,
              onTap: () => onChanged(_AuthMode.signUp),
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthModeButton extends StatelessWidget {
  const _AuthModeButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected
                  ? dark
                        ? theme.colorScheme.primary
                        : const Color(0xFF168F99)
                  : Colors.transparent,
              width: 2.5,
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: selected
                  ? dark
                        ? theme.colorScheme.primary
                        : const Color(0xFF079CA3)
                  : _authMuted(context, const Color(0xFF5F737C)),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: selected
                    ? dark
                          ? theme.colorScheme.primary
                          : const Color(0xFF073F43)
                    : _authMuted(context, const Color(0xFF5F737C)),
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _needsProfileSetup(UserProfile profile) {
  return profile.displayName.trim().isEmpty ||
      profile.handle.trim().isEmpty ||
      profile.surfSkill.trim().isEmpty;
}

class _ProfileSetupForm extends ConsumerStatefulWidget {
  const _ProfileSetupForm({
    super.key,
    required this.profile,
    required this.onCompleted,
    required this.onUseAnotherAccount,
  });

  final UserProfile profile;
  final Future<void> Function(UserProfile) onCompleted;
  final Future<void> Function() onUseAnotherAccount;

  @override
  ConsumerState<_ProfileSetupForm> createState() => _ProfileSetupFormState();
}

class _ProfileSetupFormState extends ConsumerState<_ProfileSetupForm> {
  late final TextEditingController _nameController;
  late final TextEditingController _handleController;
  late final TextEditingController _locationController;
  late final TextEditingController _bioController;
  String? _skill;
  String? _handleError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.profile.displayName);
    _handleController = TextEditingController(text: widget.profile.handle);
    _locationController = TextEditingController(
      text: widget.profile.homeRegion,
    );
    _bioController = TextEditingController(text: widget.profile.bio);
    _skill = widget.profile.surfSkill.isEmpty ? null : widget.profile.surfSkill;
    _handleController.addListener(() {
      if (_handleError != null) {
        setState(() => _handleError = null);
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _handleController.dispose();
    _locationController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final displayName = _nameController.text.trim();
    final handle = _handleController.text.trim().replaceAll('@', '');
    final location = _locationController.text.trim();
    final bio = _bioController.text.trim();

    if (displayName.isEmpty || handle.isEmpty || _skill == null) {
      _showError('Name, @tag, and surf level are required.');
      return;
    }
    if (!RegExp(r'^[a-z0-9_]+$').hasMatch(handle)) {
      setState(
        () => _handleError =
            '@tag can only use lowercase letters, numbers, and underscores.',
      );
      return;
    }

    setState(() {
      _handleError = null;
      _saving = true;
    });
    try {
      final profile = await ref
          .read(surfRepositoryProvider)
          .updateProfile(
            displayName: displayName,
            handle: handle,
            bio: bio,
            surfSkill: _skill!,
            homeRegion: location,
            avatarUrl: widget.profile.avatarUrl,
            coverUrl: widget.profile.coverUrl,
          );
      if (!mounted) return;
      await widget.onCompleted(profile);
    } catch (error) {
      if (!mounted) return;
      final message = error.toString().replaceFirst('Bad state: ', '');
      if (_isHandleTakenMessage(message)) {
        setState(() => _handleError = 'Tag already taken');
        return;
      }
      _showError(message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AuthNotice(text: 'Signed in as ${widget.profile.email}'),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _saving ? null : widget.onUseAnotherAccount,
            child: const Text('Use another account'),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _nameController,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          maxLength: 32,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'Your display name',
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _handleController,
          textInputAction: TextInputAction.next,
          maxLength: 20,
          decoration: InputDecoration(
            labelText: '@tag',
            hintText: 'yourtag',
            prefixText: '@',
            errorText: _handleError,
            prefixIcon: const Icon(Icons.alternate_email),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _locationController,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          maxLength: 40,
          decoration: const InputDecoration(
            labelText: 'Location (optional)',
            hintText: 'Bali, Gold Coast, Canggu...',
            prefixIcon: Icon(Icons.place_outlined),
          ),
        ),
        const SizedBox(height: 6),
        Text('Surf level', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          emptySelectionAllowed: true,
          segments: const [
            ButtonSegment<String>(value: 'beginner', label: Text('Beginner')),
            ButtonSegment<String>(
              value: 'intermediate',
              label: Text('Skilled'),
            ),
            ButtonSegment<String>(value: 'pro', label: Text('Pro')),
          ],
          selected: _skill == null ? const {} : {_skill!},
          onSelectionChanged: _saving
              ? null
              : (selection) => setState(
                  () => _skill = selection.isEmpty ? null : selection.first,
                ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _bioController,
          maxLines: 3,
          maxLength: 180,
          decoration: const InputDecoration(
            labelText: 'Bio (optional)',
            hintText:
                'Tell people what kind of waves and surf trips you are into.',
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).brightness == Brightness.dark
                  ? Theme.of(context).colorScheme.primary
                  : const Color(0xFF073F43),
              foregroundColor: Theme.of(context).brightness == Brightness.dark
                  ? Theme.of(context).colorScheme.onPrimary
                  : Colors.white,
              minimumSize: const Size.fromHeight(56),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving...' : 'Finish profile'),
          ),
        ),
        const SizedBox(height: 10),
        const _AuthLegalNote(isSignup: true),
      ],
    );
  }
}

bool _isHandleTakenMessage(String message) {
  return message.toLowerCase().contains('tag is already taken') ||
      message.toLowerCase().contains('tag already taken');
}

class _PasswordResetSheet extends ConsumerStatefulWidget {
  const _PasswordResetSheet({required this.initialEmail});

  final String initialEmail;

  @override
  ConsumerState<_PasswordResetSheet> createState() =>
      _PasswordResetSheetState();
}

class _PasswordResetSheetState extends ConsumerState<_PasswordResetSheet> {
  late final TextEditingController _emailController;
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _codeSent = false;
  bool _loading = false;
  bool _obscurePassword = true;
  String? _resetHint;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController(text: widget.initialEmail);
  }

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _errorText = 'Enter the email for your account.');
      return;
    }
    setState(() {
      _loading = true;
      _errorText = null;
    });
    try {
      final hint = await ref
          .read(surfRepositoryProvider)
          .requestPasswordReset(email: email);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _codeSent = true;
        _resetHint = hint;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = _friendlyAuthError(error);
      });
    }
  }

  Future<void> _resetPassword() async {
    final email = _emailController.text.trim();
    final code = _codeController.text.trim();
    final password = _passwordController.text;
    if (code.length < 4) {
      setState(() => _errorText = 'Enter the reset code from your email.');
      return;
    }
    if (password.length < 8) {
      setState(() => _errorText = 'Password must be at least 8 characters.');
      return;
    }
    if (password != _confirmPasswordController.text) {
      setState(() => _errorText = 'Passwords do not match.');
      return;
    }

    setState(() {
      _loading = true;
      _errorText = null;
    });
    try {
      final profile = await ref
          .read(surfRepositoryProvider)
          .confirmPasswordReset(email: email, code: code, password: password);
      if (!mounted) return;
      Navigator.of(context).pop(profile);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = _friendlyAuthError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 24 + bottomInset),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Theme.of(context).colorScheme.outlineVariant
                        : const Color(0xFFD5D0C6),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Reset password',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              Text(
                'We’ll email you a code, then you can choose a new password.',
                style: TextStyle(
                  color: _authMuted(context, const Color(0xFF5D686C)),
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                enabled: !_codeSent && !_loading,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.email_outlined),
                ),
              ),
              if (_codeSent) ...[
                const SizedBox(height: 14),
                TextField(
                  controller: _codeController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Reset code',
                    prefixIcon: Icon(Icons.mark_email_read_outlined),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: InputDecoration(
                    labelText: 'New password',
                    helperText: 'Use at least 8 characters.',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _confirmPasswordController,
                  obscureText: _obscurePassword,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: const InputDecoration(
                    labelText: 'Confirm new password',
                    prefixIcon: Icon(Icons.lock_reset_rounded),
                  ),
                ),
              ],
              if (_resetHint != null) ...[
                const SizedBox(height: 12),
                _AuthNotice(text: _resetHint!),
              ],
              if (_errorText != null) ...[
                const SizedBox(height: 12),
                _AuthError(text: _errorText!),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _loading
                      ? null
                      : _codeSent
                      ? _resetPassword
                      : _sendCode,
                  child: Text(
                    _loading
                        ? 'Working...'
                        : _codeSent
                        ? 'Reset password'
                        : 'Email reset code',
                  ),
                ),
              ),
              if (_codeSent) ...[
                const SizedBox(height: 10),
                Center(
                  child: TextButton(
                    onPressed: _loading
                        ? null
                        : () {
                            setState(() {
                              _codeSent = false;
                              _resetHint = null;
                              _errorText = null;
                              _codeController.clear();
                              _passwordController.clear();
                              _confirmPasswordController.clear();
                            });
                          },
                    child: const Text('Use a different email'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AuthNotice extends StatelessWidget {
  const _AuthNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: dark
            ? theme.colorScheme.primaryContainer
            : const Color(0xFFE7F6F3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        text,
        style: dark
            ? TextStyle(color: theme.colorScheme.onPrimaryContainer)
            : null,
      ),
    );
  }
}

class _AuthError extends StatelessWidget {
  const _AuthError({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: dark
            ? theme.colorScheme.errorContainer
            : const Color(0xFFFFE8E1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: dark ? theme.colorScheme.onErrorContainer : null,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String _friendlyAuthError(Object error) {
  return error.toString().replaceFirst('Bad state: ', '');
}
