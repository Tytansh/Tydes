import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' deferred as image_tools;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import 'post_composer_shared.dart';

/// The complete composer is loaded only when a person opens Post on the web.
/// Providers are inherited from the route; the code loader never owns drafts.
Widget buildPostComposer({required List<SpotModel> spots}) =>
    _CreatePostPage(spots: spots);

final composerDraftsProvider = StateProvider<List<_ComposerPostDraft>>(
  (ref) => const [],
);

class _CreatePostPage extends ConsumerStatefulWidget {
  const _CreatePostPage({required this.spots});

  final List<SpotModel> spots;

  @override
  ConsumerState<_CreatePostPage> createState() => _CreatePostPageState();
}

class _CreatePostPageState extends ConsumerState<_CreatePostPage> {
  final _bodyController = TextEditingController();
  final _imagePicker = ImagePicker();
  final List<_PostMediaDraft> _media = [];
  String? _activeDraftId;
  String _postType = 'general';
  String _visibility = 'public';
  String? _spotId;
  DateTime? _inviteDate;
  DateTime? _inviteEndDate;
  bool _submitting = false;
  bool _discardDraftOnDispose = false;
  String? _submitStatus;

  @override
  void initState() {
    super.initState();
    _bodyController.addListener(_syncCurrentDraft);
  }

