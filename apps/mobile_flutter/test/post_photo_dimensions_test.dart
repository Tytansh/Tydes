import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/features/social/post_photo_dimensions.dart';

void main() {
  for (final orientation in <int?>[null, 1, 2, 3, 4, 5, 6, 7, 8]) {
    test('photo dimensions follow camera orientation $orientation', () {
      final dimensions = postPhotoDisplayDimensions(
        width: 4000,
        height: 3000,
        exifOrientation: orientation,
      );
      final swapsAxes = orientation != null && orientation >= 5;
      expect(dimensions.width, swapsAxes ? 3000 : 4000);
      expect(dimensions.height, swapsAxes ? 4000 : 3000);
    });
  }

  for (var orientation = 1; orientation <= 8; orientation++) {
    test('JPEG decodeImage bakes orientation $orientation only once', () {
      final original = image.Image(width: 80, height: 45);
      original.exif.imageIfd.orientation = orientation;
      // Use the exact decoder entry point used by the composer, not a mocked
      // width/height. The installed JPEG decoder bakes and clears EXIF itself.
      final decoded = image.decodeImage(image.encodeJpg(original))!;
      final swapsAxes = orientation >= 5;
      final expected = swapsAxes
          ? (width: 45, height: 80)
          : (width: 80, height: 45);
      expect(decoded.width, expected.width);
      expect(decoded.height, expected.height);
      expect(decoded.exif.imageIfd.orientation, isNull);
      final dimensions = postPhotoDisplayDimensions(
        width: decoded.width,
        height: decoded.height,
        exifOrientation: decoded.exif.imageIfd.orientation,
      );
      // copyResize must retain the already-oriented shape, not swap it again.
      final thumbnail = image.copyResize(decoded, width: 700);
      expect(dimensions, expected);
      expect(
        thumbnail.height,
        (700 * dimensions.height / dimensions.width).round(),
      );
    });
  }

  test('upload dimensions retain all media identity and request fields', () {
    final uploaded = SocialMediaAttachmentModel.fromJson({
      'id': 'photo-reservation',
      'media_type': 'photo',
      'url': 'https://photos.example.invalid/photo.jpg',
      'thumbnail_url': 'https://photos.example.invalid/thumbnail.jpg',
      'fallback_url': null,
      'alt_text': 'A reef break',
    });
    final attachment = postPhotoWithDimensions(
      uploaded,
      width: 1600,
      height: 900,
    );
    expect(attachment.id, uploaded.id);
    expect(attachment.mediaType, 'photo');
    expect(attachment.url, uploaded.url);
    expect(attachment.thumbnailUrl, uploaded.thumbnailUrl);
    expect(attachment.fallbackUrl, uploaded.fallbackUrl);
    expect(attachment.altText, uploaded.altText);
    expect(uploaded.width, isNull);
    expect(uploaded.height, isNull);
    // createSocialPost serializes this attachment directly. Its JSON round-trip
    // must keep the shape for every other account opening this post later.
    final persisted = SocialMediaAttachmentModel.fromJson(
      jsonDecode(jsonEncode(attachment.toJson())) as Map<String, dynamic>,
    );
    expect(persisted.width, 1600);
    expect(persisted.height, 900);
    expect(persisted.toJson(), attachment.toJson());
  });

  test('upright portrait and square photos keep their original dimensions', () {
    expect(postPhotoDisplayDimensions(width: 900, height: 1600), (
      width: 900,
      height: 1600,
    ));
    expect(postPhotoDisplayDimensions(width: 1080, height: 1080), (
      width: 1080,
      height: 1080,
    ));
  });
}
