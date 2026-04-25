import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as image_tools;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../spots/spot_picker.dart';

final travelFeedPostsProvider = FutureProvider((ref) {
  ref.watch(socialRefreshKeyProvider);
  return ref.watch(surfRepositoryProvider).fetchSocialPosts();
});
final travelFeedSpotsProvider = FutureProvider(
  (ref) => ref.watch(surfRepositoryProvider).fetchSpots(),
);

class TravelFeedSection extends ConsumerWidget {
  const TravelFeedSection({
    super.key,
    this.compact = false,
    this.showHeader = true,
  });

  final bool compact;
  final bool showHeader;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final posts = ref.watch(travelFeedPostsProvider);
    final spots = ref.watch(travelFeedSpotsProvider);
    final spotItems = spots.valueOrNull ?? const <SpotModel>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeader) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  'Travel feed',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              FilledButton.icon(
                onPressed: () => showCreatePostSheet(context, spotItems),
                icon: const Icon(Icons.add),
                label: const Text('Post'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Share clips, photos, plans, and surf travel updates.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 14),
        ],
        posts.when(
          data: (items) {
            if (items.isEmpty) return const _EmptyFeedCard();
            final shown = compact ? items.take(4).toList() : items;
            return Column(
              children: shown
                  .map(
                    (post) => Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: _PostCard(post: post, spots: spotItems),
                    ),
                  )
                  .toList(),
            );
          },
          loading: () => const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          ),
          error: (error, _) => Text('Could not load posts: $error'),
        ),
      ],
    );
  }
}

Future<void> showCreatePostSheet(BuildContext context, List<SpotModel> spots) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _CreatePostSheet(spots: spots),
  );
}

class _EmptyFeedCard extends StatelessWidget {
  const _EmptyFeedCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            const Icon(Icons.forum_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'No posts yet. Start the feed with a surf photo or trip note.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PostCard extends StatelessWidget {
  const _PostCard({required this.post, required this.spots});

  final SocialPostModel post;
  final List<SpotModel> spots;

  @override
  Widget build(BuildContext context) {
    final spot = _spotForId(spots, post.spotId);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(child: Text(post.authorName.characters.first)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        post.authorName,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Text('${_labelForVisibility(post.visibility)} post'),
                    ],
                  ),
                ),
                if (spot != null)
                  ActionChip(
                    avatar: const Icon(Icons.place_outlined, size: 16),
                    label: Text(spot.name),
                    onPressed: () => context.push('/spot/${spot.id}'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (post.media.isNotEmpty) ...[
              _PostMediaGrid(media: post.media),
              const SizedBox(height: 12),
            ],
            if (post.body.isNotEmpty)
              Text(post.body, style: Theme.of(context).textTheme.bodyLarge),
          ],
        ),
      ),
    );
  }
}

class _PostMediaGrid extends StatelessWidget {
  const _PostMediaGrid({required this.media});

  final List<SocialMediaAttachmentModel> media;