  @override
  void dispose() {
    _bodyController.removeListener(_syncCurrentDraft);
    // Edits already sync the draft; WidgetRef is unavailable during unmount.
    _bodyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final favoriteSpotIds = ref.watch(favoriteSpotIdsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isSurfInvite = _postType == 'surf_plan';
    final selectedSpot = postSpotForId(widget.spots, _spotId);
    final canPost =
        !_submitting &&
        (!isSurfInvite || (_spotId != null && _inviteDate != null)) &&
        (_bodyController.text.trim().isNotEmpty ||
            _media.isNotEmpty ||
            (isSurfInvite && _spotId != null));
    const captionHint = 'Add a caption...';

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          isSurfInvite ? 'New event' : 'New post',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _openDraftsSheet,
                        child: const Text('Drafts'),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _ComposerTypeSwitch(
                    value: _postType,
                    onChanged: _setPostType,
                  ),
                  const SizedBox(height: 14),
                  _ComposerMediaStage(
                    media: _media,
                    onAddMedia: _pickMedia,
                    onRemoveMedia: (media) {
                      setState(() => _media.remove(media));
                      _syncCurrentDraft();
                    },
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _ComposerMetaChip(
                        icon: _visibility == 'public'
                            ? Icons.public_rounded
                            : Icons.group_outlined,
                        label: _visibility == 'public' ? 'Public' : 'Followers',
                        onTap: () {
                          setState(() {
                            _visibility = _visibility == 'public'
                                ? 'followers'
                                : 'public';
                          });
                          _syncCurrentDraft();
                        },
                      ),
                      if (widget.spots.isNotEmpty)
                        _ComposerMetaChip(
                          icon: Icons.location_on_outlined,
                          label:
                              selectedSpot?.name ??
                              (isSurfInvite ? 'Choose event spot' : 'Tag spot'),
                          selected: selectedSpot != null,
                          onTap: () => _openSpotTagSheet(favoriteSpotIds),
                        ),
                    ],
                  ),
                  if (isSurfInvite) ...[
                    const SizedBox(height: 10),
                    Text(
                      _visibility == 'public'
                          ? 'Public event: anyone can see it on the guest map.'
                          : 'Followers-only event: hidden from the guest map.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    if (selectedSpot == null) ...[
                      Text(
                        'Choose a spot to show your event on the map.',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (_inviteDate == null) ...[
                      Text(
                        'Choose an event date before posting.',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                    ],
                    _InviteDateChips(
                      selectedStartDate: _inviteDate,
                      selectedEndDate: _inviteEndDate,
                      onChanged: (value) {
                        setState(() {
                          _inviteDate = value?.start;
                          _inviteEndDate =
                              value == null ||
                                  samePostDay(value.start, value.end)
                              ? null
                              : value.end;
                        });
                        _syncCurrentDraft();
                      },
                    ),
                  ],
                  const SizedBox(height: 14),
                  Container(
                    decoration: BoxDecoration(
                      color: theme.cardColor,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: scheme.outlineVariant.withValues(alpha: 0.45),
                      ),
                    ),
                    child: TextField(
                      controller: _bodyController,
                      minLines: 4,
                      maxLines: 8,
                      onChanged: _handleBodyChanged,
                      decoration: InputDecoration(
                        hintText: captionHint,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.all(18),
                      ),
                      style: theme.textTheme.bodyLarge?.copyWith(height: 1.25),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: _PostCaptionLimitNotice(text: _bodyController.text),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: canPost ? _submitPost : null,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: _submitting
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: scheme.onPrimary,
                              ),
                            )
                          : Text(isSurfInvite ? 'Post event' : 'Post'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_submitting)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: LinearProgressIndicator(
                            color: scheme.primary,
                            backgroundColor: scheme.primary.withValues(
                              alpha: 0.12,
                            ),
                            minHeight: 4,
                          ),
                        ),
                        if (_submitStatus != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            _submitStatus!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _setPostType(String nextType) {
    setState(() {
      _postType = nextType;
      // Keep the audience the person selected instead of silently making
      // every new event followers-only (and invisible to guest discovery).
      if (nextType != 'surf_plan') {
        _inviteEndDate = null;
      }
    });
    _syncCurrentDraft();
  }

  void _handleBodyChanged(String value) {
    final limited = _limitPostCaption(value);
    if (limited != value) {
      _bodyController.value = TextEditingValue(
        text: limited,
        selection: _postCaptionSelection(limited),
      );
    }
    setState(() {});
  }

  Future<void> _openSpotTagSheet(Set<String> favoriteSpotIds) async {
    final value = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _SpotTagSheet(
        spots: widget.spots,
        favoriteSpotIds: favoriteSpotIds,
        selectedSpotId: _spotId,
      ),
    );
    if (!mounted || value == null) return;
    setState(() => _spotId = value == _noSpotValue ? null : value);
    _syncCurrentDraft();
  }

  Future<void> _openDraftsSheet() async {
    final messenger = ScaffoldMessenger.of(context);
    _syncCurrentDraft();
    final draft = await showModalBottomSheet<_ComposerPostDraft>(
      context: context,
      showDragHandle: true,
      builder: (context) => const _ComposerDraftsSheet(),
    );
    if (!mounted || draft == null) return;
    ref.read(composerDraftsProvider.notifier).state = [
      for (final item in ref.read(composerDraftsProvider))
        if (item.id != draft.id) item,
    ];
    setState(() {
      _activeDraftId = draft.id;
      _bodyController.text = draft.body;
      _postType = draft.postType;
      _visibility = draft.visibility;
      _spotId = draft.spotId;
      _inviteDate = draft.inviteDate;
      _inviteEndDate = draft.inviteEndDate;
      _media
        ..clear()
        ..addAll(draft.media);
    });
    _syncCurrentDraft();
    messenger.showSnackBar(const SnackBar(content: Text('Draft restored.')));
  }

  void _syncCurrentDraft() {
    if (_discardDraftOnDispose) return;
    if (!_hasDraftContent) {
      _removeActiveDraft();
      return;
    }
    final draft = _ComposerPostDraft(
      id: _activeDraftId ?? 'draft_${DateTime.now().microsecondsSinceEpoch}',
      body: _bodyController.text.trim(),
      postType: _postType,
      visibility: _visibility,
      spotId: _spotId,
      inviteDate: _inviteDate,
      inviteEndDate: _inviteEndDate,
      media: List.unmodifiable(_media),
      savedAt: DateTime.now(),
    );
    final existing = ref.read(composerDraftsProvider);
    ref.read(composerDraftsProvider.notifier).state = [
      draft,
      for (final item in existing)
        if (item.id != draft.id) item,
    ].take(_maxComposerDrafts).toList();
    _activeDraftId = draft.id;
  }

  void _removeActiveDraft() {
    final draftId = _activeDraftId;
    if (draftId == null) return;
    ref.read(composerDraftsProvider.notifier).state = [
      for (final item in ref.read(composerDraftsProvider))
        if (item.id != draftId) item,
    ];
    _activeDraftId = null;
  }

  bool get _hasDraftContent {
    return _bodyController.text.trim().isNotEmpty ||
        _media.isNotEmpty ||
        _spotId != null;
  }

  Future<void> _pickMedia() async {
    final messenger = ScaffoldMessenger.of(context);
    final remainingSlots = _maxPostMediaItems - _media.length;
    if (remainingSlots <= 0) {
      messenger.showSnackBar(
        const SnackBar(content: Text('You can add up to 3 photos or videos.')),
      );
      return;
    }

    try {
      final picked = await _imagePicker.pickMultipleMedia(
        imageQuality: 78,
        limit: remainingSlots,
        requestFullMetadata: false,
      );
      if (!mounted || picked.isEmpty) return;
      await _addPickedMedia(picked, remainingSlots, messenger);
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open your photos right now.')),
      );
    }
  }

  Future<void> _addPickedMedia(
    List<XFile> picked,
    int remainingSlots,
    ScaffoldMessengerState messenger,
  ) async {
    final warnings = <String>[];
    final drafts = <_PostMediaDraft>[];
    final selected = picked.take(remainingSlots).toList();

    for (final item in selected) {
      if (_looksLikeVideo(item)) {
        final durationMilliseconds = await _pickedVideoDurationMilliseconds(
          item,
        );
        if (!mounted) return;
        if (durationMilliseconds != null &&
            durationMilliseconds > _maxPostVideoDurationMilliseconds) {
          warnings.add('Videos can be up to 30 seconds long.');
          continue;
        }
        final videoSize = await _pickedVideoSize(item);
        if (!mounted) return;
        if (videoSize != null && videoSize > _maxPostVideoBytes) {
          if (kIsWeb) {
            warnings.add(
              'Web videos need to be under ${_formatFileSize(_maxPostVideoBytes)}.',
            );
            continue;
          }
          warnings.add('Video added. TYDES will optimize it before posting.');
        }
        drafts.add(_PostMediaDraft.video(item));
        continue;
      }

      final draft = await _draftForPickedPhoto(item, warnings);
      if (!mounted) return;
      if (draft != null) drafts.add(draft);
    }

    if (drafts.isNotEmpty) {
      setState(() => _media.addAll(drafts));
      _syncCurrentDraft();
    }
    if (picked.length > remainingSlots) {
      warnings.insert(0, 'Only the first 3 media items were added.');
    }
    if (warnings.isNotEmpty && mounted) {
      messenger.showSnackBar(SnackBar(content: Text(warnings.first)));
    } else if (drafts.isEmpty && mounted) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not add that media.')),
      );
    }
  }

  Future<int?> _pickedVideoSize(XFile picked) async {
    try {
      return picked.length().timeout(const Duration(seconds: 3));
    } catch (_) {
      return null;
    }
  }

  Future<double?> _pickedVideoDurationMilliseconds(XFile picked) async {
    if (kIsWeb) return null;
    try {
      final info = await VideoCompress.getMediaInfo(picked.path);
      return info.duration;
    } catch (_) {
      return null;
    }
  }

  Future<XFile> _videoForUpload(XFile source, int index) async {
    if (kIsWeb) return source;

    final originalSize = await _pickedVideoSize(source);
    if (originalSize != null && originalSize <= _maxPostVideoBytes) {
      return source;
    }

    _setSubmitStatus(
      'Compressing video ${index + 1} of ${_media.length}${originalSize == null ? '' : ' (${_formatFileSize(originalSize)})'}...',
    );

    try {
      final compressedInfo = await VideoCompress.compressVideo(
        source.path,
        quality: VideoQuality.Res1280x720Quality,
        deleteOrigin: false,
        includeAudio: true,
        frameRate: 30,
      );
      final compressedPath = compressedInfo?.path;
      if (compressedPath == null || compressedPath.isEmpty) return source;

      final compressed = XFile(
        compressedPath,
        name: _compressedVideoName(source, compressedPath),
        mimeType: 'video/mp4',
      );
      final compressedSize = await _pickedVideoSize(compressed);
      if (compressedSize == null) return source;
      if (originalSize != null && compressedSize >= originalSize) {
        return source;
      }
      return compressed;
    } catch (_) {
      return source;
    }
  }

  String _compressedVideoName(XFile source, String compressedPath) {
    final sourceName = source.name.trim();
    if (sourceName.isEmpty) {
      return File(compressedPath).uri.pathSegments.last;
    }
    final dotIndex = sourceName.lastIndexOf('.');
    final baseName = dotIndex <= 0
        ? sourceName
        : sourceName.substring(0, dotIndex);
    return '${baseName}_compressed.mp4';
  }

  Future<XFile?> _createVideoThumbnail(XFile source) async {
    if (kIsWeb) return null;

    try {
      final thumbnailFile = await VideoCompress.getFileThumbnail(
        source.path,
        quality: 45,
        position: 0,
      );
      return XFile(
        thumbnailFile.path,
        name: 'video_thumb_${DateTime.now().microsecondsSinceEpoch}.jpg',
        mimeType: 'image/jpeg',
      );
    } catch (_) {
      return null;
    }
  }

  bool _looksLikeVideo(XFile media) {
    final mimeType = media.mimeType?.toLowerCase();
    if (mimeType != null) return mimeType.startsWith('video/');
    final path = media.path.toLowerCase();
    final name = media.name.toLowerCase();
    return path.endsWith('.mov') ||
        path.endsWith('.mp4') ||
        path.endsWith('.m4v') ||
        path.endsWith('.avi') ||
        path.endsWith('.webm') ||
        name.endsWith('.mov') ||
        name.endsWith('.mp4') ||
        name.endsWith('.m4v') ||
        name.endsWith('.avi') ||
        name.endsWith('.webm');
  }

  Future<_PostMediaDraft?> _draftForPickedPhoto(
    XFile picked,
    List<String> warnings,
  ) async {
    final mediaSize = await picked.length();

    if (mediaSize > _maxPostPhotoBytes) {
      warnings.add(
        'Photos need to be under ${_formatFileSize(_maxPostPhotoBytes)}.',
      );
      return null;
    }

    final thumbnail = await _createThumbnail(picked);
    if (thumbnail == null) {
      warnings.add('Could not add one photo. Try another image.');
      return null;
    }

    final draft = _PostPhotoDraft(fullImage: picked, thumbnail: thumbnail);
    return _PostMediaDraft.photo(draft);
  }

  Future<XFile?> _createThumbnail(XFile source) async {
    // Image codecs are needed when composing, not when opening/scrolling feed.
    await image_tools.loadLibrary();
    final bytes = await source.readAsBytes();
    final decoded = image_tools.decodeImage(bytes);
    if (decoded == null) return null;

    final resized = image_tools.copyResize(decoded, width: 700);
    final encoded = image_tools.encodeJpg(resized, quality: 68);
    final name = 'post_thumb_${DateTime.now().microsecondsSinceEpoch}.jpg';
    if (kIsWeb) {
      return XFile.fromData(encoded, name: name, mimeType: 'image/jpeg');
    }
    final tempDir = await getTemporaryDirectory();
    final path = '${tempDir.path}/$name';
    final file = await File(path).writeAsBytes(encoded, flush: true);
    return XFile(
      file.path,
      name: file.uri.pathSegments.last,
      mimeType: 'image/jpeg',
    );
  }

  Future<void> _submitPost() async {
    final body = _bodyController.text.trim();
    final isSurfInvite = _postType == 'surf_plan';
    if (isSurfInvite && (_spotId == null || _inviteDate == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Choose an event spot and date before posting.'),
        ),
      );
      return;
    }
    if (body.isEmpty && _media.isEmpty && !(isSurfInvite && _spotId != null)) {
      return;
    }
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _submitting = true;
      _submitStatus = _media.isEmpty ? 'Posting...' : 'Preparing upload...';
    });

    try {
      final repository = ref.read(surfRepositoryProvider);
      final media = <SocialMediaAttachmentModel>[];
      for (var index = 0; index < _media.length; index++) {
        final draft = _media[index];
        final photo = draft.photo;
        final video = draft.video;
        if (photo != null) {
          final photoSize = await _pickedVideoSize(photo.fullImage);
          var lastPercent = -1;
          _setSubmitStatus(
            'Uploading photo ${index + 1} of ${_media.length}${photoSize == null ? '' : ' (${_formatFileSize(photoSize)})'}...',
          );
          media.add(
            await repository.uploadPostPhoto(
              image: photo.fullImage,
              thumbnail: photo.thumbnail,
              onSendProgress: (sent, total) {
                final percent = _uploadPercent(sent, total);
                if (percent == null || percent == lastPercent) return;
                lastPercent = percent;
                _setSubmitStatus(
                  'Uploading photo ${index + 1} of ${_media.length} ($percent%)...',
                );
              },
            ),
          );
        } else if (video != null) {
          final uploadVideo = await _videoForUpload(video, index);
          final videoThumbnail = await _createVideoThumbnail(uploadVideo);
          final videoSize = await _pickedVideoSize(uploadVideo);
          if (videoSize != null && videoSize > _maxPostVideoBytes) {
            throw StateError(
              'Videos need to be under ${_formatFileSize(_maxPostVideoBytes)} for now. Try trimming this clip.',
            );
          }
          var lastPercent = -1;
          final compressedLabel = uploadVideo.path == video.path
              ? ''
              : ' compressed';
          _setSubmitStatus(
            'Uploading$compressedLabel video ${index + 1} of ${_media.length}${videoSize == null ? '' : ' (${_formatFileSize(videoSize)})'}...',
          );
          media.add(
            await repository.uploadPostVideo(
              video: uploadVideo,
              thumbnail: videoThumbnail,
              onSendProgress: (sent, total) {
                final percent = _uploadPercent(sent, total);
                if (percent == null || percent == lastPercent) return;
                lastPercent = percent;
                _setSubmitStatus(
                  'Uploading$compressedLabel video ${index + 1} of ${_media.length} ($percent%)...',
                );
              },
            ),
          );
        }
      }

      _setSubmitStatus('Posting...');
      await repository.createSocialPost(
        body: body,
        spotId: _spotId,
        postType: _postType,
        visibility: _visibility,
        media: media,
        meetupDate: isSurfInvite && _inviteDate != null
            ? _dateOnly(_inviteDate!)
            : null,
        meetupEndDate: isSurfInvite && _inviteEndDate != null
            ? _dateOnly(_inviteEndDate!)
            : null,
      );
      ref.read(socialRefreshKeyProvider.notifier).state++;
      if (!mounted) return;
      _discardDraftOnDispose = true;
      if (_activeDraftId != null) {
        ref.read(composerDraftsProvider.notifier).state = [
          for (final item in ref.read(composerDraftsProvider))
            if (item.id != _activeDraftId) item,
        ];
      }
      navigator.pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitStatus = null;
      });
      messenger.showSnackBar(
        SnackBar(content: Text(postActionErrorMessage(error))),
      );
    } finally {
      unawaited(VideoCompress.deleteAllCache());
    }
  }

  void _setSubmitStatus(String status) {
    if (!mounted) return;
    setState(() => _submitStatus = status);
  }
}

