import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../home/home_page.dart';
import '../spots/spot_detail_page.dart';
import '../spots/spots_page.dart';

final authStateProvider = FutureProvider.autoDispose((ref) async {
  return ref.watch(surfRepositoryProvider).fetchMe();
});

enum _AuthMode { signIn, signUp }

class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key});

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

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _verificationCodeController.dispose();
    super.dispose();
  }

  void _setMode(_AuthMode mode) {
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
    ref.invalidate(authStateProvider);
    ref.invalidate(meProvider);
    ref.invalidate(dashboardProvider);
    ref.invalidate(homeAdsProvider);
    ref.invalidate(spotForecastsBySpotProvider);
    ref.invalidate(spotCardForecastProvider);
    ref.invalidate(spotTideProvider);
    ref.invalidate(spotSurfWindowProvider);
    ref.invalidate(spotDetailBundleProvider);
  }

  Future<void> _finishAuth(UserProfile profile) async {
    if (!mounted) return;
    _refreshAfterAuth();
    setState(() => _loading = false);
    if (_needsProfileSetup(profile)) {
      final completed = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        isDismissible: false,
        enableDrag: false,
        builder: (context) => _ProfileSetupSheet(profile: profile),
      );
      if (!mounted || completed != true) return;
      _refreshAfterAuth();
    }
    Navigator.of(context).pop();
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

  @override
  Widget build(BuildContext context) {
    final isSignup = _mode == _AuthMode.signUp;
    final title = _verificationPending
        ? 'Verify your email'
        : isSignup
        ? 'Create account'
        : 'Welcome back';
    final subtitle = _verificationPending
        ? 'Enter the code sent to ${_verificationEmail ?? 'your email'} to finish creating your account.'
        : isSignup
        ? 'Build your surf profile'
        : 'Sign in to unlock your saved spots, alerts, and live forecast tools.';
    final actionLabel = _loading
        ? 'Working...'
        : _verificationPending
        ? 'Verify email'
        : isSignup
        ? 'Create account'
        : 'Sign in';

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFDFF5F2), Color(0xFFF8F7F2), Color(0xFFFFF2E2)],
            stops: [0, 0.58, 1],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final maxWidth = constraints.maxWidth > 560
                  ? 500.0
                  : double.infinity;
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 28),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: IconButton.filledTonal(
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: Icon(
                              Navigator.of(context).canPop()
                                  ? Icons.arrow_back_rounded
                                  : Icons.close_rounded,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        _AuthBrandHeader(title: title, subtitle: subtitle),
                        const SizedBox(height: 18),
                        _AuthFormCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (!_verificationPending) ...[
                                _AuthModeToggle(
                                  mode: _mode,
                                  onChanged: _setMode,
                                ),
                                const SizedBox(height: 22),
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
                                    helperText: isSignup
                                        ? 'Use at least 8 characters.'
                                        : null,
                                    prefixIcon: const Icon(Icons.lock_outline),
                                    suffixIcon: IconButton(
                                      onPressed: () => setState(
                                        () => _obscurePassword =
                                            !_obscurePassword,
                                      ),
                                      icon: Icon(
                                        _obscurePassword
                                            ? Icons.visibility_outlined
                                            : Icons.visibility_off_outlined,
                                      ),
                                    ),
                                  ),
                                ),
                                if (!isSignup) ...[
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton(
                                      onPressed: _loading
                                          ? null
                                          : _openPasswordReset,
                                      child: const Text('Forgot password?'),
                                    ),
                                  ),
                                ],
                                if (isSignup) ...[
                                  const SizedBox(height: 14),
                                  TextField(
                                    controller: _confirmPasswordController,
                                    obscureText: _obscurePassword,
                                    autofillHints: const [
                                      AutofillHints.newPassword,
                                    ],
                                    decoration: const InputDecoration(
                                      labelText: 'Confirm password',
                                      prefixIcon: Icon(
                                        Icons.lock_reset_rounded,
                                      ),
                                    ),
                                  ),
                                ],
                              ] else ...[
                                TextField(
                                  controller: _verificationCodeController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'Verification code',
                                    prefixIcon: Icon(
                                      Icons.mark_email_read_outlined,
                                    ),
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
                                  backgroundColor: const Color(0xFF073F43),
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size.fromHeight(56),
                                  textStyle: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
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
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (!_verificationPending) const _AuthPerksCard(),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AuthBrandHeader extends StatelessWidget {
  const _AuthBrandHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(32),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14073F43),
            blurRadius: 28,
            offset: Offset(0, 18),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _SurfLogoBadge(),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Tydes',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.black,
                        fontSize: 24,
                        letterSpacing: -0.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            title,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              color: const Color(0xFF142127),
              fontSize: 32,
              letterSpacing: -0.8,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: const Color(0xFF4F5E62),
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _SurfLogoBadge extends StatelessWidget {
  const _SurfLogoBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 82,
      height: 58,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE8E5DA)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 14,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: const Center(
        child: SizedBox(
          width: 60,
          height: 34,
          child: CustomPaint(painter: _SurfLogoPainter()),
        ),
      ),
    );
  }
}

class _SurfLogoPainter extends CustomPainter {
  const _SurfLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final wavePaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final dotPaint = Paint()..color = Colors.black;

    canvas.drawCircle(
      Offset(size.width * 0.08, size.height * 0.55),
      2.4,
      dotPaint,
    );

