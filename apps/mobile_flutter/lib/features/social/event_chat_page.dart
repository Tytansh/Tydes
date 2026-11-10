import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';

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

class _EventChatPageState extends ConsumerState<EventChatPage> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _refreshTimer;
  List<EventChatMessageModel> _messages = const [];
  SocialPostModel? _event;
  String? _viewerId;
  String? _error;
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load(initial: true);
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _load(initial: false),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load({required bool initial}) async {
    try {
      final repository = ref.read(surfRepositoryProvider);
      final results = await Future.wait<dynamic>([
        repository.fetchEventChat(widget.postId),
        if (initial) repository.fetchSocialPost(widget.postId),
        if (initial) repository.fetchMe(),
      ]);
      if (!mounted) return;
      final messages = results[0] as List<EventChatMessageModel>;
      setState(() {
        _messages = messages;
        if (initial) {
          _event = results[1] as SocialPostModel;
          _viewerId = (results[2] as UserProfile).id;
        }
        _error = null;
        _loading = false;
      });
      if (initial) _scrollToBottom();
    } catch (_) {
      if (!mounted || !initial) return;
      setState(() {
        _error = 'Join this event before entering its group chat.';
        _loading = false;
      });
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final message = await ref
          .read(surfRepositoryProvider)
          .sendEventChatMessage(postId: widget.postId, text: text);
      if (!mounted) return;
      _controller.clear();
      setState(() {
        _messages = [..._messages, message];
        _error = null;
      });
      _scrollToBottom();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send that message.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
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
    final title = _event?.body.trim();
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
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _ChatAccessError(message: _error!)
          : Column(
              children: [
                Expanded(
                  child: _messages.isEmpty
                      ? const _EmptyEventChat()
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
                          itemCount: _messages.length,
                          itemBuilder: (context, index) => _MessageBubble(
                            message: _messages[index],
                            mine: _messages[index].userId == _viewerId,
                          ),
                        ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            minLines: 1,
                            maxLines: 4,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: const InputDecoration(
                              hintText: 'Message everyone going…',
                            ),
                            onSubmitted: (_) => _send(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          onPressed: _sending ? null : _send,
                          icon: _sending
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.send_rounded),
                          tooltip: 'Send',
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.mine});

  final EventChatMessageModel message;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: mine ? const Color(0xFF087E7A) : Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: mine ? null : Border.all(color: const Color(0xFFE0E2DC)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!mine)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  message.authorName,
                  style: const TextStyle(
                    color: Color(0xFF087E7A),
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ),
            Text(
              message.text,
              style: TextStyle(
                color: mine ? Colors.white : const Color(0xFF202725),
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
