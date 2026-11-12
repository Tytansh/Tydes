import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';
import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../../core/moderation/content_moderation.dart';
import '../../core/widgets/feed_refresh_indicator.dart';
import '../../core/network/api_error_message.dart';
import '../auth/email_verification_sheet.dart';
import '../home/home_page.dart' show meProvider;
import 'direct_message_api.dart';
import 'inbox_badges.dart';
import 'social_profile.dart';

final directMessageThreadsProvider =
    StateNotifierProvider<
      DirectMessageThreadsNotifier,
      List<DirectMessageThread>
    >(
      (ref) => DirectMessageThreadsNotifier(
        api: ref.watch(directMessageApiProvider),
        ownerId: ref.watch(meProvider.select((value) => value.valueOrNull?.id)),
        onStatus: (status) =>
            ref.read(dmInboxStatusProvider.notifier).state = status,
        onCountsChanged: () =>
            ref.read(inboxCountsRefreshKeyProvider.notifier).state++,
      ),
    );

final dmInboxStatusProvider = StateProvider<AsyncValue<void>>(
  (ref) => const AsyncData(null),
);

class _VerifyEmailAction extends ConsumerWidget {
  const _VerifyEmailAction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider).valueOrNull;
    if (me == null || me.emailVerified) return const SizedBox.shrink();
    return TextButton.icon(
      key: const ValueKey('messages-verify-email'),
      icon: const Icon(Icons.mark_email_unread_outlined, size: 18),
      label: const Text('Verify email'),
      onPressed: () async {
        final verified = await showEmailVerificationSheet(
          context,
          accountId: me.id,
          email: me.email,
        );
        if (!context.mounted ||
            !verified ||
            ref.read(meProvider).valueOrNull?.id != me.id) {
          return;
        }
        try {
          final updated = await ref.refresh(meProvider.future);
          if (!context.mounted || updated.id != me.id) return;
          await ref.read(directMessageThreadsProvider.notifier).refresh();
          if (!context.mounted) return;
          ref.read(inboxCountsRefreshKeyProvider.notifier).state++;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Email verified. You can now send messages.'),
            ),
          );
        } catch (error) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(friendlyErrorMessage(error))),
            );
          }
        }
      },
    );
  }
}

final unreadDirectMessageThreadCountProvider = Provider<int>((ref) {
  final blockedUserIds = ref.watch(blockedUserIdsProvider);
  return ref
      .watch(directMessageThreadsProvider)
      .where(
        (thread) =>
            !thread.requestDeclined &&
            !_isBlockedThread(thread, blockedUserIds),
      )
      .fold(0, (count, thread) => count + thread.unreadCount);
});

final dmSharedEventRsvpProvider = StateProvider<Set<String>>((ref) => {});
final dmSocialProfilesProvider = FutureProvider.autoDispose((ref) {
  ref.watch(socialRefreshKeyProvider);
  return ref.watch(surfRepositoryProvider).fetchSocialProfiles();
});

final joinedEventChatsProvider =
    FutureProvider.autoDispose<List<JoinedEventChatSummary>>((ref) async {
      ref.watch(socialRefreshKeyProvider);
      final repository = ref.watch(surfRepositoryProvider);
      final posts = await repository.fetchEventChatPosts();
      final chats = posts.map(JoinedEventChatSummary.fromPost).toList();
      chats.sort((a, b) => a.sortDate.compareTo(b.sortDate));
      return chats;
    });

class JoinedEventChatSummary {
  const JoinedEventChatSummary({
    required this.postId,
    required this.title,
    required this.hostName,
    required this.meetupDate,
    required this.sortDate,
  });

  final String postId;
  final String title;
  final String hostName;
  final String? meetupDate;
  final DateTime sortDate;

  factory JoinedEventChatSummary.fromPost(SocialPostModel post) {
    final title = post.body.trim();
    final parsedDate = DateTime.tryParse(post.meetupDate ?? '');
    return JoinedEventChatSummary(
      postId: post.id,
      title: title.isEmpty ? 'Event group chat' : title,
      hostName: post.authorName,
      meetupDate: post.meetupDate,
      sortDate: parsedDate ?? DateTime(9999),
    );
  }
}