class _ComposerTypeSwitch extends StatelessWidget {
  const _ComposerTypeSwitch({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ComposerTypeOption(
              icon: Icons.chat_bubble_outline,
              label: 'Post',
              selected: value == 'general',
              onTap: () => onChanged('general'),
            ),
          ),
          Expanded(
            child: _ComposerTypeOption(
              icon: Icons.groups_2_outlined,
              label: 'Event',
              selected: value == 'surf_plan',
              onTap: () => onChanged('surf_plan'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ComposerTypeOption extends StatelessWidget {
  const _ComposerTypeOption({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: 0.16) : null,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComposerMediaStage extends StatefulWidget {
  const _ComposerMediaStage({
    required this.media,
    required this.onAddMedia,
    required this.onRemoveMedia,
  });

  final List<_PostMediaDraft> media;
  final VoidCallback onAddMedia;
  final ValueChanged<_PostMediaDraft> onRemoveMedia;

  @override
  State<_ComposerMediaStage> createState() => _ComposerMediaStageState();
}

class _ComposerMediaStageState extends State<_ComposerMediaStage> {
  late final PageController _controller;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _controller = PageController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ComposerMediaStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final itemCount = _mediaItemCount;
    if (itemCount == 0) {
      _index = 0;
      return;
    }
    if (oldWidget.media.length < itemCount) {
      _index = itemCount - 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_controller.hasClients) return;
        _controller.animateToPage(
          _index,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      });
      return;
    }
    if (_index >= itemCount) {
      _index = itemCount - 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final itemCount = _mediaItemCount;
    final hasMedia = itemCount > 0;
    final canAddMedia = itemCount < _maxPostMediaItems;
    final desktop = MediaQuery.sizeOf(context).width >= 980;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: desktop ? 1 : 4 / 5,
              child: hasMedia
                  ? Stack(
                      children: [
                        PageView.builder(
                          controller: _controller,
                          physics: socialPostMediaCarouselPhysics(
                            isWeb: kIsWeb,
                          ),
                          itemCount: itemCount,
                          onPageChanged: (value) =>
                              setState(() => _index = value),
                          itemBuilder: _buildMediaPage,
                        ),
                        if (socialPostMediaCarouselShowsArrows(
                          isWeb: kIsWeb,
                          mediaCount: itemCount,
                        )) ...[
                          if (_index > 0)
                            Positioned(
                              left: 12,
                              top: 0,
                              bottom: 0,
                              child: Center(
                                child: PostMediaArrowButton(
                                  tooltip: 'Previous media',
                                  icon: Icons.chevron_left_rounded,
                                  onPressed: () => _showPage(_index - 1),
                                ),
                              ),
                            ),
                          if (_index < itemCount - 1)
                            Positioned(
                              right: 12,
                              top: 0,
                              bottom: 0,
                              child: Center(
                                child: PostMediaArrowButton(
                                  tooltip: 'Next media',
                                  icon: Icons.chevron_right_rounded,
                                  onPressed: () => _showPage(_index + 1),
                                ),
                              ),
                            ),
                        ],
                        _ComposerRemoveButton(onTap: _removeCurrentMedia),
                        if (itemCount > 1)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 12,
                            child: _ComposerDots(
                              count: itemCount,
                              index: _index,
                            ),
                          ),
                      ],
                    )
                  : _ComposerEmptyMedia(onAddMedia: widget.onAddMedia),
            ),
            if (hasMedia && canAddMedia)
              _ComposerMediaActions(
                itemCount: itemCount,
                onAddMedia: widget.onAddMedia,
              ),
          ],
        ),
      ),
    );
  }

  int get _mediaItemCount => widget.media.length;

  Widget _buildMediaPage(BuildContext context, int index) {
    final media = widget.media[index];
    final photo = media.photo;
    if (photo != null) {
      return _ComposerPhotoPreview(photo: photo.thumbnail);
    }

    final video = media.video;
    if (video == null) return const SizedBox.shrink();
    return Stack(
      children: [Positioned.fill(child: _ComposerVideoPreview(video: video))],
    );
  }

  void _removeCurrentMedia() {
    widget.onRemoveMedia(widget.media[_index]);
  }

  Future<void> _showPage(int index) async {
    if (!_controller.hasClients || index == _index) return;
    await _controller.animateToPage(
      index,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }
}

