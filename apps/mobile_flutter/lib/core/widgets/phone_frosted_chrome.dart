import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A small, clipped glass surface. Its children stay fully opaque; only the
/// backdrop tint is translucent. Accessibility preferences get a solid surface.
class PhoneFrostedChrome extends StatelessWidget {
  const PhoneFrostedChrome({
    super.key,
    required this.child,
    this.topBorder = false,
    this.bottomBorder = false,
  });

  final Widget child;
  final bool topBorder;
  final bool bottomBorder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final solid =
        media.highContrast ||
        media.disableAnimations ||
        media.accessibleNavigation;
    final dark = scheme.brightness == Brightness.dark;
    final edge = BorderSide(
      color: scheme.onSurface.withValues(alpha: dark ? 0.10 : 0.08),
      width: 0.5,
    );
    final tinted = DecoratedBox(
      key: const ValueKey('phone-frosted-chrome-tint'),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(
          alpha: solid ? 1 : (dark ? 0.86 : 0.88),
        ),
        border: Border(
          top: topBorder ? edge : BorderSide.none,
          bottom: bottomBorder ? edge : BorderSide.none,
        ),
      ),
      child: child,
    );
    return ClipRect(
      child: solid
          ? tinted
          : BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: tinted,
            ),
    );
  }
}

/// Geometry of the feed's actual viewport and its translucent overlays. Media
/// may paint behind these bars, but covered pixels must not trigger autoplay.
class FeedChromeInsets extends InheritedWidget {
  const FeedChromeInsets({
    super.key,
    required this.insets,
    required this.viewportHeight,
    required super.child,
  });

  final EdgeInsets insets;
  final double viewportHeight;

  static FeedChromeInsets? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FeedChromeInsets>();

  @override
  bool updateShouldNotify(FeedChromeInsets oldWidget) =>
      insets != oldWidget.insets || viewportHeight != oldWidget.viewportHeight;
}
