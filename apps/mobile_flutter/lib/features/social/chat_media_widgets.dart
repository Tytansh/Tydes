import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import '../../core/media/native_hls_support.dart';
import '../../core/media/video_playback_sources.dart';
import '../../core/moderation/content_moderation.dart';
import '../../core/network/api_error_message.dart';
import '../../core/network/chat_media_models.dart';
import 'chat_media_api.dart';
import 'post_media_zoom.dart';
import '../home/home_page.dart' show meProvider;

final chatMediaPickerProvider = Provider<Future<XFile?> Function()>(
  (ref) =>
      () => ImagePicker().pickMedia(
        imageQuality: 78,
        maxWidth: 2048,
        maxHeight: 2048,
        requestFullMetadata: false,
      ),
);

/// One selected file stays local until Send. Failed sends retain both caption
/// and the acknowledged attachment ID, so retry never reuploads a ready file.
class ChatMessageComposer extends ConsumerStatefulWidget {
  const ChatMessageComposer({
    super.key,
    required this.ownerId,
    required this.conversationType,
    required this.conversationId,
    required this.controller,
    required this.onSend,
    this.hintText = 'Message...',
    this.onSent,
    this.attachmentsAllowed = true,
    this.maxLength = 1600,
  });
  final String ownerId, conversationType, conversationId, hintText;
  final TextEditingController controller;
  final Future<void> Function(String text, String? attachmentId) onSend;
  final VoidCallback? onSent;
  final bool attachmentsAllowed;
  final int maxLength;
  @override
  ConsumerState<ChatMessageComposer> createState() =>
      _ChatMessageComposerState();
}

class _ChatMessageComposerState extends ConsumerState<ChatMessageComposer> {
  XFile? _file;
  Uint8List? _photo;
  String? _type, _reservation, _error;
  ChatMediaAttachment? _ready;
  ChatMediaSession? _session;
  CancelToken? _cancel;
  double? _progress;
  bool _busy = false, _processing = false, _committing = false;
  int _generation = 0;

  String get _scope =>
      '${widget.ownerId}\u0000${widget.conversationType}\u0000${widget.conversationId}';
  Future<ChatMediaSession> _connected() async {
    if (_session != null) {
      await _session!.account.ensureCurrent();
      return _session!;
    }
    final scope = _scope;
    final session = await ref
        .read(chatMediaApiProvider)
        .session(
          widget.ownerId,
          widget.conversationType,
          widget.conversationId,
        );
    if (!mounted || scope != _scope) {
      throw StateError('Your conversation changed. Reopen it to continue.');
    }
    return _session = session;
  }

  void _clear({bool cleanup = true}) {
    _generation++;
    _cancel?.cancel();
    final reservation = _reservation;
    if (cleanup && reservation != null && !_committing) {
      unawaited(_session?.cancel(reservation).catchError((Object _) {}));
    }
    _file = null;
    _photo = null;
    _type = null;
    _reservation = null;
    _ready = null;
    _error = null;
    _progress = null;
    _processing = false;
    _busy = false;
    _committing = false;
  }

  void _cancelUpload() {
    if (_committing) return;
    _generation++;
    _cancel?.cancel();
    final reservation = _reservation;
    if (reservation != null) {
      unawaited(_session?.cancel(reservation).catchError((Object _) {}));
    }
    _reservation = null;
    _ready = null;
    _busy = false;
    _processing = false;
    _progress = null;
    _error = 'Upload canceled. Your file and caption are still here.';
  }