class _ComposerPhotoPreview extends StatefulWidget {
  const _ComposerPhotoPreview({required this.photo});

  final XFile photo;

  @override
  State<_ComposerPhotoPreview> createState() => _ComposerPhotoPreviewState();
}

class _ComposerPhotoPreviewState extends State<_ComposerPhotoPreview> {
  late Future<Uint8List> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = widget.photo.readAsBytes();
  }

  @override
  void didUpdateWidget(covariant _ComposerPhotoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photo.path != widget.photo.path ||
        oldWidget.photo.name != widget.photo.name) {
      _bytes = widget.photo.readAsBytes();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null) {
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            gaplessPlayback: true,
          );
        }
        return ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: Center(
            child: snapshot.hasError
                ? Icon(
                    Icons.broken_image_outlined,
                    color: scheme.onSurfaceVariant,
                  )
                : CircularProgressIndicator(color: scheme.primary),
          ),
        );
      },
    );
  }
}

class _ComposerEmptyMedia extends StatelessWidget {
  const _ComposerEmptyMedia({required this.onAddMedia});

  final VoidCallback onAddMedia;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.primary.withValues(alpha: 0.06),
      padding: const EdgeInsets.all(22),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Icon(
              Icons.add_photo_alternate_outlined,
              color: scheme.primary,
              size: 30,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Add media',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 4),
          Text(
            'Pick up to 3 photos or videos before you post.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: onAddMedia,
              icon: const Icon(Icons.perm_media_outlined),
              label: const Text('Add media'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ComposerDraftsSheet extends ConsumerWidget {
  const _ComposerDraftsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drafts = ref.watch(composerDraftsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Drafts',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Saved posts stay here while the app is open.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            if (drafts.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Text(
                  'No drafts yet.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: drafts.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final draft = drafts[index];
                    return ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      tileColor: Theme.of(context).cardColor,
                      title: Text(
                        _draftTitle(draft),
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      subtitle: Text(
                        _draftSubtitle(draft),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: 'Delete draft',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () {
                          ref.read(composerDraftsProvider.notifier).state = [
                            for (final item in drafts)
                              if (item.id != draft.id) item,
                          ];
                        },
                      ),
                      onTap: () => Navigator.pop(context, draft),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ComposerVideoPreview extends StatefulWidget {
  const _ComposerVideoPreview({required this.video});

  final XFile video;

  @override
  State<_ComposerVideoPreview> createState() => _ComposerVideoPreviewState();
}

class _ComposerVideoPreviewState extends State<_ComposerVideoPreview> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _initializeController();
  }

  @override
  void didUpdateWidget(covariant _ComposerVideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.path == widget.video.path) return;
    _controller?.dispose();
    _controller = null;
    _failed = false;
    _initializeController();
  }

  void _initializeController() {
    final controller = kIsWeb
        ? VideoPlayerController.networkUrl(Uri.parse(widget.video.path))
        : VideoPlayerController.file(File(widget.video.path));
    _controller = controller;
    controller
      ..setLooping(true)
      ..setVolume(0)
      ..initialize()
          .then((_) {
            if (!mounted) return;
            setState(() {});
          })
          .catchError((Object _) {
            if (!mounted) return null;
            setState(() => _failed = true);
            return null;
          });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _toggle() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final controller = _controller;
    final ready = controller?.value.isInitialized ?? false;
    final playing = controller?.value.isPlaying ?? false;

    return GestureDetector(
      onTap: ready ? _toggle : null,
      child: SizedBox.expand(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: ready
                  ? FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: controller!.value.size.width,
                        height: controller.value.size.height,
                        child: VideoPlayer(controller),
                      ),
                    )
                  : Container(
                      color: scheme.surfaceContainerHighest,
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _failed
                                ? Icons.videocam_outlined
                                : Icons.movie_creation_outlined,
                            color: scheme.onSurfaceVariant,
                          ),
                          if (_failed) ...[
                            const SizedBox(height: 8),
                            Text(
                              'Video added',
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
            ),
            if (!playing)
              Material(
                color: Colors.black.withValues(alpha: 0.34),
                shape: const CircleBorder(),
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 36,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ComposerRemoveButton extends StatelessWidget {
  const _ComposerRemoveButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 10,
      right: 10,
      child: Material(
        color: Colors.black.withValues(alpha: 0.55),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: const Padding(
            padding: EdgeInsets.all(7),
            child: Icon(Icons.close, color: Colors.white, size: 18),
          ),
        ),
      ),
    );
  }
}

class _ComposerDots extends StatelessWidget {
  const _ComposerDots({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (dotIndex) {
        final selected = dotIndex == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: selected ? 8 : 6,
          height: selected ? 8 : 6,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            color: selected
                ? Colors.white
                : Colors.white.withValues(alpha: 0.5),
            shape: BoxShape.circle,
          ),
        );
      }),
    );
  }
}

class _ComposerMediaActions extends StatelessWidget {
  const _ComposerMediaActions({
    required this.itemCount,
    required this.onAddMedia,
  });

  final int itemCount;
  final VoidCallback onAddMedia;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = '$itemCount/$_maxPostMediaItems';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: onAddMedia,
          icon: const Icon(Icons.perm_media_outlined, size: 18),
          label: Text('Add media ($label)'),
          style: OutlinedButton.styleFrom(
            foregroundColor: scheme.primary,
            side: BorderSide(color: scheme.primary.withValues(alpha: 0.32)),
          ),
        ),
      ),
    );
  }
}