    final path = Path()
      ..moveTo(size.width * 0.2, size.height * 0.55)
      ..cubicTo(
        size.width * 0.38,
        size.height * 0.46,
        size.width * 0.46,
        size.height * 0.1,
        size.width * 0.67,
        size.height * 0.14,
      )
      ..cubicTo(
        size.width * 0.84,
        size.height * 0.17,
        size.width * 0.86,
        size.height * 0.42,
        size.width * 0.8,
        size.height * 0.48,
      )
      ..cubicTo(
        size.width * 0.75,
        size.height * 0.32,
        size.width * 0.58,
        size.height * 0.34,
        size.width * 0.56,
        size.height * 0.53,
      )
      ..cubicTo(
        size.width * 0.54,
        size.height * 0.73,
        size.width * 0.75,
        size.height * 0.74,
        size.width * 0.9,
        size.height * 0.63,
      )
      ..cubicTo(
        size.width * 0.98,
        size.height * 0.58,
        size.width * 1.05,
        size.height * 0.62,
        size.width * 1.12,
        size.height * 0.73,
      );

    canvas.drawPath(path, wavePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _AuthFormCard extends StatelessWidget {
  const _AuthFormCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final baseTheme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: const Color(0xFFEDEAE1)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F073F43),
            blurRadius: 24,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: Theme(
        data: baseTheme.copyWith(
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFFF8F7F2),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: const BorderSide(color: Color(0xFFECE8DD)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: const BorderSide(
                color: Color(0xFF079CA3),
                width: 1.4,
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
          ),
        ),
        child: child,
      ),
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
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: const Color(0xFFF1EFE7),
        borderRadius: BorderRadius.circular(22),
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
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          boxShadow: selected
              ? const [
                  BoxShadow(
                    color: Color(0x12073F43),
                    blurRadius: 12,
                    offset: Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: selected
                  ? const Color(0xFF079CA3)
                  : const Color(0xFF738185),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: selected
                    ? const Color(0xFF073F43)
                    : const Color(0xFF738185),
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AuthPerksCard extends StatelessWidget {
  const _AuthPerksCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xEFFFFFFF),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFFEDEAE1)),
      ),
      child: const Column(
        children: [
          _AuthPerk(
            icon: Icons.waves_rounded,
            text: 'Save your favorite surf spots across devices.',
          ),
          SizedBox(height: 12),
          _AuthPerk(
            icon: Icons.notifications_active_outlined,
            text: 'Create wave, wind, and tide alerts for unlocked breaks.',
          ),
          SizedBox(height: 12),
          _AuthPerk(
            icon: Icons.travel_explore_rounded,
            text: 'Keep trip planning, maps, and live forecast tools together.',
          ),
        ],
      ),
    );
  }
}

class _AuthPerk extends StatelessWidget {
  const _AuthPerk({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: const Color(0xFFE3F5F2),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(icon, color: const Color(0xFF079CA3), size: 19),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              text,
              style: const TextStyle(
                color: Color(0xFF4F5E62),
                fontWeight: FontWeight.w700,
                height: 1.25,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

bool _needsProfileSetup(UserProfile profile) {
  return profile.displayName.trim().isEmpty ||
      profile.handle.trim().isEmpty ||
      profile.surfSkill.trim().isEmpty;
}

class _ProfileSetupSheet extends ConsumerStatefulWidget {
  const _ProfileSetupSheet({required this.profile});

  final UserProfile profile;

  @override
  ConsumerState<_ProfileSetupSheet> createState() => _ProfileSetupSheetState();
}

class _ProfileSetupSheetState extends ConsumerState<_ProfileSetupSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _handleController;
  late final TextEditingController _locationController;
  late final TextEditingController _bioController;
  String? _skill;
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
      _showError(
        '@tag can only use lowercase letters, numbers, and underscores.',
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await ref
          .read(surfRepositoryProvider)
          .updateProfile(
            displayName: displayName,
            handle: handle,
            bio: bio,
            surfSkill: _skill!,
            homeRegion: location,
            avatarUrl: widget.profile.avatarUrl,
          );
      ref.invalidate(authStateProvider);
      ref.invalidate(meProvider);
      ref.invalidate(dashboardProvider);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      _showError(error.toString().replaceFirst('Bad state: ', ''));
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
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return PopScope(
      canPop: false,
      child: SafeArea(
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
                      color: const Color(0xFFD5D0C6),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Set up your profile',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                const Text(
                  'Choose your name, @tag, and surf level. You can add location and bio now or later.',
                  style: TextStyle(color: Color(0xFF5D686C), height: 1.35),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'Your display name',
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _handleController,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '@tag',
                    hintText: 'yourtag',
                    prefixText: '@',
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
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Surf level',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  emptySelectionAllowed: true,
                  segments: const [
                    ButtonSegment<String>(
                      value: 'beginner',
                      label: Text('Beginner'),
                    ),
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
                          () => _skill = selection.isEmpty
                              ? null
                              : selection.first,
                        ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _bioController,
                  maxLines: 4,
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
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Saving...' : 'Finish profile'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
                    color: const Color(0xFFD5D0C6),
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
              const Text(
                'We’ll email you a code, then you can choose a new password.',
                style: TextStyle(color: Color(0xFF5D686C), height: 1.35),
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
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFE7F6F3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(text),
    );
  }
}

class _AuthError extends StatelessWidget {
  const _AuthError({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFE8E1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }
}

String _friendlyAuthError(Object error) {
  return error.toString().replaceFirst('Bad state: ', '');
}
