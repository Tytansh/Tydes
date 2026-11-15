import 'dart:async';
import 'package:dio/dio.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../home/home_page.dart' show meProvider;
import 'direct_message_api.dart';
import 'chat_media_widgets.dart';
import 'event_chat_controls.dart';

final eventChatAttendeesProvider = FutureProvider.autoDispose
    .family<List<EventAttendeeModel>, String>((ref, postId) {
      ref.watch(socialRefreshKeyProvider);
      return ref.watch(surfRepositoryProvider).fetchEventAttendees(postId);
    });

Future<void> showEventChatJoinPrompt(
  BuildContext context, {
  required String postId,
  String? eventTitle,
}) async {
  final title = eventTitle?.trim();
  final openChat = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Join the event group chat?'),
      content: Text(
        title == null || title.isEmpty
            ? 'Chat with everyone going, plan the meetup, and share updates.'
            : 'Chat with everyone going to “$title”, plan the meetup, and share updates.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Maybe later'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          icon: const Icon(Icons.forum_outlined),
          label: const Text('Join group chat'),
        ),
      ],
    ),
  );
  if (openChat == true && context.mounted) {
    context.push('/event/$postId/chat');
  }
}

class EventChatPage extends ConsumerStatefulWidget {
  const EventChatPage({super.key, required this.postId});

  final String postId;

  @override
  ConsumerState<EventChatPage> createState() => _EventChatPageState();
}