class _ComposerMetaChip extends StatelessWidget {
  const _ComposerMetaChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      avatar: Icon(
        icon,
        size: 17,
        color: selected ? scheme.onPrimary : scheme.primary,
      ),
      label: Text(label),
      labelStyle: TextStyle(
        color: selected ? scheme.onPrimary : scheme.onSurface,
        fontWeight: FontWeight.w800,
      ),
      backgroundColor: Theme.of(context).cardColor,
      side: BorderSide(
        color: selected
            ? scheme.primary.withValues(alpha: 0.65)
            : scheme.outlineVariant,
      ),
      color: WidgetStateProperty.resolveWith(
        (_) => selected ? scheme.primary : Theme.of(context).cardColor,
      ),
      onPressed: onTap,
    );
  }
}

const _noSpotValue = '__no_spot__';

class _SpotTagSheet extends StatefulWidget {
  const _SpotTagSheet({
    required this.spots,
    required this.favoriteSpotIds,
    required this.selectedSpotId,
  });

  final List<SpotModel> spots;
  final Set<String> favoriteSpotIds;
  final String? selectedSpotId;

  @override
  State<_SpotTagSheet> createState() => _SpotTagSheetState();
}

class _SpotTagSheetState extends State<_SpotTagSheet> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final selectedSpot = postSpotForId(widget.spots, widget.selectedSpotId);
    final searchResults = _sortTagSpots(
      widget.spots.where((spot) {
        if (query.isEmpty) return true;
        final haystack =
            '${spot.name} ${spot.area} ${spot.region} ${spot.country}'
                .toLowerCase();
        return haystack.contains(query);
      }).toList(),
      widget.favoriteSpotIds,
    ).take(80).toList();
    final countries = _groupSpotsForTagging(
      widget.spots,
      (spot) => spot.country,
    );
    final countryNames = countries.keys.toList()
      ..sort((a, b) => _tagCountryRank(a).compareTo(_tagCountryRank(b)));

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.78,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
          children: [
            Text('Tag a spot', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: 'Search spots',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _controller.clear();
                          setState(() => _query = '');
                        },
                        icon: const Icon(Icons.close),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            _SpotTagTile(
              title: 'No specific spot',
              subtitle: 'Post to the general feed',
              selected: widget.selectedSpotId == null,
              onTap: () => Navigator.of(context).pop(_noSpotValue),
            ),
            const SizedBox(height: 8),
            if (query.isNotEmpty)
              ...searchResults.map(
                (spot) => _SpotTagTile(
                  title: spot.name,
                  subtitle: _spotTagSubtitle(spot),
                  selected: widget.selectedSpotId == spot.id,
                  onTap: () => Navigator.of(context).pop(spot.id),
                ),
              )
            else
              for (final country in countryNames)
                _SpotTagCountrySection(
                  country: country,
                  spots: countries[country]!,
                  selectedSpot: selectedSpot,
                  onSelected: (spotId) => Navigator.of(context).pop(spotId),
                ),
          ],
        ),
      ),
    );
  }
}