  @override
  Widget build(BuildContext context) {
    final videos = media
        .where((item) => item.mediaType == 'video')
        .take(1)
        .toList();
    if (videos.isNotEmpty) return _PostVideoPlayer(url: videos.first.url);

    final photos = media
        .where((item) => item.mediaType == 'photo')
        .take(3)
        .toList();
    if (photos.isEmpty) return const SizedBox.shrink();

    if (photos.length == 1) {
      return AspectRatio(
        aspectRatio: 4 / 3,
        child: _PostPhoto(url: photos.first.url),
      );
    }

    return SizedBox(
      height: 210,
      child: Row(
        children: [
          Expanded(child: _PostPhoto(url: photos.first.url)),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              children: [
                Expanded(child: _PostPhoto(url: photos[1].url)),
                if (photos.length > 2) ...[
                  const SizedBox(height: 6),
                  Expanded(child: _PostPhoto(url: photos[2].url)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PostVideoPlayer extends StatefulWidget {
  const _PostVideoPlayer({required this.url});

  final String url;

  @override
  State<_PostVideoPlayer> createState() => _PostVideoPlayerState();
}

class _PostVideoPlayerState extends State<_PostVideoPlayer> {
  late final VideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (mounted) setState(() {});
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _controller.value.isInitialized;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: AspectRatio(
        aspectRatio: ready ? _controller.value.aspectRatio : 16 / 9,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: ready
                  ? VideoPlayer(_controller)
                  : Container(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                    ),
            ),
            Material(
              color: Colors.black.withValues(alpha: 0.35),
              shape: const CircleBorder(),
              child: IconButton(
                color: Colors.white,
                iconSize: 34,
                onPressed: ready
                    ? () {
                        setState(() {
                          _controller.value.isPlaying
                              ? _controller.pause()
                              : _controller.play();
                        });
                      }
                    : null,
                icon: Icon(
                  _controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PostPhoto extends StatelessWidget {
  const _PostPhoto({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Image.network(
        url,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          alignment: Alignment.center,
          child: const Icon(Icons.image_not_supported_outlined),
        ),
      ),
    );
  }
}

class _CreatePostSheet extends ConsumerStatefulWidget {
  const _CreatePostSheet({required this.spots});

  final List<SpotModel> spots;

  @override
  ConsumerState<_CreatePostSheet> createState() => _CreatePostSheetState();
}

class _CreatePostSheetState extends ConsumerState<_CreatePostSheet> {
  final _bodyController = TextEditingController();
  final _imagePicker = ImagePicker();
  final List<_PostPhotoDraft> _photos = [];
  XFile? _video;
  String _visibility = 'public';
  String? _spotId;
  bool _submitting = false;

  @override
  void dispose() {
    _bodyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final favoriteSpotIds = ref.watch(favoriteSpotIdsProvider);

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Create post',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 14),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'public', label: Text('Public')),
                ButtonSegment(value: 'friends', label: Text('Friends')),
              ],
              selected: {_visibility},
              onSelectionChanged: (selection) {
                setState(() => _visibility = selection.first);
              },
            ),
            const SizedBox(height: 14),
            if (widget.spots.isNotEmpty)
              SpotPickerField(
                spots: widget.spots,
                favoriteSpotIds: favoriteSpotIds,
                selectedSpotId: _spotId,
                labelText: 'Spot optional',
                includeNoSpecific: true,
                onChanged: (value) => setState(() => _spotId = value),
              ),
            const SizedBox(height: 14),
            TextField(
              controller: _bodyController,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'What’s happening?',
                hintText: 'Share a session clip, a plan, or a travel update...',
              ),
            ),
            const SizedBox(height: 14),
            _PhotoPickerRow(
              photos: _photos,
              video: _video,
              onAdd: _pickPhotos,
              onAddVideo: _pickVideo,
              onRemove: (photo) => setState(() => _photos.remove(photo)),
              onRemoveVideo: () => setState(() => _video = null),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _submitting ? null : _submitPost,
              child: Text(_submitting ? 'Posting...' : 'Post'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickPhotos() async {
    if (_video != null) return;
    final remaining = 3 - _photos.length;
    if (remaining <= 0) return;

    final picked = await _imagePicker.pickMultiImage(
      maxWidth: 1800,
      imageQuality: 78,
      limit: remaining,
      requestFullMetadata: false,
    );
    if (picked.isEmpty) return;

    final drafts = <_PostPhotoDraft>[];
    for (final photo in picked.take(remaining)) {
      drafts.add(
        _PostPhotoDraft(
          fullImage: photo,
          thumbnail: await _createThumbnail(photo),
        ),
      );
    }
    if (!mounted) return;
    setState(() => _photos.addAll(drafts));
  }

  Future<void> _pickVideo() async {
    if (_photos.isNotEmpty || _video != null) return;

    final picked = await _imagePicker.pickVideo(
      source: ImageSource.gallery,
      maxDuration: const Duration(seconds: 30),
    );
    if (picked == null || !mounted) return;
    setState(() => _video = picked);
  }

  Future<XFile> _createThumbnail(XFile source) async {
    final bytes = await source.readAsBytes();
    final decoded = image_tools.decodeImage(bytes);
    if (decoded == null) return source;

    final resized = image_tools.copyResize(decoded, width: 700);
    final encoded = image_tools.encodeJpg(resized, quality: 68);
    final tempDir = await getTemporaryDirectory();
    final path =
        '${tempDir.path}/post_thumb_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final file = await File(path).writeAsBytes(encoded, flush: true);
    return XFile(
      file.path,
      name: file.uri.pathSegments.last,
      mimeType: 'image/jpeg',
    );
  }

  Future<void> _submitPost() async {
    final body = _bodyController.text.trim();
    if (body.isEmpty && _photos.isEmpty && _video == null) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _submitting = true);

    try {
      final repository = ref.read(surfRepositoryProvider);
      final media = <SocialMediaAttachmentModel>[];
      for (final photo in _photos) {
        media.add(
          await repository.uploadPostPhoto(
            image: photo.fullImage,
            thumbnail: photo.thumbnail,
          ),
        );
      }
      final video = _video;
      if (video != null) {
        media.add(await repository.uploadPostVideo(video: video));
      }

      await repository.createSocialPost(
        body: body,
        spotId: _spotId,
        visibility: _visibility,
        media: media,
      );
      ref.read(socialRefreshKeyProvider.notifier).state++;
      if (!mounted) return;
      navigator.pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _submitting = false);
      messenger.showSnackBar(
        SnackBar(content: Text(_uploadErrorMessage(error))),
      );
    }
  }
}

class _PostPhotoDraft {
  const _PostPhotoDraft({required this.fullImage, required this.thumbnail});

  final XFile fullImage;
  final XFile thumbnail;
}

class _PhotoPickerRow extends StatelessWidget {
  const _PhotoPickerRow({
    required this.photos,
    required this.video,
    required this.onAdd,
    required this.onAddVideo,
    required this.onRemove,
    required this.onRemoveVideo,
  });

  final List<_PostPhotoDraft> photos;
  final XFile? video;
  final VoidCallback onAdd;
  final VoidCallback onAddVideo;
  final ValueChanged<_PostPhotoDraft> onRemove;
  final VoidCallback onRemoveVideo;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final photo in photos)
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.file(
                  File(photo.thumbnail.path),
                  width: 88,
                  height: 88,
                  fit: BoxFit.cover,
                ),
              ),
              Positioned(
                right: 4,
                top: 4,
                child: InkWell(
                  onTap: () => onRemove(photo),
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 14,
                    ),
                  ),
                ),
              ),
            ],
          ),
        if (video != null)
          InputChip(
            avatar: const Icon(Icons.play_circle_outline),
            label: Text(_videoFileName(video!)),
            onDeleted: onRemoveVideo,
          ),
        if (photos.length < 3 && video == null)
          OutlinedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text('Add photos ${photos.length}/3'),
          ),
        if (photos.isEmpty && video == null)
          OutlinedButton.icon(
            onPressed: onAddVideo,
            icon: const Icon(Icons.video_library_outlined),
            label: const Text('Add video 0/1'),
          ),
      ],
    );
  }
}

String _labelForVisibility(String visibility) {
  return visibility == 'friends' ? 'Friends' : 'Public';
}

String _uploadErrorMessage(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map<String, dynamic> && data['detail'] is String) {
      return data['detail'] as String;
    }
  }
  return 'Upload failed. Try again.';
}

String _videoFileName(XFile video) {
  final name = video.name.trim();
  if (name.isNotEmpty) return name;
  return File(video.path).uri.pathSegments.last;
}

SpotModel? _spotForId(List<SpotModel> spots, String? spotId) {
  if (spotId == null) return null;
  for (final spot in spots) {
    if (spot.id == spotId) return spot;
  }
  return null;
}