class _EventChatPageState extends ConsumerState<EventChatPage>
    with WidgetsBindingObserver {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _refreshTimer;
  List<EventChatMessageModel> _messages = const [];
  SocialPostModel? _event;
  String? _viewerId;
  String? _error;
  bool _loading = true;
  bool _sending = false;
  bool _foreground = true;
  bool _loadingRequest = false;
  bool _settingsLoaded = false;
  bool _leftConfirmed = false;
  int _revision = 0;
  DirectMessageSession? _session;
  final Map<String, String> _sendKeys = {};
  bool get _visible =>
      mounted &&
      _foreground &&
      (ModalRoute.of(context)?.isCurrent ?? true) &&
      (_viewerId == null || ref.read(meProvider).valueOrNull?.id == _viewerId);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load(initial: true);
    });
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_visible) _load(initial: false);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _revision++;
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load({required bool initial}) async {
    if (_loadingRequest || _sending || !_visible) return;
    _loadingRequest = true;
    final revision = _revision;
    try {
      final owner = await ref.read(meProvider.future);
      if (!mounted ||
          revision != _revision ||
          (_viewerId != null && _viewerId != owner.id)) {
        return;
      }
      final session = _session ??= await ref
          .read(directMessageApiProvider)
          .openSession(owner.id);
      // Capture account-scoped controls only after identity has resolved.
      final controls = ref.read(eventChatControlsProvider.notifier);
      if (ref.read(eventChatControlsProvider).pending.contains(widget.postId) ||
          (!initial &&
              (_leftConfirmed ||
                  controls.current(widget.postId)?.left == true))) {
        return;
      }
      if (!_settingsLoaded || initial) {
        final settings = await controls.fetch(widget.postId);
        if (!mounted ||
            !_visible ||
            ref.read(meProvider).valueOrNull?.id != owner.id) {
          return;
        }
        _settingsLoaded = true;
        if (settings.left) {
          setState(() {
            _viewerId = owner.id;
            _leftConfirmed = true;
            _messages = const [];
            _loading = false;
            _error = null;
          });
          return;
        }
      }
      final controlRevision = controls.revisionFor(widget.postId);
      final repository = ref.read(surfRepositoryProvider);
      // A newly opened left room has not loaded its post yet. Rejoining must
      // recover that metadata too, without re-fetching confirmed settings.
      final loadEvent = initial || _event == null;
      final results = await Future.wait<dynamic>([
        session.getList(
          '/social/posts/${Uri.encodeComponent(widget.postId)}/chat',
        ),
        if (loadEvent) repository.fetchSocialPost(widget.postId),
      ]);
      await session.ensureCurrent();
      if (!mounted ||
          revision != _revision ||
          !_visible ||
          _sending ||
          controlRevision != controls.revisionFor(widget.postId) ||
          ref.read(meProvider).valueOrNull?.id != owner.id) {
        return;
      }
      final rows = results[0] as List<Map<String, dynamic>>;
      final messages = rows
          .map(
            (row) => EventChatMessageModel.fromJson(
              Map<String, dynamic>.from(row as Map),
            ),
          )
          .toList();
      if (!initial &&
          !loadEvent &&
          !_loading &&
          _error == null &&
          _viewerId == owner.id &&
          _sameEventMessages(_messages, messages)) {
        return;
      }
      setState(() {
        _messages = messages;
        if (loadEvent) {
          _event = results[1] as SocialPostModel;
        }
        _viewerId = owner.id;
        _error = null;
        _loading = false;
      });
      if (initial) _scrollToBottom();
    } catch (error) {
      if (_eventChatLeftError(error)) {
        await _handleServerLeft();
        return;
      }
      if (!mounted || revision != _revision || !initial) return;
      setState(() {
        _error = 'Join this event before entering its group chat.';
        _loading = false;
      });
    } finally {
      _loadingRequest = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && _visible) _load(initial: false);
  }

  Future<void> _send(String text, String? attachmentId) async {
    if (_sending ||
        !_visible ||
        _viewerId == null ||
        _session == null ||
        _leftConfirmed ||
        ref.read(eventChatControlsProvider).settings[widget.postId]?.left ==
            true) {
      throw StateError('Reopen the event chat to send.');
    }
    _revision++;
    final owner = _viewerId;
    final fingerprint = '$text\u0000${attachmentId ?? ''}';
    final key = _sendKeys.putIfAbsent(
      fingerprint,
      () =>
          'event_${DateTime.now().microsecondsSinceEpoch}_${_sendKeys.length}',
    );
    setState(() => _sending = true);
    try {
      final ack = await _session!.postMap(
        '/social/posts/${Uri.encodeComponent(widget.postId)}/chat',
        {
          'text': text,
          'client_message_id': key,
          'attachment_id': ?attachmentId,
        },
      );
      if (!mounted || !_visible || _viewerId != owner) {
        throw StateError('Your account changed. Reopen the event chat.');
      }
      final message = EventChatMessageModel.fromJson(ack);
      if (message.userId != owner ||
          message.postId != widget.postId ||
          message.clientMessageId != key ||
          (attachmentId != null && message.attachment?.id != attachmentId)) {
        throw StateError(
          'The server did not confirm this message. Please retry.',
        );
      }
      _revision++;
      setState(() {
        _messages = [
          ..._messages.where((item) => item.id != message.id),
          message,
        ];
        _error = null;
      });
      _sendKeys.remove(fingerprint);
      _scrollToBottom();
    } catch (error) {
      if (_eventChatLeftError(error)) await _handleServerLeft();
      rethrow;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _handleServerLeft() async {
    if (!mounted) return;
    final owner = _viewerId ?? ref.read(meProvider).valueOrNull?.id;
    if (owner == null || _session == null) return;
    try {
      await _session!.ensureCurrent();
    } catch (_) {
      return;
    }
    if (!mounted ||
        !_visible ||
        ref.read(meProvider).valueOrNull?.id != owner) {
      return;
    }
    _revision++;
    setState(() {
      _viewerId = owner;
      _leftConfirmed = true;
      _messages = const [];
      _loading = false;
      _error = null;
    });
    // One permission-change refresh, never a settings request on each poll.
    try {
      await ref.read(eventChatControlsProvider.notifier).fetch(widget.postId);
    } catch (_) {}
  }

  Future<void> _rejoin() async {
    final controls = ref.read(eventChatControlsProvider.notifier);
    try {
      await controls.join(widget.postId);
      if (!mounted || !_visible || controls.ownerId != _viewerId) return;
      _revision++;
      setState(() {
        _leftConfirmed = false;
        _error = null;
      });
      await _load(initial: false);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not rejoin this chat. Please try again.'),
          ),
        );
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final owner = ref.watch(meProvider).valueOrNull?.id;
    if (_viewerId != null && owner != _viewerId) {
      return Scaffold(
        appBar: AppBar(title: const Text('Event group chat')),
        body: const Center(
          child: Text('Your account changed. Reopen this chat to continue.'),
        ),
      );
    }
    final title = _event?.body.trim();
    final controls = ref.watch(eventChatControlsProvider);
    final settings = controls.settings[widget.postId];
    final left = _leftConfirmed || settings?.left == true;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Event group chat'),
            if (title != null && title.isNotEmpty)
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        actions: [
          if (_viewerId != null)
            EventChatOptionsButton(
              postId: widget.postId,
              initialMuted: settings?.muted ?? false,
              disabled: _sending || _loading,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _ChatAccessError(message: _error!)
          : Column(
              children: [
                Expanded(
                  child: left
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('You left this event chat.'),
                              const SizedBox(height: 8),
                              const Text('Your event RSVP has not changed.'),
                              const SizedBox(height: 12),
                              FilledButton(
                                onPressed:
                                    controls.pending.contains(widget.postId)
                                    ? null
                                    : _rejoin,
                                child: const Text('Rejoin chat'),
                              ),
                            ],
                          ),
                        )
                      : _messages.isEmpty
                      ? const _EmptyEventChat()
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
                          itemCount: _messages.length,
                          itemBuilder: (context, index) => _MessageBubble(
                            message: _messages[index],
                            mine: _messages[index].userId == _viewerId,
                            viewerId: _viewerId!,
                          ),
                        ),
                ),
                if (_viewerId != null)
                  Offstage(
                    offstage: left,
                    child: ChatMessageComposer(
                      key: ValueKey(
                        'event-composer-$_viewerId-${widget.postId}',
                      ),
                      ownerId: _viewerId!,
                      conversationType: 'event',
                      conversationId: widget.postId,
                      controller: _controller,
                      onSend: _send,
                      hintText: 'Message everyone going…',
                      maxLength: 600,
                    ),
                  ),
              ],
            ),
    );
  }
}