class _SpotTagCountrySection extends StatelessWidget {
  const _SpotTagCountrySection({
    required this.country,
    required this.spots,
    required this.selectedSpot,
    required this.onSelected,
  });

  final String country;
  final List<SpotModel> spots;
  final SpotModel? selectedSpot;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final regions = _groupSpotsForTagging(spots, (spot) => spot.region);
    final regionNames = _sortTagGroupNames(regions.keys);
    final selectedInside = selectedSpot?.country == country;

    return _SpotTagExpansion(
      title: country,
      subtitle: '${spots.length} breaks',
      initiallyExpanded: selectedInside,
      children: [
        for (final region in regionNames)
          _SpotTagRegionSection(
            region: region,
            spots: regions[region]!,
            selectedSpot: selectedSpot,
            onSelected: onSelected,
          ),
      ],
    );
  }
}

class _SpotTagRegionSection extends StatelessWidget {
  const _SpotTagRegionSection({
    required this.region,
    required this.spots,
    required this.selectedSpot,
    required this.onSelected,
  });

  final String region;
  final List<SpotModel> spots;
  final SpotModel? selectedSpot;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final areas = _groupSpotsForTagging(spots, (spot) => spot.area);
    final areaNames = _sortTagGroupNames(areas.keys);
    final selectedInside = selectedSpot?.region == region;