class DirectMessageThreadsNotifier
    extends StateNotifier<List<DirectMessageThread>> {
  DirectMessageThreadsNotifier({
    required DirectMessageApi api,
    required this.ownerId,
    required void Function(AsyncValue<void>) onStatus,
    required VoidCallback onCountsChanged,
  }) : _api = api,
       _onStatus = onStatus,
       _onCountsChanged = onCountsChanged,
       super(const []) {
    if (ownerId != null) {
      Future.microtask(() => refresh().catchError((Object _) {}));
    }
  }

  @visibleForTesting
  DirectMessageThreadsNotifier.testing(super.threads)
    : _api = null,
      ownerId = 'test-owner',
      _onStatus = null,
      _onCountsChanged = null;

  final DirectMessageApi? _api;
  final String? ownerId;
  final void Function(AsyncValue<void>)? _onStatus;
  final VoidCallback? _onCountsChanged;
  Future<DirectMessageSession>? _session;
  bool _disposed = false;
  bool _refreshing = false;
  int _revision = 0;
  final Map<String, String> _sendKeys = {};
  final Set<String> _sending = {};

  Future<DirectMessageSession> _connected() {
    if (_disposed || ownerId == null || _api == null) {
      throw StateError('Please sign in to use messages.');
    }
    return _session ??= _api.openSession(ownerId!).catchError((Object error) {
      _session = null;
      throw error;
    });
  }

  void _check() {
    if (_disposed) throw StateError('Your account changed. Reopen Messages.');
  }

  DirectMessageThread _fromServer(Map<String, dynamic> json) {
    final id = json['id'];
    final peerId = json['peer_user_id'];
    if (id is! String ||
        id.isEmpty ||
        peerId is! String ||
        peerId.isEmpty ||
        peerId == ownerId) {
      throw StateError('The conversation response was incomplete.');
    }
    final previous = threadByIdOrHandle(id);
    final name = json['peer_name'] as String? ?? 'Tydes surfer';
    return DirectMessageThread(
      id: id,
      profileUserId: peerId,
      name: name,
      handle: json['peer_handle'] as String? ?? '',
      initial: _initialFor(name),
      location: 'Tydes',
      preview: json['preview'] as String? ?? '',
      time: _messageTime(json['updated_at'] as String?),
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
      avatarUrl: json['peer_avatar_url'] as String?,
      premium: json['peer_premium'] as bool? ?? false,
      online: false,
      requestAccepted: json['request_accepted'] as bool? ?? false,
      requestDeclined: json['request_declined'] as bool? ?? false,
      messages: json['messages'] is List
          ? (json['messages'] as List)
                .map(
                  (raw) => DirectChatMessage.fromServer(
                    Map<String, dynamic>.from(raw as Map),
                    ownerId!,
                  ),
                )
                .toList()
          : previous?.messages ?? const [],
    );
  }

  void _accept(DirectMessageThread thread) {
    _check();
    state = [thread, ...state.where((item) => item.id != thread.id)]
      ..sort(
        (a, b) => (b.updatedAt ?? DateTime(1970)).compareTo(
          a.updatedAt ?? DateTime(1970),
        ),
      );
    _revision++;
  }

  Future<void> refresh() async {
    if (_api == null) return; // Explicit widget-test fixture only.
    if (_refreshing) return;
    _refreshing = true;
    _onStatus?.call(const AsyncLoading());
    final revision = _revision;
    try {
      final items = await (await _connected()).threads();
      _check();
      // A slower inbox response must not overwrite a just-confirmed send/read.
      if (revision == _revision) state = items.map(_fromServer).toList();
      _onStatus?.call(const AsyncData(null));
      _onCountsChanged?.call();
    } catch (error, stack) {
      if (!_disposed) _onStatus?.call(AsyncError(error, stack));
      rethrow;
    } finally {
      _refreshing = false;
    }
  }

  Future<DirectMessageThread> ensureThreadForProfile(
    PublicProfilePreview profile,
  ) async {
    final result = await (await _connected()).ensureThread(profile.userId);
    _check();
    final thread = _fromServer(result);
    if (thread.profileUserId != profile.userId) {
      throw StateError('The server returned a different conversation.');
    }
    _accept(thread);
    _onCountsChanged?.call();
    return thread;
  }

  Future<DirectMessageThread> loadThread(String threadId) async {
    final revision = _revision;
    final result = await (await _connected()).thread(threadId);
    _check();
    if (revision != _revision) {
      final current = threadByIdOrHandle(threadId);
      if (current != null) return current;
    }
    final thread = _fromServer(result);
    _accept(thread);
    return thread;
  }

  Future<void> markRead(String threadId) async {
    final thread = threadByIdOrHandle(threadId);
    if (thread == null) return;
    final incoming = thread.messages.where(
      (message) => !message.isMe && message.id != null,
    );
    if (incoming.isEmpty) return;
    final marker = incoming.last.id!;
    final remaining = await (await _connected()).markRead(thread.id, marker);
    _check();
    final latest = threadByIdOrHandle(thread.id);
    final latestMarker = latest?.messages
        .where((message) => !message.isMe && message.id != null)
        .lastOrNull
        ?.id;
    if (latest != null && latestMarker == marker) {
      _accept(latest.copyWith(unreadCount: remaining));
    }
    _onCountsChanged?.call();
  }

  Future<void> sendMessage(String threadId, String text) =>
      _send(threadId, text.trim());

  Future<void> sendSharedPost({
    required String threadId,
    required SocialPostModel post,
    required String? spotName,
    required String? note,
  }) => _send(threadId, note?.trim() ?? '', sharedPostId: post.id);

  Future<void> _send(
    String threadId,
    String text, {
    String? sharedPostId,
  }) async {
    if (text.isEmpty && sharedPostId == null) return;
    if (text.length > 1600) {
      throw StateError('Messages can be up to 1600 characters.');
    }
    if (_sending.contains(threadId)) {
      throw StateError('This message is still sending.');
    }
    final fingerprint = '$threadId\u0000$text\u0000${sharedPostId ?? ''}';
    final key = _sendKeys.putIfAbsent(
      fingerprint,
      () => 'dm_${DateTime.now().microsecondsSinceEpoch}_${_sendKeys.length}',
    );
    _sending.add(threadId);
    try {
      final ack = await (await _connected()).send(
        threadId: threadId,
        text: text,
        clientMessageId: key,
        sharedPostId: sharedPostId,
      );
      _check();
      final current = threadByIdOrHandle(threadId);
      if (current == null) {
        throw StateError('Reopen this conversation and try again.');
      }
      final message = DirectChatMessage.fromServer(ack, ownerId!);
      _accept(
        current.copyWith(
          preview: message.text.isNotEmpty ? message.text : 'Shared a post',
          time: _messageTime(ack['created_at'] as String?),
          updatedAt: DateTime.tryParse(ack['created_at'] as String? ?? ''),
          messages: [
            ...current.messages.where((item) => item.id != message.id),
            message,
          ],
        ),
      );
      _sendKeys.remove(fingerprint);
      _onCountsChanged?.call();
    } finally {
      _sending.remove(threadId);
    }
  }

  Future<void> sendAttachment({
    required String threadId,
    required String path,
    required String type,
  }) async {
    throw StateError(
      'Private photo and video messages are not available yet. You can send text or share a post.',
    );
  }

  Future<void> acceptRequest(String threadId) =>
      _requestStatus(threadId, accepted: true);
  Future<void> declineRequest(String threadId) =>
      _requestStatus(threadId, declined: true);
  Future<void> hideThread(String threadId) => declineRequest(threadId);

  Future<void> _requestStatus(
    String threadId, {
    bool? accepted,
    bool? declined,
  }) async {
    final result = await (await _connected()).requestStatus(
      threadId,
      accepted: accepted,
      declined: declined,
    );
    _check();
    _accept(_fromServer(result));
    _onCountsChanged?.call();
  }

  DirectMessageThread? threadByIdOrHandle(String value) {
    final normalized = _normalizeThreadId(value);
    return state
        .where(
          (thread) =>
              thread.id == value ||
              thread.profileUserId == value ||
              _normalizeThreadId(thread.handle) == normalized,
        )
        .firstOrNull;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

String _messageTime(String? value) {
  final parsed = DateTime.tryParse(value ?? '')?.toLocal();
  if (parsed == null) return '';
  final diff = DateTime.now().difference(parsed);
  if (diff.inMinutes < 1) return 'Now';
  if (diff.inHours < 1) return '${diff.inMinutes}m';
  if (diff.inDays < 1) return '${diff.inHours}h';
  return '${parsed.day}/${parsed.month}';
}

class DirectMessagesPage extends ConsumerStatefulWidget {
  const DirectMessagesPage({super.key, this.initialThreadId, this.seedProfile});

  final String? initialThreadId;
  final PublicProfilePreview? seedProfile;

  @override
  ConsumerState<DirectMessagesPage> createState() => _DirectMessagesPageState();
}

class _DirectMessagesPageState extends ConsumerState<DirectMessagesPage>
    with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  Timer? _poll;
  bool _foreground = true;
  bool _openingInitial = false;
  String? _openedInitialId;
  Object? _initialError;

  Future<void> _refreshInbox() async {
    // Recover a failed account lookup before resolving its account-scoped
    // inbox. A same-account profile refresh retains the notifier and drafts.
    final account = await ref.refresh(meProvider.future);
    if (!mounted || ref.read(meProvider).valueOrNull?.id != account.id) {
      return;
    }
    await Future.wait([
      ref.read(directMessageThreadsProvider.notifier).refresh(),
      ref.refresh(joinedEventChatsProvider.future),
      ref.refresh(socialRelationshipHydrationProvider.future),
    ]);
    if (mounted && widget.initialThreadId != null && _initialError != null) {
      await _openInitialConversation();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _poll = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!mounted ||
          !_foreground ||
          widget.initialThreadId != null ||
          ref.read(meProvider).hasError ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      unawaited(
        ref
            .read(directMessageThreadsProvider.notifier)
            .refresh()
            .catchError((Object _) {}),
      );
    });
    if (widget.initialThreadId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openInitialConversation();
      });
    }
  }

  Future<void> _openInitialConversation({bool reloadAccount = false}) async {
    if (_openingInitial) return;
    setState(() {
      _openingInitial = true;
      _initialError = null;
    });
    try {
      final account = reloadAccount
          ? await ref.refresh(meProvider.future)
          : await ref.read(meProvider.future);
      if (!mounted || ref.read(meProvider).valueOrNull?.id != account.id) {
        return;
      }
      final controller = ref.read(directMessageThreadsProvider.notifier);
      final profile = widget.seedProfile;
      final thread = profile == null
          ? await controller.loadThread(widget.initialThreadId!)
          : await controller.ensureThreadForProfile(profile);
      if (mounted) setState(() => _openedInitialId = thread.id);
    } catch (error) {
      if (mounted) setState(() => _initialError = error);
    } finally {
      if (mounted) setState(() => _openingInitial = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _foreground = state == AppLifecycleState.resumed;

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider);
    final threads = ref.watch(directMessageThreadsProvider);
    if (me.hasError) {
      return Scaffold(
        appBar: AppBar(title: const Text('Messages')),
        body: FeedRefreshIndicator(
          onRefresh: _refreshInbox,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(24),
            children: [
              const Text('Could not load your account'),
              const SizedBox(height: 8),
              Text(friendlyErrorMessage(me.error)),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _refreshInbox().catchError((Object _) {}),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (!me.hasValue) {
      return Scaffold(
        appBar: AppBar(title: const Text('Messages')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final inboxStatus = ref.watch(dmInboxStatusProvider);
    final eventChats = ref.watch(joinedEventChatsProvider);
    final followedUserIds = ref.watch(followedUserIdsProvider);
    final hiddenFollowingUserIds = ref.watch(hiddenFollowingUserIdsProvider);
    final blockedUserIds = ref.watch(blockedUserIdsProvider);
    final initialThreadId = widget.initialThreadId;
    if (initialThreadId != null && initialThreadId.isNotEmpty) {
      if (_initialError != null) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Messages'),
            actions: const [_VerifyEmailAction()],
          ),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    friendlyLoadErrorMessage(
                      _initialError,
                      label: 'this conversation',
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () =>
                        _openInitialConversation(reloadAccount: true),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      final thread = _threadByIdOrHandle(
        threads,
        _openedInitialId ?? initialThreadId,
      );
      if (thread == null) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return _DirectChatPage(threadId: thread.id);
    }

    final visibleThreads = threads
        .where(
          (thread) =>
              !thread.requestDeclined &&
              !_isBlockedThread(thread, blockedUserIds),
        )
        .toList();
    final primaryThreads = visibleThreads
        .where(
          (thread) =>
              thread.requestAccepted ||
              _isFollowingThread(
                thread,
                followedUserIds,
                hiddenFollowingUserIds,
              ),
        )
        .toList();
    final requestThreads = visibleThreads
        .where(
          (thread) =>
              !thread.requestAccepted &&
              !_isFollowingThread(
                thread,
                followedUserIds,
                hiddenFollowingUserIds,
              ),
        )
        .toList();

    final filteredThreads = primaryThreads.where((thread) {
      final haystack = '${thread.name} ${thread.handle} ${thread.location}'
          .toLowerCase();
      return haystack.contains(_query.toLowerCase());
    }).toList();
    final filteredEventChats = (eventChats.valueOrNull ?? const []).where((
      chat,
    ) {
      final haystack = '${chat.title} ${chat.hostName}'.toLowerCase();
      return haystack.contains(_query.toLowerCase());
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
        actions: [
          const _VerifyEmailAction(),
          IconButton(
            onPressed: () => _openNewMessageSheet(context, ref),
            icon: const Icon(Icons.edit_square),
            tooltip: 'New message',
          ),
        ],
      ),
      body: FeedRefreshIndicator(
        onRefresh: _refreshInbox,
        child: ListView(
          key: const PageStorageKey('messages-inbox'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            _SearchField(
              controller: _searchController,
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 18),
            if (inboxStatus.isLoading && threads.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (inboxStatus.hasError)
              ListTile(
                title: const Text('Could not refresh messages'),
                subtitle: Text(friendlyErrorMessage(inboxStatus.error)),
                trailing: TextButton(
                  onPressed: () => _refreshInbox().catchError((Object _) {}),
                  child: const Text('Retry'),
                ),
              ),
            if (eventChats.isLoading && !eventChats.hasValue)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (eventChats.hasError)
              ListTile(
                title: const Text('Could not load event chats'),
                trailing: TextButton(
                  onPressed: () => ref.invalidate(joinedEventChatsProvider),
                  child: const Text('Retry'),
                ),
              ),
            if (filteredEventChats.isNotEmpty) ...[
              Text(
                'Event chats',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              ...filteredEventChats.map(
                (chat) => _EventChatThreadTile(
                  chat: chat,
                  onTap: () => context.push('/event/${chat.postId}/chat'),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Text('Primary', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          _MessageRequestsPage(requestThreads: requestThreads),
                    ),
                  ),
                  child: Text(
                    requestThreads.isEmpty
                        ? 'Requests'
                        : 'Requests ${requestThreads.length}',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (filteredThreads.isEmpty)
              const _EmptyMessagesCard()
            else
              ...filteredThreads.map(
                (thread) => _MessageThreadTile(
                  thread: thread,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _DirectChatPage(threadId: thread.id),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EventChatThreadTile extends StatelessWidget {
  const _EventChatThreadTile({required this.chat, required this.onTap});

  final JoinedEventChatSummary chat;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            const CircleAvatar(
              radius: 29,
              backgroundColor: Color(0xFFD7EFEC),
              child: Icon(
                Icons.groups_2_outlined,
                color: Color(0xFF087E7A),
                size: 28,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chat.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Event group chat • ${chat.hostName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (chat.meetupDate != null) ...[
                    const SizedBox(height: 5),
                    Text(
                      _eventChatDateLabel(chat.meetupDate!),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              Icons.chevron_right,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

String _eventChatDateLabel(String value) {
  final date = DateTime.tryParse(value);
  if (date == null) return 'Upcoming event';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[date.month - 1]} ${date.day}';
}

String _normalizeThreadId(String value) {
  var normalized = value.trim().toLowerCase();
  if (normalized.startsWith('friend_')) {
    normalized = normalized.substring('friend_'.length);
  }
  if (normalized.startsWith('suggested_')) {
    normalized = normalized.substring('suggested_'.length);
  }
  if (normalized.startsWith('random_')) {
    normalized = normalized.substring('random_'.length);
  }
  return normalized.replaceAll(RegExp(r'[^a-z0-9_]+'), '');
}

DirectMessageThread? _threadByIdOrHandle(
  List<DirectMessageThread> threads,
  String value,
) {
  final normalized = _normalizeThreadId(value);
  for (final thread in threads) {
    if (thread.id == value ||
        thread.id == normalized ||
        thread.handle == normalized) {
      return thread;
    }
  }
  return null;
}

bool _isFollowingThread(
  DirectMessageThread thread,
  Set<String> followedUserIds,
  Set<String> hiddenFollowingUserIds,
) {
  final threadKeys = {
    _normalizeThreadId(thread.id),
    _normalizeThreadId(thread.handle),
  };
  final hiddenKeys = hiddenFollowingUserIds.map(_normalizeThreadId).toSet();
  if (threadKeys.any(hiddenKeys.contains)) return false;

  final followedKeys = followedUserIds.map(_normalizeThreadId).toSet();
  if (threadKeys.any(followedKeys.contains)) return true;
  return threadKeys.any(_defaultFollowingThreadIds.contains);
}

bool _isBlockedThread(DirectMessageThread thread, Set<String> blockedUserIds) {
  final blockedKeys = blockedUserIds.map(_normalizeThreadId).toSet();
  final threadKeys = {
    _normalizeThreadId(thread.id),
    _normalizeThreadId(thread.handle),
    if (thread.profileUserId?.trim().isNotEmpty ?? false)
      _normalizeThreadId(thread.profileUserId!),
  };
  return threadKeys.any(blockedKeys.contains);
}

const _defaultFollowingThreadIds = <String>{};

String _initialFor(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  return trimmed.characters.first.toUpperCase();
}

PublicProfilePreview _profileFromThread(DirectMessageThread thread) {
  final match = _messageableProfiles
      .where(
        (profile) =>
            _normalizeThreadId(profile.userId) == thread.id ||
            _normalizeThreadId(profile.handle ?? '') == thread.handle,
      )
      .firstOrNull;
  if (match != null) return match;

  return PublicProfilePreview(
    userId: thread.profileUserId?.trim().isNotEmpty == true
        ? thread.profileUserId!
        : thread.id,
    displayName: thread.name,
    handle: thread.handle,
    subtitle: 'Surf traveler on Tydes',
    location: thread.location,
    avatarUrl: thread.avatarUrl,
    premium: thread.premium,
  );
}

Future<void> _openNewMessageSheet(BuildContext context, WidgetRef ref) async {
  ref.invalidate(dmSocialProfilesProvider);
  final profile = await showModalBottomSheet<PublicProfilePreview>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _NewMessageSheet(),
  );
  if (profile == null || !context.mounted) return;
  DirectMessageThread thread;
  try {
    thread = await ref
        .read(directMessageThreadsProvider.notifier)
        .ensureThreadForProfile(profile);
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(friendlyErrorMessage(error))));
    }
    return;
  }
  if (!context.mounted) return;
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _DirectChatPage(threadId: thread.id),
    ),
  );
}

class _NewMessageSheet extends ConsumerStatefulWidget {
  const _NewMessageSheet();

  @override
  ConsumerState<_NewMessageSheet> createState() => _NewMessageSheetState();
}

class _NewMessageSheetState extends ConsumerState<_NewMessageSheet> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase().replaceFirst('@', '');
    final realProfiles = ref.watch(dmSocialProfilesProvider);
    ref.watch(socialRelationshipHydrationProvider);
    final blockedUserIds = ref.watch(blockedUserIdsProvider);
    final profiles = _filteredMessageableProfiles(
      realProfiles: realProfiles.valueOrNull ?? const [],
      fallbackProfiles: _messageableProfiles,
      blockedUserIds: blockedUserIds,
      query: q,
    );

    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.42,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
          ),
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              Text(
                'New message',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              _SearchField(
                controller: _controller,
                onChanged: (value) => setState(() => _query = value),
                hintText: 'Search people',
              ),
              const SizedBox(height: 16),
              Text('People', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              if (realProfiles.isLoading && profiles.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (realProfiles.hasError && profiles.isEmpty)
                _MessagePeopleErrorCard(
                  onRetry: () => ref.invalidate(dmSocialProfilesProvider),
                )
              else if (profiles.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(18),
                    child: Text('No people found.'),
                  ),
                )
              else
                ...profiles.map(
                  (profile) => _NewMessagePersonTile(profile: profile),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _MessagePeopleErrorCard extends StatelessWidget {
  const _MessagePeopleErrorCard({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Could not load people right now.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Try again and we will reload the real Tydes accounts.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

List<PublicProfilePreview> _filteredMessageableProfiles({
  required List<SocialProfileModel> realProfiles,
  required List<PublicProfilePreview> fallbackProfiles,
  required Set<String> blockedUserIds,
  required String query,
}) {
  final ranked = <String, _RankedMessageProfile>{};

  void addProfile(PublicProfilePreview profile, int priority) {
    if (profile.userId == 'usr_demo') return;
    if (blockedUserIds.contains(profile.userId)) return;
    final handle = _normalizeMessageSearch(profile.handle ?? '');
    final key = handle.isEmpty ? 'id:${profile.userId}' : 'handle:$handle';
    final existing = ranked[key];
    if (existing == null || priority > existing.priority) {
      ranked[key] = _RankedMessageProfile(profile, priority);
    }
  }

  for (final profile in fallbackProfiles) {
    addProfile(profile, 5);
  }
  for (final profile in realProfiles) {
    addProfile(
      PublicProfilePreview(
        userId: profile.userId,
        displayName: profile.displayName,
        handle: profile.handle,
        avatarUrl: profile.avatarUrl,
        coverUrl: profile.coverUrl,
        premium: profile.premium,
        subtitle: profile.subtitle,
        location: profile.location,
        surfSkill: profile.surfSkill ?? 'beginner',
      ),
      50,
    );
  }

  final profiles = ranked.values.map((item) => item.profile).where((profile) {
    if (query.isEmpty) return true;
    final handle = _normalizeMessageSearch(profile.handle ?? '');
    final name = _normalizeMessageSearch(profile.displayName);
    final location = _normalizeMessageSearch(profile.location ?? '');
    return handle.contains(query) ||
        name.contains(query) ||
        location.contains(query);
  }).toList();

  profiles.sort((a, b) {
    if (query.isNotEmpty) {
      final aHandle = _normalizeMessageSearch(a.handle ?? '');
      final bHandle = _normalizeMessageSearch(b.handle ?? '');
      final exactCompare = _boolRank(
        bHandle == query,
      ).compareTo(_boolRank(aHandle == query));
      if (exactCompare != 0) return exactCompare;
      final startsCompare = _boolRank(
        bHandle.startsWith(query),
      ).compareTo(_boolRank(aHandle.startsWith(query)));
      if (startsCompare != 0) return startsCompare;
    }
    return a.displayName.compareTo(b.displayName);
  });

  return profiles.take(query.isEmpty ? 16 : 30).toList();
}

class _RankedMessageProfile {
  const _RankedMessageProfile(this.profile, this.priority);

  final PublicProfilePreview profile;
  final int priority;
}

String _normalizeMessageSearch(String value) {
  return value.trim().toLowerCase().replaceFirst(RegExp(r'^@+'), '');
}

int _boolRank(bool value) => value ? 1 : 0;

class _NewMessagePersonTile extends StatelessWidget {
  const _NewMessagePersonTile({required this.profile});

  final PublicProfilePreview profile;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: () => Navigator.of(context).pop(profile),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            TydesProfileAvatar(
              size: 50,
              displayName: profile.displayName,
              imageUrl: profile.avatarUrl,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  Text(
                    '@${profile.handle ?? profile.userId} • ${profile.location ?? 'Tydes'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.onChanged,
    this.hintText = 'Search messages',
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: hintText,
        prefixIcon: const Icon(Icons.search),
        filled: true,
        fillColor: Theme.of(context).cardColor,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(22),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _MessageThreadTile extends StatelessWidget {
  const _MessageThreadTile({required this.thread, required this.onTap});

  final DirectMessageThread thread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            _ThreadAvatar(thread: thread, radius: 29),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          thread.name,
                          style: TextStyle(
                            fontWeight: thread.unreadCount > 0
                                ? FontWeight.w900
                                : FontWeight.w700,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        thread.time,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '@${thread.handle} - ${thread.location}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    thread.preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: thread.unreadCount > 0
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant,
                      fontWeight: thread.unreadCount > 0
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (thread.unreadCount > 0)
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  thread.unreadCount.toString(),
                  style: TextStyle(
                    color: theme.colorScheme.onPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              )
            else
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
              ),
          ],
        ),
      ),
    );
  }
}

class _DirectChatPage extends ConsumerStatefulWidget {
  const _DirectChatPage({
    required this.threadId,
    this.showRequestActions = false,
  });

  final String threadId;
  final bool showRequestActions;

  @override
  ConsumerState<_DirectChatPage> createState() => _DirectChatPageState();
}

class _DirectChatPageState extends ConsumerState<_DirectChatPage>
    with WidgetsBindingObserver {
  final TextEditingController _messageController = TextEditingController();
  Timer? _poll;
  bool _foreground = true;
  bool _loading = true;
  bool _loadingRequest = false;
  bool _sending = false;
  bool _requestBusy = false;
  bool _readPending = false;
  String? _lastReadMessageId;
  Object? _loadError;
  late final String? _chatOwnerId;

  @override
  void initState() {
    super.initState();
    _chatOwnerId = ref.read(directMessageThreadsProvider.notifier).ownerId;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadConversation();
    });
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_isVisible) _loadConversation();
    });
  }

  bool get _isVisible =>
      mounted &&
      _foreground &&
      ref.read(directMessageThreadsProvider.notifier).ownerId == _chatOwnerId &&
      ModalRoute.of(context)?.isCurrent == true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && mounted) _loadConversation();
  }

  Future<void> _loadConversation() async {
    if (_loadingRequest || !_isVisible) return;
    _loadingRequest = true;
    try {
      await ref
          .read(directMessageThreadsProvider.notifier)
          .loadThread(widget.threadId);
      if (mounted) setState(() => _loadError = null);
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    } finally {
      _loadingRequest = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _markVisibleRead(String messageId) async {
    if (!_isVisible || _readPending || _lastReadMessageId == messageId) return;
    _readPending = true;
    try {
      await ref
          .read(directMessageThreadsProvider.notifier)
          .markRead(widget.threadId);
      if (mounted) _lastReadMessageId = messageId;
    } catch (_) {
      // A failed acknowledgement must leave server unread counts intact.
    } finally {
      _readPending = false;
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(directMessageThreadsProvider.notifier).ownerId !=
        _chatOwnerId) {
      return Scaffold(
        appBar: AppBar(title: const Text('Messages')),
        body: const Center(
          child: Text('Your account changed. Reopen Messages to continue.'),
        ),
      );
    }
    final thread = _threadByIdOrHandle(
      ref.watch(directMessageThreadsProvider),
      widget.threadId,
    );
    if (thread == null) {
      return const Scaffold(body: Center(child: Text('Chat not found.')));
    }
    final incoming = thread.messages.where(
      (message) => !message.isMe && message.id != null,
    );
    if (thread.unreadCount > 0 && incoming.isNotEmpty) {
      final marker = incoming.last.id!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _markVisibleRead(marker);
      });
    }
    final isRequest = !thread.requestAccepted;
    final profile = _profileFromThread(thread);
    final isBlocked = _isBlockedThread(
      thread,
      ref.watch(blockedUserIdsProvider),
    );

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () =>
              context.push('/profile/${profile.userId}', extra: profile),
          child: Row(
            children: [
              _ThreadAvatar(thread: thread, radius: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      thread.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      thread.online ? 'Active now' : '@${thread.handle}',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          const _VerifyEmailAction(),
          if (!isBlocked &&
              ref.watch(meProvider).valueOrNull?.emailVerified != false)
            Padding(
              padding: const EdgeInsets.only(right: 2),
              child: Center(
                child: FollowButton(userId: profile.userId, compact: true),
              ),
            ),
          _DirectChatSafetyMenu(thread: thread, profile: profile),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading && thread.messages.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: thread.messages.length,
                    itemBuilder: (context, index) {
                      final message =
                          thread.messages[thread.messages.length - 1 - index];
                      return _MessageBubble(message: message);
                    },
                  ),
          ),
          if (_loadError != null)
            ListTile(
              dense: true,
              title: Text(
                friendlyLoadErrorMessage(_loadError, label: 'new messages'),
              ),
              trailing: TextButton(
                onPressed: _loadConversation,
                child: const Text('Retry'),
              ),
            ),
          if (isBlocked)
            _BlockedDirectThreadNotice(profile: profile)
          else if (isRequest)
            _MessageRequestActions(
              thread: thread,
              busy: _requestBusy,
              onAccept: () => _changeRequest(thread.id, true),
              onDecline: () => _changeRequest(thread.id, false),
            )
          else
            _MessageComposer(
              controller: _messageController,
              sending: _sending,
              onSend: () => _sendMessage(thread.id),
              onAddAttachment: () => _openAttachmentSheet(thread.id),
            ),
        ],
      ),
    );
  }

  Future<void> _openAttachmentSheet(String threadId) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Private photo and video messages are not available yet. Send text or share a post instead.',
        ),
      ),
    );
  }

  Future<void> _changeRequest(String threadId, bool accept) async {
    if (_requestBusy) return;
    setState(() => _requestBusy = true);
    try {
      final notifier = ref.read(directMessageThreadsProvider.notifier);
      if (accept) {
        await notifier.acceptRequest(threadId);
      } else {
        await notifier.declineRequest(threadId);
        if (mounted) Navigator.of(context).pop();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendlyErrorMessage(error))));
      }
    } finally {
      if (mounted) setState(() => _requestBusy = false);
    }
  }

  Future<void> _sendMessage(String threadId) async {
    if (_sending) return;
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    if (hasBlockedContent(text)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text(contentBlockedMessage)));
      return;
    }
    setState(() => _sending = true);
    try {
      await ref
          .read(directMessageThreadsProvider.notifier)
          .sendMessage(threadId, text);
      if (mounted && _messageController.text.trim() == text) {
        _messageController.clear();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Message not sent. ${friendlyErrorMessage(error)}'),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => _sendMessage(threadId),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }
}

enum _DirectChatSafetyAction { report, block }

class _DirectChatSafetyMenu extends ConsumerWidget {
  const _DirectChatSafetyMenu({required this.thread, required this.profile});

  final DirectMessageThread thread;
  final PublicProfilePreview profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<_DirectChatSafetyAction>(
      tooltip: 'Chat options',
      icon: const Icon(Icons.more_horiz_rounded),
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _DirectChatSafetyAction.report,
          child: Text('Report conversation'),
        ),
        PopupMenuItem(
          value: _DirectChatSafetyAction.block,
          child: Text('Block surfer'),
        ),
      ],
      onSelected: (action) {
        switch (action) {
          case _DirectChatSafetyAction.report:
            unawaited(_reportDirectThread(context, ref, thread, profile));
          case _DirectChatSafetyAction.block:
            unawaited(
              _confirmAndBlockDirectProfile(context, ref, thread, profile),
            );
        }
      },
    );
  }
}

Future<void> _reportDirectThread(
  BuildContext context,
  WidgetRef ref,
  DirectMessageThread thread,
  PublicProfilePreview profile,
) async {
  try {
    await ref
        .read(surfRepositoryProvider)
        .reportSocialContent(
          targetType: 'message_thread',
          targetId: thread.id,
          reason:
              'Conversation report with @${profile.handle ?? thread.handle}',
        );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Report sent. Thanks for helping Tydes.')),
    );
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not report this conversation right now.'),
      ),
    );
  }
}

Future<void> _confirmAndBlockDirectProfile(
  BuildContext context,
  WidgetRef ref,
  DirectMessageThread thread,
  PublicProfilePreview profile,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Block ${profile.displayName}?'),
      content: const Text(
        'You will not see their messages, posts, or profile in Tydes. You can undo this later from safety settings.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Block'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  await blockSocialUser(ref, profile.userId);
  // Blocking is enforced by the server and must not invent a local delivery state.
  await ref
      .read(directMessageThreadsProvider.notifier)
      .refresh()
      .catchError((Object _) {});
  ref.invalidate(dmSocialProfilesProvider);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('@${profile.handle ?? profile.displayName} blocked.'),
    ),
  );
  if (Navigator.of(context).canPop()) {
    Navigator.of(context).pop();
  }
}

