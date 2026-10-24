import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';

void main() {
  test('web carousel uses arrows instead of mouse dragging at every width', () {
    expect(
      socialPostMediaCarouselPhysics(isWeb: true),
      isA<NeverScrollableScrollPhysics>(),
    );
    expect(
      socialPostMediaCarouselShowsArrows(isWeb: true, mediaCount: 3),
      isTrue,
    );
  });

  test('native carousel keeps touch swiping', () {
    expect(
      socialPostMediaCarouselPhysics(isWeb: false),
      isA<PageScrollPhysics>(),
    );
    expect(
      socialPostMediaCarouselShowsArrows(isWeb: false, mediaCount: 3),
      isFalse,
    );
  });

  test('web carousel hides arrows for a single media item', () {
    expect(
      socialPostMediaCarouselShowsArrows(isWeb: true, mediaCount: 1),
      isFalse,
    );
  });
}