bool _eventChatLeftError(Object error) {
  if (error is! DioException || error.response?.statusCode != 403) return false;
  final data = error.response?.data;
  final detail = data is Map ? data['detail'] : null;
  return detail is Map && detail['code'] == 'event_chat_left';
}

bool _sameEventMessages(
  List<EventChatMessageModel> previous,
  List<EventChatMessageModel> next,
) {
  if (identical(previous, next)) return true;
  if (previous.length != next.length) return false;
  for (var index = 0; index < previous.length; index++) {
    final a = previous[index];
    final b = next[index];
    if (a.id != b.id ||
        a.postId != b.postId ||
        a.userId != b.userId ||
        a.authorName != b.authorName ||
        a.authorHandle != b.authorHandle ||
        a.authorAvatarUrl != b.authorAvatarUrl ||
        a.text != b.text ||
        a.createdAt != b.createdAt ||
        a.clientMessageId != b.clientMessageId ||
        a.attachment?.id != b.attachment?.id ||
        a.attachment?.mediaType != b.attachment?.mediaType) {
      return false;
    }
  }
  return true;
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.mine,
    required this.viewerId,
  });

  final EventChatMessageModel message;
  final bool mine;
  final String viewerId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: mine
              ? (dark ? scheme.primary : const Color(0xFF087E7A))
              : theme.cardColor,
          borderRadius: BorderRadius.circular(18),
          border: mine
              ? null
              : Border.all(
                  color: dark ? scheme.outlineVariant : const Color(0xFFE0E2DC),
                ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!mine)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  message.authorName,
                  style: TextStyle(
                    color: dark ? scheme.primary : const Color(0xFF087E7A),
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ),
            if (message.attachment != null)
              ChatMediaBubble(
                attachment: message.attachment!,
                ownerId: viewerId,
                conversationType: 'event',
                conversationId: message.postId,
              ),
            if (message.text.isNotEmpty)
              Text(
                message.text,
                style: TextStyle(
                  color: mine
                      ? (dark ? scheme.onPrimary : Colors.white)
                      : (dark ? scheme.onSurface : const Color(0xFF202725)),
                  height: 1.3,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyEventChat extends StatelessWidget {
  const _EmptyEventChat();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'You’re in. Start the conversation with everyone going.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _ChatAccessError extends StatelessWidget {
  const _ChatAccessError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline_rounded, size: 42),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
