import '../../core/network/api_models.dart';

/// Display shape of an original photo, including camera EXIF rotation.
/// The composer reads this while it already has the thumbnail decode in memory.
/// Decoders that already bake orientation clear its tag; their dimensions pass
/// through unchanged. Remaining rotation tags match copyResize's EXIF handling.
({int width, int height}) postPhotoDisplayDimensions({
  required int width,
  required int height,
  int? exifOrientation,
}) {
  final swapsAxes =
      exifOrientation != null && exifOrientation >= 5 && exifOrientation <= 8;
  return swapsAxes
      ? (width: height, height: width)
      : (width: width, height: height);
}

/// Preserve the upload's identity/URLs while providing initial feed layout hints.
SocialMediaAttachmentModel postPhotoWithDimensions(
  SocialMediaAttachmentModel uploaded, {
  required int width,
  required int height,
}) => SocialMediaAttachmentModel.fromJson({
  ...uploaded.toJson(),
  'width': width,
  'height': height,
});
