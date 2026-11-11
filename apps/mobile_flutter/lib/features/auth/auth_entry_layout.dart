import 'package:flutter/material.dart';

/// Presentation only: authentication and return routing stay in AuthPage.
class AuthEntryLayout extends StatelessWidget {
  const AuthEntryLayout({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).brightness == Brightness.dark
        ? Theme.of(context).scaffoldBackgroundColor
        : const Color(0xFFF9FAF7),
    child: SafeArea(
      child: LayoutBuilder(
        builder: (context, size) {
          final desktop = size.maxWidth >= 980;
          final form = ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: _AuthFormStyle(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: 'Sora',
                      fontSize: desktop ? 32 : 28,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                      letterSpacing: -1.2,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Theme.of(context).colorScheme.onSurface
                          : const Color(0xFF163340),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : const Color(0xFF5A6F77),
                      fontSize: 15,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 26),
                  child,
                ],
              ),
            ),
          );
          if (desktop) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 6,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 0, 16),
                    child: const _AuthOceanPanel(),
                  ),
                ),
                Expanded(
                  flex: 5,
                  child: SingleChildScrollView(
                    key: const ValueKey('auth-form-scroll'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 42,
                      vertical: 40,
                    ),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: (size.maxHeight - 80)
                            .clamp(0, double.infinity)
                            .toDouble(),
                      ),
                      child: Center(child: form),
                    ),
                  ),
                ),
              ],
            );
          }
          return SingleChildScrollView(
            key: const ValueKey('auth-form-scroll'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(10, 10, 10, 0),
                  child: SizedBox(
                    height: 230,
                    child: _AuthOceanPanel(compact: true),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 30, 24, 26),
                  child: Center(child: form),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

class _AuthOceanPanel extends StatelessWidget {
  const _AuthOceanPanel({this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(compact ? 22 : 28),
    child: Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: const Color(0xFF12495A),
          child: Image.asset(
            compact
                ? 'assets/images/auth-surf-ocean-mobile.webp'
                : 'assets/images/auth-surf-ocean.webp',
            key: const ValueKey('auth-surf-photo'),
            fit: BoxFit.cover,
            alignment: compact
                ? const Alignment(-.2, -.2)
                : const Alignment(-.2, 0),
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) =>
                const ColoredBox(color: Color(0xFF12495A)),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x48102331), Color(0x05102331), Color(0xCA102B35)],
              stops: [0, .36, 1],
            ),
          ),
        ),
        Positioned(
          top: compact ? 20 : 34,
          left: compact ? 22 : 36,
          child: Row(
            key: const ValueKey('auth-brand'),
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(compact ? 12 : 16),
                child: Image.asset(
                  'assets/branding/tydes-wave-blue-256.png',
                  width: compact ? 40 : 54,
                  height: compact ? 40 : 54,
                  excludeFromSemantics: true,
                ),
              ),
              SizedBox(width: compact ? 11 : 14),
              Text(
                'Tydes',
                style: TextStyle(
                  fontFamily: 'Sora',
                  color: Colors.white,
                  fontSize: compact ? 23 : 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1,
                ),
              ),
            ],
          ),
        ),
        Positioned(
          left: compact ? 22 : 40,
          right: compact ? 22 : 40,
          bottom: compact ? 26 : 58,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!compact) ...[
                const Text(
                  'GOOD WAVES. GOOD COMPANY.',
                  style: TextStyle(
                    color: Color(0xFFD3F2EB),
                    fontSize: 11,
                    letterSpacing: 2.4,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 20),
              ],
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  'Where We Surfing',
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: 'Pacifico',
                    color: Colors.white,
                    fontSize: compact ? 32 : 54,
                    height: 1.25,
                  ),
                ),
              ),
              if (!compact) ...[
                const SizedBox(height: 22),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: const Text(
                    'Check the forecast, pick a spot, and see who’s heading out.',
                    style: TextStyle(
                      color: Color(0xE5FFFFFF),
                      fontSize: 17,
                      height: 1.6,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class _AuthFormStyle extends StatelessWidget {
  const _AuthFormStyle({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final borderColor = dark
        ? theme.colorScheme.outlineVariant
        : const Color(0xFFDDE5E5);
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: borderColor),
    );
    return Theme(
      data: theme.copyWith(
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: dark
                ? theme.colorScheme.primary
                : const Color(0xFF087B88),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: dark
              ? theme.colorScheme.surfaceContainerHigh
              : const Color(0xFFF4F7F6),
          border: border,
          enabledBorder: border,
          focusedBorder: border.copyWith(
            borderSide: BorderSide(
              color: dark ? theme.colorScheme.primary : const Color(0xFF168F99),
              width: 1.5,
            ),
          ),
          labelStyle: TextStyle(
            color: dark
                ? theme.colorScheme.onSurfaceVariant
                : const Color(0xFF5A6F77),
            fontSize: 14,
          ),
          prefixIconColor: dark
              ? theme.colorScheme.onSurfaceVariant
              : const Color(0xFF6A7D83),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 17,
          ),
        ),
      ),
      child: child,
    );
  }
}