class _BlockedDirectThreadNotice extends StatelessWidget {
  const _BlockedDirectThreadNotice({required this.profile});

  final PublicProfilePreview profile;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(Icons.block_rounded),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '@${profile.handle ?? profile.displayName} is blocked. Their messages are hidden from your inbox.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final DirectChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final alignment = message.isMe
        ? Alignment.centerRight
        : Alignment.centerLeft;
    final color = message.isMe ? theme.colorScheme.primary : theme.cardColor;
    final textColor = message.isMe
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;
    final hasMedia = message.mediaPath != null;
    final isSharedPost = message.sharedPostId != null;

    return Align(
      alignment: alignment,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth:
                MediaQuery.sizeOf(context).width * (isSharedPost ? 0.9 : 0.76),
          ),
          child: Column(
            crossAxisAlignment: message.isMe
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Container(
                padding: isSharedPost
                    ? EdgeInsets.zero
                    : const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: isSharedPost
                      ? Colors.transparent
                      : hasMedia
                      ? theme.cardColor
                      : color,
                  borderRadius: isSharedPost
                      ? BorderRadius.zero
                      : BorderRadius.only(
                          topLeft: const Radius.circular(20),
                          topRight: const Radius.circular(20),
                          bottomLeft: Radius.circular(message.isMe ? 20 : 6),
                          bottomRight: Radius.circular(message.isMe ? 6 : 20),
                        ),
                ),
                child: _MessageContent(
                  message: message,
                  textColor: isSharedPost || hasMedia
                      ? theme.colorScheme.onSurface
                      : textColor,
                ),
              ),
              if (hasMedia && message.isMe) ...[
                const SizedBox(height: 2),
                Text(
                  'Sent',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
              const SizedBox(height: 3),
              Text(
                message.time,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageContent extends StatelessWidget {
  const _MessageContent({required this.message, required this.textColor});

  final DirectChatMessage message;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final mediaPath = message.mediaPath;
    final hasText = message.text.trim().isNotEmpty;
    final children = <Widget>[];

    if (message.sharedPostId != null) {
      children.add(_SharedPostPreview(message: message));
    }

    if (mediaPath != null) {
      if (message.mediaType == 'image') {
        children.add(_ImageAttachmentPreview(path: mediaPath));
      } else {
        children.add(_VideoAttachmentPreview(path: mediaPath));
      }
    }

    if (hasText) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 8));
      if (message.sharedPostId != null) {
        final scheme = Theme.of(context).colorScheme;
        children.add(
          Align(
            alignment: message.isMe
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: message.isMe
                    ? scheme.primary
                    : Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(
                message.text,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: message.isMe ? scheme.onPrimary : scheme.onSurface,
                  height: 1.28,
                ),
              ),
            ),
          ),
        );
      } else {
        children.add(
          Text(
            message.text,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: textColor, height: 1.28),
          ),
        );
      }
    }

    if (children.isEmpty) {
      children.add(
        Text(
          message.mediaType == 'video' ? 'Video attachment' : 'Photo',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: textColor, height: 1.28),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: message.isMe && message.sharedPostId != null
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: children,
    );
  }
}