    return _SpotTagExpansion(
      title: region,
      subtitle: '${areas.length} areas · ${spots.length} breaks',
      initiallyExpanded: selectedInside,
      inset: true,
      children: [
        for (final area in areaNames)
          _SpotTagAreaSection(
            area: area,
            spots: areas[area]!,
            selectedSpot: selectedSpot,
            onSelected: onSelected,
          ),
      ],
    );
  }
}

class _SpotTagAreaSection extends StatelessWidget {
  const _SpotTagAreaSection({
    required this.area,
    required this.spots,
    required this.selectedSpot,
    required this.onSelected,
  });

  final String area;
  final List<SpotModel> spots;
  final SpotModel? selectedSpot;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final selectedInside = selectedSpot?.area == area;
    final sortedSpots = _sortTagSpots(spots, const <String>{});

    return _SpotTagExpansion(
      title: area,
      subtitle: '${spots.length} ${spots.length == 1 ? 'break' : 'breaks'}',
      initiallyExpanded: selectedInside,
      inset: true,
      children: [
        for (final spot in sortedSpots)
          _SpotTagTile(
            title: spot.name,
            subtitle: _spotTagSubtitle(spot),
            selected: selectedSpot?.id == spot.id,
            compact: true,
            onTap: () => onSelected(spot.id),
          ),
      ],
    );
  }
}

class _SpotTagExpansion extends StatelessWidget {
  const _SpotTagExpansion({
    required this.title,
    required this.subtitle,
    required this.children,
    required this.initiallyExpanded,
    this.inset = false,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final bool initiallyExpanded;
  final bool inset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: EdgeInsets.only(left: inset ? 10 : 0, bottom: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          iconColor: scheme.primary,
          collapsedIconColor: scheme.onSurfaceVariant,
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          subtitle: Text(
            subtitle,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          children: children,
        ),
      ),
    );
  }
}

class _SpotTagTile extends StatelessWidget {
  const _SpotTagTile({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: EdgeInsets.all(compact ? 12 : 14),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(18),
            border: selected ? Border.all(color: scheme.primary) : null,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

Map<String, List<SpotModel>> _groupSpotsForTagging(
  Iterable<SpotModel> spots,
  String Function(SpotModel spot) keyFor,
) {
  final grouped = <String, List<SpotModel>>{};
  for (final spot in spots) {
    final key = keyFor(spot).trim();
    grouped.putIfAbsent(key.isEmpty ? 'Other' : key, () => []).add(spot);
  }
  return grouped;
}

List<String> _sortTagGroupNames(Iterable<String> names) {
  return names.toList()..sort((a, b) {
    final byRank = _tagCountryRank(a).compareTo(_tagCountryRank(b));
    if (byRank != 0 && (byRank < 900 || _tagCountryRank(b) < 900)) {
      return byRank;
    }
    return a.compareTo(b);
  });
}

List<SpotModel> _sortTagSpots(
  List<SpotModel> spots,
  Set<String> favoriteSpotIds,
) {
  return spots..sort((a, b) {
    final favoriteCompare =
        (favoriteSpotIds.contains(b.id) ? 1 : 0) -
        (favoriteSpotIds.contains(a.id) ? 1 : 0);
    if (favoriteCompare != 0) return favoriteCompare;
    return a.name.compareTo(b.name);
  });
}

String _spotTagSubtitle(SpotModel spot) {
  return '${spot.area}, ${spot.region}, ${spot.country}';
}

int _tagCountryRank(String name) {
  const order = [
    'Australia',
    'Indonesia',
    'Sri Lanka',
    'Philippines',
    'Taiwan',
    'Thailand',
    'Vietnam',
    'Malaysia',
    'Myanmar',
    'Timor-Leste',
  ];
  final index = order.indexOf(name);
  return index == -1 ? 900 : index;
}

class _InviteDateChips extends StatelessWidget {
  const _InviteDateChips({
    required this.selectedStartDate,
    required this.selectedEndDate,
    required this.onChanged,
  });

  final DateTime? selectedStartDate;
  final DateTime? selectedEndDate;
  final ValueChanged<DateTimeRange?> onChanged;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final selectedRange = selectedStartDate == null
        ? null
        : DateTimeRange(
            start: selectedStartDate!,
            end: selectedEndDate ?? selectedStartDate!,
          );
    final isSingleToday =
        selectedRange != null &&
        samePostDay(selectedRange.start, today) &&
        samePostDay(selectedRange.end, today);
    final isSingleTomorrow =
        selectedRange != null &&
        samePostDay(selectedRange.start, tomorrow) &&
        samePostDay(selectedRange.end, tomorrow);
    final calendarSelected =
        selectedRange != null && !isSingleToday && !isSingleTomorrow;
    final calendarLabel = calendarSelected
        ? shortPostDateRangeLabel(selectedRange)
        : 'Pick dates';
    final options = <({String label, DateTimeRange range})>[
      (label: 'Today', range: DateTimeRange(start: today, end: today)),
      (label: 'Tomorrow', range: DateTimeRange(start: tomorrow, end: tomorrow)),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (selectedRange != null)
          ChoiceChip(
            label: const Text('No date yet'),
            selected: false,
            onSelected: (_) => onChanged(null),
          ),
        for (final option in options)
          ChoiceChip(
            label: Text(option.label),
            selected: _sameRange(selectedRange, option.range),
            onSelected: (_) => onChanged(option.range),
          ),
        ChoiceChip(
          avatar: const Icon(Icons.calendar_month_outlined, size: 16),
          label: Text(calendarLabel),
          selected: calendarSelected,
          onSelected: (_) => _pickDate(context, today, tomorrow),
        ),
      ],
    );
  }

  Future<void> _pickDate(
    BuildContext context,
    DateTime today,
    DateTime tomorrow,
  ) async {
    final initialRange =
        selectedStartDate != null && !selectedStartDate!.isBefore(today)
        ? DateTimeRange(
            start: DateTime(
              selectedStartDate!.year,
              selectedStartDate!.month,
              selectedStartDate!.day,
            ),
            end: selectedEndDate ?? selectedStartDate!,
          )
        : DateTimeRange(start: tomorrow, end: tomorrow);
    final picked = await showDateRangePicker(
      context: context,
      helpText: 'Pick event dates',
      initialDateRange: initialRange,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
    );
    if (picked == null) return;
    onChanged(picked);
  }
}

class _PostCaptionLineLimitFormatter {
  static String limit(String value) {
    final normalized = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    if (lines.length <= _postCaptionMaxLines) return normalized;
    return lines.take(_postCaptionMaxLines).join('\n');
  }
}

class _PostCaptionCharacterLimitFormatter {
  static String limit(String value) {
    if (value.length <= _postCaptionMaxChars) return value;
    return value.substring(0, _postCaptionMaxChars);
  }
}

String _limitPostCaption(String value) {
  return _PostCaptionLineLimitFormatter.limit(
    _PostCaptionCharacterLimitFormatter.limit(value),
  );
}

String _postCaptionLimitLabel(String text) {
  final lineCount = text.isEmpty ? 0 : text.split('\n').length;
  final remainingLines = _postCaptionMaxLines - lineCount;
  if (remainingLines <= 3) {
    return '$remainingLines ${remainingLines == 1 ? 'line' : 'lines'} left';
  }
  return 'Up to $_postCaptionMaxLines lines';
}

TextSelection _postCaptionSelection(String text) {
  return TextSelection.collapsed(offset: text.length);
}

class _PostCaptionLimitNotice extends StatelessWidget {
  const _PostCaptionLimitNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final nearLimit = text.split('\n').length >= _postCaptionMaxLines - 3;