  @override
  void didUpdateWidget(covariant ChatMessageComposer old) {
    super.didUpdateWidget(old);
    if (old.ownerId != widget.ownerId ||
        old.conversationId != widget.conversationId ||
        old.conversationType != widget.conversationType) {
      _clear();
      _session = null;
      widget.controller.clear();
    }
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  Future<void> _pick() async {
    if (_busy) return;
    if (!widget.attachmentsAllowed) {
      setState(
        () => _error =
            'Both people must accept this conversation before sending photos or videos.',
      );
      return;
    }
    final generation = ++_generation;
    try {
      final caps = await (await _connected()).capabilities();
      if (!mounted || generation != _generation) return;
      if (!caps.enabled) {
        throw StateError(
          caps.reason ?? 'Private photos and videos are coming soon.',
        );
      }
      final picked = await ref.read(chatMediaPickerProvider)();
      if (picked == null || !mounted || generation != _generation) return;
      final name = picked.name.toLowerCase();
      final video =
          picked.mimeType?.startsWith('video/') == true ||
          RegExp(r'\.(mp4|mov|m4v|webm|avi)$').hasMatch(name);
      if (!(video ? caps.videosEnabled : caps.photosEnabled)) {
        throw StateError(
          video
              ? 'Private videos are not available yet. Photos are available.'
              : 'Private photos are not available yet.',
        );
      }
      final length = await picked.length();
      final limit = video ? caps.videoMaxBytes : caps.photoMaxBytes;
      if (length <= 0 || length > limit) {
        throw StateError(
          'Choose a ${video ? 'video' : 'photo'} under ${(limit / 1048576).floor()} MB.',
        );
      }
      if (video) {
        final controller = kIsWeb
            ? VideoPlayerController.networkUrl(Uri.parse(picked.path))
            : VideoPlayerController.file(File(picked.path));
        try {
          await controller.setVolume(0);
          await controller.initialize().timeout(const Duration(seconds: 20));
          if (controller.value.duration.inMilliseconds >
              caps.videoMaxSeconds * 1000) {
            throw StateError(
              'Videos can be up to ${caps.videoMaxSeconds.floor()} seconds long.',
            );
          }
        } finally {
          await controller.dispose();
        }
      }
      final photo = video ? null : await picked.readAsBytes();
      if (!mounted || generation != _generation) return;
      setState(() {
        _clear();
        _file = picked;
        _photo = photo;
        _type = video ? 'video' : 'photo';
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = friendlyErrorMessage(error));
      }
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    final text = widget.controller.text.trim();
    if (text.isEmpty && _file == null) return;
    if (_file != null && !widget.attachmentsAllowed) {
      setState(
        () => _error = 'This conversation is not ready for private media.',
      );
      return;
    }
    if (text.length > widget.maxLength || hasBlockedContent(text)) {
      setState(
        () => _error = text.length > widget.maxLength
            ? 'Messages can be up to ${widget.maxLength} characters.'
            : contentBlockedMessage,
      );
      return;
    }
    final generation = _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_file != null && _ready == null) {
        final session = await _connected();
        if (!mounted || generation != _generation) return;
        final cancellation = _cancel = CancelToken();
        ChatMediaAttachment ready;
        if (_processing && _reservation != null) {
          ready = await session.complete(_reservation!, _type!, cancellation);
        } else {
          ready = await session.upload(
            _file!,
            _type!,
            cancellation: cancellation,
            onReservation: (id) {
              if (!mounted || generation != _generation) {
                unawaited(session.cancel(id).catchError((Object _) {}));
              } else {
                _reservation = id;
              }
            },
            onProgress: (progress) {
              if (mounted && generation == _generation) {
                setState(() {
                  _progress = progress;
                  _processing = progress == null;
                });
              }
            },
          );
        }
        if (!mounted || generation != _generation) return;
        _ready = ready;
      }
      if (!mounted || generation != _generation) return;
      setState(() => _committing = true);
      await widget.onSend(text, _ready?.id);
      if (!mounted || generation != _generation) return;
      if (widget.controller.text.trim() == text) widget.controller.clear();
      setState(() => _clear(cleanup: false));
      widget.onSent?.call();
    } catch (error) {
      if (mounted &&
          generation == _generation &&
          !(error is DioException && CancelToken.isCancel(error))) {
        setState(
          () => _error = 'Message not sent. ${friendlyErrorMessage(error)}',
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _busy = false;
          _committing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_file != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: 64,
                      height: 64,
                      child: _photo != null
                          ? Image.memory(
                              _photo!,
                              fit: BoxFit.cover,
                              cacheWidth: 256,
                            )
                          : const ColoredBox(
                              color: Color(0xFF173F45),
                              child: Icon(Icons.videocam, color: Colors.white),
                            ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _file!.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (_busy && !_committing) ...[
                          Text(
                            _processing
                                ? 'Processing video…'
                                : 'Uploading ${((_progress ?? 0) * 100).round()}%',
                          ),
                          LinearProgressIndicator(
                            value: _processing ? null : _progress,
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: _busy ? 'Cancel upload' : 'Remove attachment',
                    onPressed: _committing
                        ? null
                        : () {
                            if (_committing) return;
                            setState(() {
                              if (_busy) {
                                _cancelUpload();
                              } else {
                                _clear();
                              }
                            });
                          },
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          if (_error != null)
            Row(
              children: [
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                if (!_busy &&
                    (_file != null || widget.controller.text.trim().isNotEmpty))
                  TextButton(onPressed: _submit, child: const Text('Retry')),
              ],
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Add photo or video',
                onPressed: _busy ? null : _pick,
                icon: const Icon(Icons.add_circle_outline),
              ),
              Expanded(
                child: TextField(
                  key: const ValueKey('dm-message-input'),
                  controller: widget.controller,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: widget.maxLength,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    hintText: widget.hintText,
                    counterText: '',
                    filled: true,
                    fillColor: Theme.of(context).cardColor,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('dm-send-message'),
                onPressed: _busy ? null : _submit,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(46, 46),
                  padding: EdgeInsets.zero,
                  shape: const CircleBorder(),
                ),
                child: _busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_upward_rounded),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class ChatMediaBubble extends ConsumerStatefulWidget {
  const ChatMediaBubble({
    super.key,
    required this.attachment,
    required this.ownerId,
    required this.conversationType,
    required this.conversationId,
  });
  final ChatMediaAttachment attachment;
  final String ownerId, conversationType, conversationId;
  @override
  ConsumerState<ChatMediaBubble> createState() => _ChatMediaBubbleState();
}

class _ChatMediaBubbleState extends ConsumerState<ChatMediaBubble> {
  late Future<Map<String, dynamic>> _access;
  int _generation = 0;
  bool _renewed = false;
  Future<Map<String, dynamic>> _load() async {
    final owner = widget.ownerId;
    final type = widget.conversationType;
    final conversation = widget.conversationId;
    final attachment = widget.attachment.id;
    final session = await ref
        .read(chatMediaApiProvider)
        .session(owner, type, conversation);
    return session.access(attachment);
  }

  @override
  void initState() {
    super.initState();
    _access = _load();
  }

  @override
  void didUpdateWidget(covariant ChatMediaBubble old) {
    super.didUpdateWidget(old);
    if (old.ownerId != widget.ownerId ||
        old.conversationId != widget.conversationId ||
        old.conversationType != widget.conversationType ||
        old.attachment.id != widget.attachment.id) {
      _generation++;
      _renewed = false;
      _access = _load();
    }
  }

  void _refresh() {
    setState(() {
      _generation++;
      _access = _load();
    });
  }

  Future<void> _open() async {
    try {
      final generation = _generation;
      final owner = widget.ownerId;
      final mediaType = widget.attachment.mediaType;
      final access = await _load(); // Always get fresh, authorized viewer URLs.
      if (!mounted || generation != _generation) return;
      await showDialog<void>(
        context: context,
        builder: (_) => Consumer(
          builder: (context, ref, _) {
            final account = ref.watch(meProvider);
            if (account.isLoading ||
                account.hasError ||
                account.valueOrNull?.id != owner) {
              return const Dialog(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Your account changed. Reopen this attachment.'),
                ),
              );
            }
            return Dialog(
              insetPadding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 680,
                  maxHeight: 680,
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (mediaType == 'video')
                      ChatVideoViewer(
                        url: access['url'] as String,
                        fallbackUrl: access['fallback_url'] as String?,
                      )
                    else
                      PostMediaZoom(
                        child: Image.network(
                          access['url'] as String,
                          fit: BoxFit.contain,
                          cacheWidth: 2048,
                          errorBuilder: (_, _, _) => const Center(
                            child: Text(
                              'Photo unavailable. Close and reopen to retry.',
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      right: 4,
                      top: 4,
                      child: IconButton(
                        tooltip: 'Close media',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    } catch (_) {
      if (mounted) _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(meProvider);
    if (account.isLoading ||
        account.hasError ||
        account.valueOrNull?.id != widget.ownerId) {
      return const SizedBox(
        width: 280,
        height: 190,
        child: Center(child: Text('Checking private media access…')),
      );
    }
    return SizedBox(
      width: 280,
      height: 190,
      child: FutureBuilder<Map<String, dynamic>>(
        key: ValueKey(_generation),
        future: _access,
        builder: (context, state) {
          if (state.hasError) {
            return Center(
              child: TextButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Reload attachment'),
              ),
            );
          }
          if (!state.hasData) {
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          }
          final data = state.data!;
          final thumbnail = data['thumbnail_url'] as String?;
          final video = widget.attachment.mediaType == 'video';
          return InkWell(
            onTap: _open,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (!video || thumbnail != null)
                    Image.network(
                      thumbnail ?? data['url'] as String,
                      fit: BoxFit.cover,
                      cacheWidth: 840,
                      errorBuilder: (_, _, _) {
                        if (!_renewed) {
                          _renewed = true;
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) _refresh();
                          });
                        }
                        return const Center(
                          child: Icon(Icons.broken_image_outlined),
                        );
                      },
                    )
                  else
                    const ColoredBox(color: Color(0xFF173F45)),
                  if (video)
                    const Center(
                      child: Icon(
                        Icons.play_circle_fill,
                        color: Colors.white,
                        size: 48,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Chat videos never autoplay. Explicit play is muted; leaving/covering the
/// viewer immediately pauses/mutes, including late initialization/play calls.
class ChatVideoViewer extends StatefulWidget {
  const ChatVideoViewer({super.key, required this.url, this.fallbackUrl});
  final String url;
  final String? fallbackUrl;
  @override
  State<ChatVideoViewer> createState() => _ChatVideoViewerState();
}

class _ChatVideoViewerState extends State<ChatVideoViewer>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _foreground = true, _visible = true, _failed = false, _fallback = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final source = videoPlaybackSources(
      url: widget.url,
      fallbackUrl: widget.fallbackUrl,
      isWeb: kIsWeb,
      supportsNativeHls: kIsWeb && nativeHlsPlaybackSupported(),
    );
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(_fallback ? widget.fallbackUrl! : source.primary),
    );
    _controller = controller;
    try {
      await controller.setVolume(0);
      await controller.initialize();
      if (!mounted || generation != _generation) return;
      controller.addListener(_changed);
      setState(() {});
    } catch (_) {
      if (!mounted || generation != _generation) return;
      await controller.dispose();
      if (!_fallback &&
          widget.fallbackUrl != null &&
          widget.fallbackUrl != source.primary) {
        _fallback = true;
        _load();
      } else {
        setState(() => _failed = true);
      }
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _silence() {
    final c = _controller;
    if (c != null) {
      unawaited(c.setVolume(0).catchError((Object _) {}));
      unawaited(c.pause().catchError((Object _) {}));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = ModalRoute.of(context)?.isCurrent ?? true;
    if (!_visible) _silence();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) _silence();
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _controller?.removeListener(_changed);
    _silence();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    final c = _controller;
    final generation = _generation;
    if (c == null || !c.value.isInitialized || !_foreground || !_visible) {
      return;
    }
    try {
      if (c.value.isPlaying) {
        _silence();
      } else {
        await c.setVolume(0);
        if (!mounted ||
            generation != _generation ||
            !_foreground ||
            !_visible) {
          return;
        }
        await c.play();
        if (!mounted ||
            generation != _generation ||
            !_foreground ||
            !_visible) {
          _silence();
        }
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (_failed) {
      return const Center(
        child: Text('Video unavailable. Close and reopen to retry.'),
      );
    }
    if (c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: c.value.aspectRatio,
            child: VideoPlayer(c),
          ),
        ),
        Center(
          child: IconButton(
            tooltip: c.value.isPlaying ? 'Pause video' : 'Play video',
            onPressed: _play,
            iconSize: 48,
            icon: Icon(
              c.value.isPlaying ? Icons.pause_circle : Icons.play_circle,
              color: Colors.white,
            ),
          ),
        ),
        Positioned(
          left: 8,
          bottom: 8,
          child: IconButton(
            tooltip: 'Toggle video sound',
            onPressed: () {
              if (_foreground && _visible && c.value.isPlaying) {
                c.setVolume(c.value.volume == 0 ? 1 : 0);
              }
            },
            icon: Icon(
              c.value.volume == 0 ? Icons.volume_off : Icons.volume_up,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }
}