class _SharedPostPreview extends ConsumerWidget {
  const _SharedPostPreview({required this.message});

  final DirectChatMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final mediaUrl = message.sharedPostMediaUrl;
    final isEvent = message.sharedPostType == 'event';
    final eventRsvps = ref.watch(dmSharedEventRsvpProvider);
    final joined = eventRsvps.contains(message.sharedPostId);

    return InkWell(
      onTap: message.sharedPostAuthorUserId == null
          ? null
          : () => _openSharedPostProfile(context, message),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: MediaQuery.sizeOf(context).width * 0.72,
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          isEvent ? 'Event' : 'Post',
                          style: TextStyle(
                            color: scheme.primary,
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      const Spacer(),
                      if (message.sharedPostAuthorUserId != null)
                        _MiniFollowButton(
                          userId: message.sharedPostAuthorUserId!,
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      TydesProfileAvatar(
                        size: 32,
                        displayName: message.sharedPostAuthor ?? 'Surfer',
                        imageUrl: message.sharedPostAuthorAvatarUrl,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    message.sharedPostAuthor ?? 'Tydes surfer',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                                if (message.sharedPostAuthorPremium) ...[
                                  const SizedBox(width: 5),
                                  Icon(
                                    Icons.verified_rounded,
                                    size: 15,
                                    color: scheme.primary,
                                  ),
                                ],
                              ],
                            ),
                            if ((message.sharedPostAuthorHandle ?? '')
                                .isNotEmpty)
                              Text(
                                '@${message.sharedPostAuthorHandle}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 11,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (message.sharedPostSpotName != null)
                        _SharedSpotButton(message: message),
                    ],
                  ),
                  if (mediaUrl != null) ...[
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: AspectRatio(
                        aspectRatio: 16 / 10,
                        child: Image.network(
                          mediaUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              Container(
                                color: scheme.surfaceContainerHighest,
                                alignment: Alignment.center,
                                child: const Icon(
                                  Icons.image_not_supported_outlined,
                                ),
                              ),
                        ),
                      ),
                    ),
                  ],
                  if ((message.sharedPostBody ?? '').isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      message.sharedPostBody!,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 14,
                        height: 1.28,
                      ),
                    ),
                  ],
                  if (isEvent) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () {
                        final next = {...eventRsvps};
                        if (joined) {
                          next.remove(message.sharedPostId);
                        } else if (message.sharedPostId != null) {
                          next.add(message.sharedPostId!);
                        }
                        ref.read(dmSharedEventRsvpProvider.notifier).state =
                            next;
                      },
                      icon: Icon(
                        joined
                            ? Icons.check_circle_rounded
                            : Icons.waving_hand_outlined,
                      ),
                      label: Text(joined ? 'You’re in' : 'I’m in'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(36),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SharedSpotButton extends StatelessWidget {
  const _SharedSpotButton({required this.message});

  final DirectChatMessage message;

  @override
  Widget build(BuildContext context) {
    final spotName = message.sharedPostSpotName;
    if (spotName == null) return const SizedBox.shrink();

    return TextButton.icon(
      onPressed: message.sharedPostSpotId == null
          ? null
          : () => context.push('/spot/${message.sharedPostSpotId}'),
      icon: const Icon(Icons.place_outlined, size: 15),
      label: Text(spotName, maxLines: 1, overflow: TextOverflow.ellipsis),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

void _openSharedPostProfile(BuildContext context, DirectChatMessage message) {
  final userId = message.sharedPostAuthorUserId;
  if (userId == null) return;
  context.push(
    '/profile/$userId?post=${message.sharedPostId ?? ''}',
    extra: PublicProfilePreview(
      userId: userId,
      displayName: message.sharedPostAuthor ?? 'Tydes surfer',
      handle: message.sharedPostAuthorHandle,
      avatarUrl: message.sharedPostAuthorAvatarUrl,
      premium: message.sharedPostAuthorPremium,
      subtitle: 'Surf traveler on Tydes',
    ),
  );
}

class _MiniFollowButton extends ConsumerWidget {
  const _MiniFollowButton({required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final followedUserIds = ref.watch(followedUserIdsProvider);
    final hiddenFollowingUserIds = ref.watch(hiddenFollowingUserIdsProvider);
    final isFollowing =
        followedUserIds.contains(userId) &&
        !hiddenFollowingUserIds.contains(userId);
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton(
      onPressed: () => _setMiniFollowed(ref, userId, !isFollowing),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(62, 30),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        visualDensity: VisualDensity.compact,
        foregroundColor: scheme.primary,
      ),
      child: Text(isFollowing ? 'Following' : 'Follow'),
    );
  }
}

void _setMiniFollowed(WidgetRef ref, String userId, bool followed) {
  final nextFollowed = {...ref.read(followedUserIdsProvider)};
  if (followed) {
    nextFollowed.add(userId);
    ref.read(hiddenFollowingUserIdsProvider.notifier).state = {
      ...ref.read(hiddenFollowingUserIdsProvider),
    }..remove(userId);
  } else {
    nextFollowed.remove(userId);
  }
  ref.read(followedUserIdsProvider.notifier).state = nextFollowed;
  unawaited(
    ref
        .read(demoPersistenceProvider)
        .saveSocialRelationships(
          followedUserIds: ref.read(followedUserIdsProvider),
          hiddenFollowingUserIds: ref.read(hiddenFollowingUserIdsProvider),
          hiddenFollowerUserIds: ref.read(hiddenFollowerUserIdsProvider),
          blockedUserIds: ref.read(blockedUserIdsProvider),
        ),
  );
  unawaited(_syncMiniFollowToBackend(ref, userId, followed));
}

Future<void> _syncMiniFollowToBackend(
  WidgetRef ref,
  String userId,
  bool following,
) async {
  try {
    final relationships = await ref
        .read(surfRepositoryProvider)
        .setUserFollow(userId: userId, following: following);
    ref.read(followedUserIdsProvider.notifier).state =
        relationships.followedUserIds;
    ref.read(followerUserIdsProvider.notifier).state =
        relationships.followerUserIds;
  } catch (_) {
    // Keep the optimistic local state if the network is briefly unavailable.
  }
}

class _ImageAttachmentPreview extends StatelessWidget {
  const _ImageAttachmentPreview({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final file = File(path);
    if (!file.existsSync()) {
      return const Text('Photo unavailable');
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Image.file(
        file,
        width: MediaQuery.sizeOf(context).width * 0.58,
        height: 190,
        fit: BoxFit.cover,
      ),
    );
  }
}

class _VideoAttachmentPreview extends StatefulWidget {
  const _VideoAttachmentPreview({required this.path});

  final String path;

  @override
  State<_VideoAttachmentPreview> createState() =>
      _VideoAttachmentPreviewState();
}

class _VideoAttachmentPreviewState extends State<_VideoAttachmentPreview> {
  VideoPlayerController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final file = File(widget.path);
    if (!file.existsSync()) {
      _failed = true;
      return;
    }

    final controller = VideoPlayerController.file(file);
    _controller = controller;
    controller
      ..setLooping(false)
      ..setVolume(1)
      ..initialize()
          .then((_) {
            if (mounted) setState(() {});
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

  void _togglePlayback() {
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
    final controller = _controller;
    final ready = controller?.value.isInitialized ?? false;
    final playing = controller?.value.isPlaying ?? false;
    final scheme = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width * 0.58;

    if (_failed) {
      return Container(
        width: width,
        height: 190,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(Icons.videocam_off_outlined, color: scheme.outline),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: width,
        height: 190,
        child: GestureDetector(
          onTap: ready ? _togglePlayback : null,
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
                    : Container(color: scheme.surfaceContainerHighest),
              ),
              if (!playing)
                Material(
                  color: Colors.black.withValues(alpha: 0.34),
                  shape: const CircleBorder(),
                  child: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 34,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageComposer extends StatelessWidget {
  const _MessageComposer({
    required this.controller,
    required this.onSend,
    required this.onAddAttachment,
    this.sending = false,
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onAddAttachment;
  final bool sending;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
        child: Row(
          children: [
            IconButton(
              onPressed: onAddAttachment,
              icon: const Icon(Icons.add_circle_outline),
              color: scheme.primary,
            ),
            Expanded(
              child: TextField(
                key: const ValueKey('dm-message-input'),
                controller: controller,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) {
                  if (!sending) onSend();
                },
                maxLength: 1600,
                decoration: InputDecoration(
                  hintText: 'Message...',
                  counterText: '',
                  filled: true,
                  fillColor: Theme.of(context).cardColor,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
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
              onPressed: sending ? null : onSend,
              style: FilledButton.styleFrom(
                minimumSize: const Size(46, 46),
                padding: EdgeInsets.zero,
                shape: const CircleBorder(),
              ),
              child: sending
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_upward_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageRequestActions extends StatelessWidget {
  const _MessageRequestActions({
    required this.thread,
    required this.onAccept,
    required this.onDecline,
    this.busy = false,
  });

  final DirectMessageThread thread;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${thread.name} wants to message you.',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Accept to move this chat into Primary and reply.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: busy ? null : onDecline,
                      child: const Text('Decline'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: busy ? null : onAccept,
                      child: const Text('Accept request'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThreadAvatar extends StatelessWidget {
  const _ThreadAvatar({required this.thread, required this.radius});

  final DirectMessageThread thread;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: radius,
          backgroundColor: tydesAvatarBackground,
          child: Text(
            thread.initial,
            style: TextStyle(
              color: tydesAvatarForeground,
              fontWeight: FontWeight.w900,
              fontSize: radius * 0.72,
            ),
          ),
        ),
        if (thread.online)
          Positioned(
            right: 0,
            bottom: 1,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: const Color(0xFF33C481),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
      ],
    );
  }
}

class _EmptyMessagesCard extends StatelessWidget {
  const _EmptyMessagesCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Text(
          'No matching messages yet.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

class _MessageRequestsPage extends ConsumerWidget {
  const _MessageRequestsPage({required this.requestThreads});

  final List<DirectMessageThread> requestThreads;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liveThreads = ref.watch(directMessageThreadsProvider);
    final blockedUserIds = ref.watch(blockedUserIdsProvider);
    final requests = liveThreads
        .where(
          (thread) =>
              !thread.requestAccepted &&
              !thread.requestDeclined &&
              !_isBlockedThread(thread, blockedUserIds),
        )
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Requests')),
      body: FeedRefreshIndicator(
        onRefresh: () =>
            ref.read(directMessageThreadsProvider.notifier).refresh(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            Text(
              'Messages from people you don’t follow yet.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            if (requests.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child: Text('No message requests right now.'),
                ),
              )
            else
              ...requests.map(
                (thread) => _MessageThreadTile(
                  thread: thread,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _DirectChatPage(
                        threadId: thread.id,
                        showRequestActions: true,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class DirectMessageThread {
  const DirectMessageThread({
    required this.id,
    this.profileUserId,
    required this.name,
    required this.handle,
    required this.initial,
    required this.location,
    required this.preview,
    required this.time,
    required this.unreadCount,
    required this.online,
    this.requestAccepted = false,
    this.requestDeclined = false,
    required this.messages,
    this.avatarUrl,
    this.premium = false,
    this.updatedAt,
  });

  final String id;
  final String? profileUserId;
  final String name;
  final String handle;
  final String initial;
  final String location;
  final String preview;
  final String time;
  final int unreadCount;
  final bool online;
  final bool requestAccepted;
  final bool requestDeclined;
  final List<DirectChatMessage> messages;
  final String? avatarUrl;
  final bool premium;
  final DateTime? updatedAt;

  DirectMessageThread copyWith({
    String? profileUserId,
    String? preview,
    String? time,
    int? unreadCount,
    bool? requestAccepted,
    bool? requestDeclined,
    List<DirectChatMessage>? messages,
    DateTime? updatedAt,
  }) {
    return DirectMessageThread(
      id: id,
      profileUserId: profileUserId ?? this.profileUserId,
      name: name,
      handle: handle,
      initial: initial,
      location: location,
      preview: preview ?? this.preview,
      time: time ?? this.time,
      unreadCount: unreadCount ?? this.unreadCount,
      online: online,
      requestAccepted: requestAccepted ?? this.requestAccepted,
      requestDeclined: requestDeclined ?? this.requestDeclined,
      messages: messages ?? this.messages,
      avatarUrl: avatarUrl,
      premium: premium,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory DirectMessageThread.fromJson(Map<String, dynamic> json) {
    return DirectMessageThread(
      id: json['id'] as String,
      profileUserId: json['profile_user_id'] as String?,
      name: json['name'] as String,
      handle: json['handle'] as String,
      initial: json['initial'] as String,
      location: json['location'] as String,
      preview: json['preview'] as String,
      time: json['time'] as String,
      unreadCount: json['unread_count'] as int? ?? 0,
      online: json['online'] as bool? ?? false,
      requestAccepted: json['request_accepted'] as bool? ?? false,
      requestDeclined: json['request_declined'] as bool? ?? false,
      messages: (json['messages'] as List<dynamic>? ?? const [])
          .map(
            (item) => DirectChatMessage.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
      avatarUrl: json['avatar_url'] as String?,
      premium: json['premium'] as bool? ?? false,
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'profile_user_id': profileUserId,
      'name': name,
      'handle': handle,
      'initial': initial,
      'location': location,
      'preview': preview,
      'time': time,
      'unread_count': unreadCount,
      'online': online,
      'request_accepted': requestAccepted,
      'request_declined': requestDeclined,
      'messages': messages.map((message) => message.toJson()).toList(),
      'avatar_url': avatarUrl,
      'premium': premium,
      'updated_at': updatedAt?.toIso8601String(),
    };
  }
}

class DirectChatMessage {
  const DirectChatMessage({
    required this.text,
    required this.time,
    required this.isMe,
    this.mediaPath,
    this.mediaType,
    this.sharedPostId,
    this.sharedPostAuthorUserId,
    this.sharedPostAuthor,
    this.sharedPostAuthorHandle,
    this.sharedPostAuthorAvatarUrl,
    this.sharedPostAuthorPremium = false,
    this.sharedPostBody,
    this.sharedPostSpotId,
    this.sharedPostSpotName,
    this.sharedPostType,
    this.sharedPostMediaUrl,
    this.id,
    this.senderUserId,
    this.createdAt,
  });

  final String text;
  final String time;
  final bool isMe;
  final String? mediaPath;
  final String? mediaType;
  final String? sharedPostId;
  final String? sharedPostAuthorUserId;
  final String? sharedPostAuthor;
  final String? sharedPostAuthorHandle;
  final String? sharedPostAuthorAvatarUrl;
  final bool sharedPostAuthorPremium;
  final String? sharedPostBody;
  final String? sharedPostSpotId;
  final String? sharedPostSpotName;
  final String? sharedPostType;
  final String? sharedPostMediaUrl;
  final String? id;
  final String? senderUserId;
  final String? createdAt;

  factory DirectChatMessage.fromServer(
    Map<String, dynamic> json,
    String ownerId,
  ) {
    final id = json['id'];
    final sender = json['sender_user_id'];
    if (id is! String || id.isEmpty || sender is! String || sender.isEmpty) {
      throw StateError('The message response was incomplete.');
    }
    final rawPost = json['shared_post'];
    final post = rawPost is Map
        ? SocialPostModel.fromJson(Map<String, dynamic>.from(rawPost))
        : null;
    return DirectChatMessage(
      id: id,
      senderUserId: sender,
      createdAt: json['created_at'] as String?,
      text: json['text'] as String? ?? '',
      time: _messageTime(json['created_at'] as String?),
      isMe: sender == ownerId,
      sharedPostId: json['shared_post_id'] as String?,
      sharedPostAuthorUserId: post?.userId,
      sharedPostAuthor: post?.authorName,
      sharedPostAuthorHandle: post?.authorHandle,
      sharedPostAuthorAvatarUrl: post?.authorAvatarUrl,
      sharedPostAuthorPremium: post?.authorPremium ?? false,
      sharedPostBody:
          post?.body ??
          (json['shared_post_id'] != null
              ? 'This post is no longer available.'
              : null),
      sharedPostSpotId: post?.spotId,
      sharedPostType: post == null
          ? null
          : (post.postType == 'general' ? 'post' : 'event'),
      sharedPostMediaUrl: post == null ? null : _sharedPostMediaUrl(post),
    );
  }

  factory DirectChatMessage.fromJson(Map<String, dynamic> json) {
    return DirectChatMessage(
      text: json['text'] as String? ?? '',
      time: json['time'] as String? ?? '',
      isMe: json['is_me'] as bool? ?? false,
      mediaPath: json['media_path'] as String?,
      mediaType: json['media_type'] as String?,
      sharedPostId: json['shared_post_id'] as String?,
      sharedPostAuthorUserId: json['shared_post_author_user_id'] as String?,
      sharedPostAuthor: json['shared_post_author'] as String?,
      sharedPostAuthorHandle: json['shared_post_author_handle'] as String?,
      sharedPostAuthorAvatarUrl:
          json['shared_post_author_avatar_url'] as String?,
      sharedPostAuthorPremium:
          json['shared_post_author_premium'] as bool? ?? false,
      sharedPostBody: json['shared_post_body'] as String?,
      sharedPostSpotId: json['shared_post_spot_id'] as String?,
      sharedPostSpotName: json['shared_post_spot_name'] as String?,
      sharedPostType: json['shared_post_type'] as String?,
      sharedPostMediaUrl: json['shared_post_media_url'] as String?,
      id: json['id'] as String?,
      senderUserId: json['sender_user_id'] as String?,
      createdAt: json['created_at'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'text': text,
      'time': time,
      'is_me': isMe,
      'id': id,
      'sender_user_id': senderUserId,
      'created_at': createdAt,
      if (mediaPath != null) 'media_path': mediaPath,
      if (mediaType != null) 'media_type': mediaType,
      if (sharedPostId != null) 'shared_post_id': sharedPostId,
      if (sharedPostAuthorUserId != null)
        'shared_post_author_user_id': sharedPostAuthorUserId,
      if (sharedPostAuthor != null) 'shared_post_author': sharedPostAuthor,
      if (sharedPostAuthorHandle != null)
        'shared_post_author_handle': sharedPostAuthorHandle,
      if (sharedPostAuthorAvatarUrl != null)
        'shared_post_author_avatar_url': sharedPostAuthorAvatarUrl,
      'shared_post_author_premium': sharedPostAuthorPremium,
      if (sharedPostBody != null) 'shared_post_body': sharedPostBody,
      if (sharedPostSpotId != null) 'shared_post_spot_id': sharedPostSpotId,
      if (sharedPostSpotName != null)
        'shared_post_spot_name': sharedPostSpotName,
      if (sharedPostType != null) 'shared_post_type': sharedPostType,
      if (sharedPostMediaUrl != null)
        'shared_post_media_url': sharedPostMediaUrl,
    };
  }
}

String? _sharedPostMediaUrl(SocialPostModel post) {
  if (post.media.isEmpty) return null;
  final photo = post.media
      .where((item) => item.mediaType == 'photo')
      .firstOrNull;
  if (photo != null) return photo.url;
  return post.media.first.thumbnailUrl.isNotEmpty
      ? post.media.first.thumbnailUrl
      : post.media.first.url;
}

const _messageableProfiles = <PublicProfilePreview>[];