    return Text(
      _postCaptionLimitLabel(text),
      style: theme.textTheme.bodySmall?.copyWith(
        color: nearLimit ? scheme.primary : scheme.onSurfaceVariant,
        fontWeight: nearLimit ? FontWeight.w800 : FontWeight.w600,
      ),
    );
  }
}

class _PostPhotoDraft {
  const _PostPhotoDraft({required this.fullImage, required this.thumbnail});

  final XFile fullImage;
  final XFile thumbnail;
}

class _PostMediaDraft {
  const _PostMediaDraft.photo(this.photo) : video = null;

  const _PostMediaDraft.video(this.video) : photo = null;

  final _PostPhotoDraft? photo;
  final XFile? video;
}

class _ComposerPostDraft {
  const _ComposerPostDraft({
    required this.id,
    required this.body,
    required this.postType,
    required this.visibility,
    required this.media,
    required this.savedAt,
    this.spotId,
    this.inviteDate,
    this.inviteEndDate,
  });

  final String id;
  final String body;
  final String postType;
  final String visibility;
  final List<_PostMediaDraft> media;
  final DateTime savedAt;
  final String? spotId;
  final DateTime? inviteDate;
  final DateTime? inviteEndDate;
}

const _maxPostMediaItems = 3;
const _maxComposerDrafts = 8;
const _maxPostPhotoBytes = 15 * 1024 * 1024;
const _maxPostVideoBytes = 250 * 1024 * 1024;
const _maxPostVideoDurationMilliseconds = 30500.0;
String _draftTitle(_ComposerPostDraft draft) {
  return draft.postType == 'surf_plan' ? 'Event draft' : 'Post draft';
}

String _draftSubtitle(_ComposerPostDraft draft) {
  final parts = <String>[
    _draftAgeLabel(draft.savedAt),
    if (draft.body.isNotEmpty) draft.body,
    if (draft.media.isNotEmpty)
      '${draft.media.length} ${draft.media.length == 1 ? 'media item' : 'media items'}',
    if (draft.spotId != null) 'Spot tagged',
  ];
  return parts.join(' - ');
}

String _draftAgeLabel(DateTime savedAt) {
  final elapsed = DateTime.now().difference(savedAt);
  if (elapsed.inMinutes < 1) return 'Saved just now';
  if (elapsed.inHours < 1) return 'Saved ${elapsed.inMinutes}m ago';
  if (elapsed.inDays < 1) return 'Saved ${elapsed.inHours}h ago';
  return 'Saved ${elapsed.inDays}d ago';
}

bool _sameRange(DateTimeRange? left, DateTimeRange? right) {
  if (left == null || right == null) return left == right;
  return samePostDay(left.start, right.start) &&
      samePostDay(left.end, right.end);
}

String _dateOnly(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

String _formatFileSize(int bytes) {
  final mb = bytes / (1024 * 1024);
  return '${mb.round()}MB';
}

int? _uploadPercent(int sent, int total) {
  if (total <= 0) return null;
  return ((sent / total) * 100).clamp(0, 99).round();
}

const _postCaptionMaxLines = 16;
const _postCaptionMaxChars = 1600;
