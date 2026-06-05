import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../core/network/api_models.dart';
import '../../core/network/demo_persistence.dart';
import '../../core/network/surf_repository.dart';
import 'social_profile.dart';

final directMessageThreadsProvider =
    StateNotifierProvider<
      DirectMessageThreadsNotifier,
      List<DirectMessageThread>
    >(
      (ref) => DirectMessageThreadsNotifier(ref.watch(demoPersistenceProvider)),
    );

final unreadDirectMessageThreadCountProvider = Provider<int>((ref) {
  return ref
      .watch(directMessageThreadsProvider)
      .where((thread) => !thread.requestDeclined && thread.unreadCount > 0)
      .length;
});

final dmSharedEventRsvpProvider = StateProvider<Set<String>>((ref) => {});
final dmSocialProfilesProvider = FutureProvider((ref) {
  ref.watch(socialRefreshKeyProvider);
  return ref.watch(surfRepositoryProvider).fetchSocialProfiles();
});

class DirectMessageThreadsNotifier
    extends StateNotifier<List<DirectMessageThread>> {
  DirectMessageThreadsNotifier(this._persistence) : super(_seedThreads) {
    unawaited(_loadSavedThreads());
  }

  final DemoPersistence _persistence;

  Future<void> _loadSavedThreads() async {
    final savedPayloads = await _persistence.loadDirectMessageThreadPayloads();
    final saved = <DirectMessageThread>[];
    for (final payload in savedPayloads) {
      try {
        saved.add(DirectMessageThread.fromJson(payload));
      } catch (_) {
        // Ignore stale/corrupt demo DM rows instead of breaking the inbox.
      }
    }
    if (saved.isEmpty) {
      final result = _applyDemoIncomingMessages(state);
      if (!result.changed) return;
      state = result.threads;
      _sortThreads();
      _persist();
      return;
    }
    final merged = {for (final thread in _seedThreads) thread.id: thread};
    for (final thread in saved) {
      merged[thread.id] = thread;
    }
    state = merged.values.toList();
    final result = _applyDemoIncomingMessages(state);
    if (result.changed) {
      state = result.threads;
    }
    _sortThreads();
    if (result.changed) _persist();
  }

  void markRead(String threadId) {
    var changed = false;
    state = [
      for (final thread in state)
        if (thread.id == threadId && thread.unreadCount > 0)
          (() {
            changed = true;
            return thread.copyWith(unreadCount: 0);
          })()
        else
          thread,
    ];
    if (changed) _persist();
  }

  void sendMessage(String threadId, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final message = DirectChatMessage(text: trimmed, time: 'Now', isMe: true);
    state = [
      for (final thread in state)
        if (thread.id == threadId)
          thread.copyWith(
            preview: trimmed,
            time: 'Now',
            unreadCount: 0,
            messages: [...thread.messages, message],
          )
        else
          thread,
    ];
    _sortThreads();
    _persist();
  }

  void sendAttachment({
    required String threadId,
    required String path,
    required String type,
  }) {
    final isVideo = type == 'video';
    final message = DirectChatMessage(
      text: '',
      time: 'Now',
      isMe: true,
      mediaPath: path,
      mediaType: type,
    );
    state = [
      for (final thread in state)
        if (thread.id == threadId)
          thread.copyWith(
            preview: isVideo ? 'Sent a video' : 'Sent a photo',
            time: 'Now',
            unreadCount: 0,
            messages: [...thread.messages, message],
          )
        else
          thread,
    ];
    _sortThreads();
    _persist();
  }

  void sendSharedPost({
    required String threadId,
    required SocialPostModel post,
    required String? spotName,
    required String? note,
  }) {
    final isEvent =
        post.postType == 'surf_plan' || post.postType == 'looking_for_buddy';
    final preview = isEvent
        ? 'Sent an event from ${post.authorName}'
        : 'Sent a post from ${post.authorName}';
    final message = DirectChatMessage(
      text: note?.trim() ?? '',
      time: 'Now',
      isMe: true,
      sharedPostId: post.id,
      sharedPostAuthorUserId: post.userId,
      sharedPostAuthor: post.authorName,
      sharedPostAuthorHandle: post.authorHandle,
      sharedPostAuthorAvatarUrl: post.authorAvatarUrl,
      sharedPostAuthorPremium: post.authorPremium,
      sharedPostBody: post.body,
      sharedPostSpotId: post.spotId,
      sharedPostSpotName: spotName,
      sharedPostType: isEvent ? 'event' : 'post',
      sharedPostMediaUrl: _sharedPostMediaUrl(post),
    );
    state = [
      for (final thread in state)
        if (thread.id == threadId)
          thread.copyWith(
            preview: preview,
            time: 'Now',
            unreadCount: 0,
            messages: [...thread.messages, message],
          )
        else
          thread,
    ];
    _sortThreads();
    _persist();
  }

  void acceptRequest(String threadId) {
    state = [
      for (final thread in state)
        if (thread.id == threadId)
          thread.copyWith(requestAccepted: true, unreadCount: 0)
        else
          thread,
    ];
    _sortThreads();
    _persist();
  }

  void declineRequest(String threadId) {
    state = [
      for (final thread in state)
        if (thread.id == threadId)
          thread.copyWith(requestDeclined: true, unreadCount: 0)
        else
          thread,
    ];
    _persist();
  }

  DirectMessageThread ensureThreadForProfile(PublicProfilePreview profile) {
    final threadId = _normalizeThreadId(
      profile.handle?.isNotEmpty == true ? profile.handle! : profile.userId,
    );
    final existing = threadByIdOrHandle(threadId);
    if (existing != null) {
      final revived = existing.copyWith(
        requestAccepted: true,
        requestDeclined: false,
        unreadCount: 0,
      );
      state = [
        for (final thread in state)
          if (thread.id == existing.id) revived else thread,
      ];
      _sortThreads();
      _persist();
      return revived;
    }

    final handle = (profile.handle?.trim().isNotEmpty ?? false)
        ? profile.handle!.trim().replaceFirst('@', '')
        : threadId;
    final thread = DirectMessageThread(
      id: threadId,
      name: profile.displayName,
      handle: handle,
      initial: _initialFor(profile.displayName),
      location: profile.location ?? 'Tydes',
      preview: 'Start a private chat.',
      time: 'Now',
      unreadCount: 0,
      online: false,
      requestAccepted: true,
      messages: [
        DirectChatMessage(
          text: 'This is the start of your chat with ${profile.displayName}.',
          time: 'Now',
          isMe: false,
        ),
      ],
    );
    state = [thread, ...state];
    _persist();
    return thread;
  }

  DirectMessageThread? threadByIdOrHandle(String value) {
    final normalized = _normalizeThreadId(value);
    for (final thread in state) {
      if (thread.id == normalized || thread.handle == normalized) {
        return thread;
      }
    }
    return null;
  }

  void _sortThreads() {
    state = [...state]
      ..sort((a, b) {
        if (a.time == 'Now' && b.time != 'Now') return -1;
        if (b.time == 'Now' && a.time != 'Now') return 1;
        return 0;
      });
  }

  void _persist() {
    unawaited(
      _persistence.saveDirectMessageThreadPayloads(
        state.map((thread) => thread.toJson()).toList(),
      ),
    );
  }
}

_ThreadPatchResult _applyDemoIncomingMessages(
  List<DirectMessageThread> threads,
) {
  final updated = <DirectMessageThread>[];
  var changed = false;

  for (final thread in threads) {
    final incoming = _demoIncomingMessages[thread.id] ?? const [];
    var messages = thread.messages;
    var addedUnread = 0;
    DirectChatMessage? latestAdded;

    for (final message in incoming) {
      final alreadyExists = messages.any(
        (existing) =>
            existing.text == message.text &&
            existing.time == message.time &&
            existing.isMe == message.isMe,
      );
      if (alreadyExists) continue;
      messages = [...messages, message];
      latestAdded = message;
      addedUnread += 1;
    }

    if (latestAdded == null) {
      updated.add(thread);
      continue;
    }

    changed = true;
    updated.add(
      thread.copyWith(
        preview: latestAdded.text,
        time: latestAdded.time,
        unreadCount: thread.unreadCount + addedUnread,
        messages: messages,
      ),
    );
  }

  return _ThreadPatchResult(threads: updated, changed: changed);
}

class _ThreadPatchResult {
  const _ThreadPatchResult({required this.threads, required this.changed});

  final List<DirectMessageThread> threads;
  final bool changed;
}

class DirectMessagesPage extends ConsumerStatefulWidget {
  const DirectMessagesPage({super.key, this.initialThreadId, this.seedProfile});

  final String? initialThreadId;
  final PublicProfilePreview? seedProfile;

  @override
  ConsumerState<DirectMessagesPage> createState() => _DirectMessagesPageState();
}

class _DirectMessagesPageState extends ConsumerState<DirectMessagesPage> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    final initialThreadId = widget.initialThreadId;
    final seedProfile = widget.seedProfile;
    if (initialThreadId != null && seedProfile != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref
            .read(directMessageThreadsProvider.notifier)
            .ensureThreadForProfile(seedProfile);
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final threads = ref.watch(directMessageThreadsProvider);
    final followedUserIds = ref.watch(followedUserIdsProvider);
    final hiddenFollowingUserIds = ref.watch(hiddenFollowingUserIdsProvider);
    final initialThreadId = widget.initialThreadId;
    if (initialThreadId != null && initialThreadId.isNotEmpty) {
      final thread = _threadByIdOrHandle(threads, initialThreadId);
      if (thread == null) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return _DirectChatPage(threadId: thread.id);
    }

    final visibleThreads = threads
        .where((thread) => !thread.requestDeclined)
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
        actions: [
          IconButton(
            onPressed: () => _openNewMessageSheet(context, ref),
            icon: const Icon(Icons.edit_square),
            tooltip: 'New message',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          _SearchField(
            controller: _searchController,
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 18),
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
    );
  }
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
    if (thread.id == normalized || thread.handle == normalized) {
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

const _defaultFollowingThreadIds = {
  'ari',
  'aridawn',
  'lina',
  'linareef',
  'jo',
  'jotide',
  'maya',
  'mayasurfer',
  'kai',
  'kaiglass',
  'noa',
  'noacurrent',
  'sam',
  'samlines',
};

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
    userId: thread.id,
    displayName: thread.name,
    handle: thread.handle,
    subtitle: 'Surf traveler on Tydes',
    location: thread.location,
  );
}

Future<void> _openNewMessageSheet(BuildContext context, WidgetRef ref) async {
  final profile = await showModalBottomSheet<PublicProfilePreview>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _NewMessageSheet(),
  );
  if (profile == null || !context.mounted) return;
  final thread = ref
      .read(directMessageThreadsProvider.notifier)
      .ensureThreadForProfile(profile);
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
    final profiles = _filteredMessageableProfiles(
      realProfiles: realProfiles.valueOrNull ?? const [],
      fallbackProfiles: _messageableProfiles,
      query: q,
    );

    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.42,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFFF8F7F2),
            borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
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

List<PublicProfilePreview> _filteredMessageableProfiles({
  required List<SocialProfileModel> realProfiles,
  required List<PublicProfilePreview> fallbackProfiles,
  required String query,
}) {
  final ranked = <String, _RankedMessageProfile>{};

  void addProfile(PublicProfilePreview profile, int priority) {
    if (profile.userId == 'usr_demo') return;
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
            CircleAvatar(
              radius: 25,
              backgroundColor: tydesAvatarBackground,
              backgroundImage: profile.avatarUrl == null
                  ? null
                  : NetworkImage(profile.avatarUrl!),
              child: profile.avatarUrl == null
                  ? Text(
                      _initialFor(profile.displayName),
                      style: const TextStyle(
                        color: tydesAvatarForeground,
                        fontWeight: FontWeight.w900,
                      ),
                    )
                  : null,
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
        fillColor: Colors.white,
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
                  style: const TextStyle(
                    color: Colors.white,
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

class _DirectChatPageState extends ConsumerState<_DirectChatPage> {
  final TextEditingController _messageController = TextEditingController();
  final ImagePicker _imagePicker = ImagePicker();

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final thread = _threadByIdOrHandle(
      ref.watch(directMessageThreadsProvider),
      widget.threadId,
    );
    if (thread == null) {
      return const Scaffold(body: Center(child: Text('Chat not found.')));
    }
    if (thread.unreadCount > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(directMessageThreadsProvider.notifier).markRead(thread.id);
      });
    }
    final isRequest = widget.showRequestActions && !thread.requestAccepted;
    final profile = _profileFromThread(thread);

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
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: FollowButton(userId: profile.userId, compact: true),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
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
          if (isRequest)
            _MessageRequestActions(
              thread: thread,
              onAccept: () {
                ref
                    .read(directMessageThreadsProvider.notifier)
                    .acceptRequest(thread.id);
              },
              onDecline: () {
                ref
                    .read(directMessageThreadsProvider.notifier)
                    .declineRequest(thread.id);
                Navigator.of(context).pop();
              },
            )
          else
            _MessageComposer(
              controller: _messageController,
              onSend: () => _sendMessage(thread.id),
              onAddAttachment: () => _openAttachmentSheet(thread.id),
            ),
        ],
      ),
    );
  }

  Future<void> _openAttachmentSheet(String threadId) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Add attachment',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.perm_media_outlined),
                title: const Text('Photo or video'),
                subtitle: const Text('Choose from your library'),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_pickAttachment(threadId));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickAttachment(String threadId) async {
    try {
      final picked = await _imagePicker.pickMedia(imageQuality: 88);
      if (picked == null || !mounted) return;
      final savedPath = await _copyAttachmentToAppStorage(picked);
      final isVideo = _isVideoAttachment(picked);
      ref
          .read(directMessageThreadsProvider.notifier)
          .sendAttachment(
            threadId: threadId,
            path: savedPath,
            type: isVideo ? 'video' : 'image',
          );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not add attachment: $error')),
      );
    }
  }

  bool _isVideoAttachment(XFile picked) {
    final mimeType = picked.mimeType?.toLowerCase();
    if (mimeType != null) return mimeType.startsWith('video/');
    final path = picked.path.toLowerCase();
    return path.endsWith('.mov') ||
        path.endsWith('.mp4') ||
        path.endsWith('.m4v') ||
        path.endsWith('.avi') ||
        path.endsWith('.webm');
  }

  Future<String> _copyAttachmentToAppStorage(XFile picked) async {
    final supportDirectory = await getApplicationSupportDirectory();
    final attachmentDirectory = Directory(
      '${supportDirectory.path}/dm_attachments',
    );
    if (!attachmentDirectory.existsSync()) {
      attachmentDirectory.createSync(recursive: true);
    }
    final originalName = picked.path.split('/').last;
    final extensionIndex = originalName.lastIndexOf('.');
    final extension = extensionIndex == -1
        ? ''
        : originalName.substring(extensionIndex);
    final fileName = 'dm_${DateTime.now().microsecondsSinceEpoch}$extension';
    final savedFile = await File(
      picked.path,
    ).copy('${attachmentDirectory.path}/$fileName');
    return savedFile.path;
  }

  void _sendMessage(String threadId) {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    ref.read(directMessageThreadsProvider.notifier).sendMessage(threadId, text);
    _messageController.clear();
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
    final color = message.isMe ? theme.colorScheme.primary : Colors.white;
    final textColor = message.isMe ? Colors.white : theme.colorScheme.onSurface;
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
                      ? Colors.white
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
                color: message.isMe ? scheme.primary : Colors.white,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(
                message.text,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: message.isMe ? Colors.white : scheme.onSurface,
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
          color: Colors.white,
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
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: tydesAvatarBackground,
                        backgroundImage:
                            message.sharedPostAuthorAvatarUrl == null
                            ? null
                            : NetworkImage(message.sharedPostAuthorAvatarUrl!),
                        child: message.sharedPostAuthorAvatarUrl == null
                            ? Text(
                                _initialFor(message.sharedPostAuthor ?? 'S'),
                                style: const TextStyle(
                                  color: tydesAvatarForeground,
                                  fontWeight: FontWeight.w900,
                                ),
                              )
                            : null,
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
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onAddAttachment;

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
                controller: controller,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(
                  hintText: 'Message...',
                  filled: true,
                  fillColor: Colors.white,
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
              onPressed: onSend,
              style: FilledButton.styleFrom(
                minimumSize: const Size(46, 46),
                padding: EdgeInsets.zero,
                shape: const CircleBorder(),
              ),
              child: const Icon(Icons.arrow_upward_rounded),
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
  });

  final DirectMessageThread thread;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
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
                      onPressed: onDecline,
                      child: const Text('Decline'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: onAccept,
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
    final requests = requestThreads
        .map((thread) => _threadByIdOrHandle(liveThreads, thread.id))
        .whereType<DirectMessageThread>()
        .where((thread) => !thread.requestAccepted && !thread.requestDeclined)
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Requests')),
      body: ListView(
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
    );
  }
}

class DirectMessageThread {
  const DirectMessageThread({
    required this.id,
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
  });

  final String id;
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

  DirectMessageThread copyWith({
    String? preview,
    String? time,
    int? unreadCount,
    bool? requestAccepted,
    bool? requestDeclined,
    List<DirectChatMessage>? messages,
  }) {
    return DirectMessageThread(
      id: id,
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
    );
  }

  factory DirectMessageThread.fromJson(Map<String, dynamic> json) {
    return DirectMessageThread(
      id: json['id'] as String,
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
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
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
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'text': text,
      'time': time,
      'is_me': isMe,
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

const _messageableProfiles = [
  PublicProfilePreview(
    userId: 'friend_ari',
    displayName: 'Ari Dawn',
    handle: 'aridawn',
    subtitle: 'Surf traveler on Tydes',
    location: 'Uluwatu',
  ),
  PublicProfilePreview(
    userId: 'friend_lina',
    displayName: 'Lina Reef',
    handle: 'linareef',
    subtitle: 'Surf traveler on Tydes',
    location: 'Canggu',
  ),
  PublicProfilePreview(
    userId: 'friend_jo',
    displayName: 'Jo Tide',
    handle: 'jotide',
    subtitle: 'Surf traveler on Tydes',
    location: 'Siargao',
  ),
  PublicProfilePreview(
    userId: 'friend_maya',
    displayName: 'Maya Surfer',
    handle: 'mayasurfer',
    subtitle: 'Surf traveler on Tydes',
    location: 'Uluwatu',
  ),
  PublicProfilePreview(
    userId: 'friend_kai',
    displayName: 'Kai Glass',
    handle: 'kaiglass',
    subtitle: 'Surf traveler on Tydes',
    location: 'Byron Bay',
  ),
  PublicProfilePreview(
    userId: 'suggested_tara_sets',
    displayName: 'Tara Sets',
    handle: 'tarasets',
    subtitle: 'Followed by Ari Dawn',
    location: 'Canggu',
  ),
  PublicProfilePreview(
    userId: 'suggested_reef_milo',
    displayName: 'Reef Milo',
    handle: 'reefmilo',
    subtitle: 'Followed by Lina Reef',
    location: 'Siargao',
  ),
  PublicProfilePreview(
    userId: 'suggested_ella_tide',
    displayName: 'Ella Tide',
    handle: 'ellatide',
    subtitle: 'Followed by Jo Tide',
    location: 'Uluwatu',
  ),
  PublicProfilePreview(
    userId: 'suggested_noah_glass',
    displayName: 'Noah Glass',
    handle: 'noahglass',
    subtitle: 'Followed by Maya Surfer',
    location: 'Arugam Bay',
  ),
  PublicProfilePreview(
    userId: 'random_ivy_reef',
    displayName: 'Ivy Reef',
    handle: 'ivyreef',
    subtitle: 'New to Tydes',
    location: 'Uluwatu',
  ),
];

const _seedThreads = [
  DirectMessageThread(
    id: 'ari',
    name: 'Ari Dawn',
    handle: 'aridawn',
    initial: 'A',
    location: 'Uluwatu',
    preview: 'Sunset Balangan still on if the wind stays light.',
    time: '12m',
    unreadCount: 0,
    online: true,
    messages: [
      DirectChatMessage(
        text: 'You still thinking Balangan later?',
        time: '6:12 PM',
        isMe: false,
      ),
      DirectChatMessage(
        text: 'Yeah if the wind holds. Sunset could be fun.',
        time: '6:14 PM',
        isMe: true,
      ),
      DirectChatMessage(
        text: 'Sweet. I can grab a scooter around 4:30.',
        time: '6:18 PM',
        isMe: false,
      ),
    ],
  ),
  DirectMessageThread(
    id: 'lina',
    name: 'Lina Reef',
    handle: 'linareef',
    initial: 'L',
    location: 'Canggu',
    preview: 'I can meet near Batu Bolong after coffee.',
    time: '1h',
    unreadCount: 0,
    online: true,
    messages: [
      DirectChatMessage(
        text: 'Longboard wave looks small but clean tomorrow.',
        time: '5:03 PM',
        isMe: false,
      ),
      DirectChatMessage(
        text: 'I might check Batu Bolong after breakfast.',
        time: '5:07 PM',
        isMe: true,
      ),
      DirectChatMessage(
        text: 'Perfect. I can meet near Batu Bolong after coffee.',
        time: '5:09 PM',
        isMe: false,
      ),
    ],
  ),
  DirectMessageThread(
    id: 'kai',
    name: 'Kai Glass',
    handle: 'kaiglass',
    initial: 'K',
    location: 'Byron Bay',
    preview: 'The Pass looked slow but clean this morning.',
    time: '3h',
    unreadCount: 0,
    online: false,
    messages: [
      DirectChatMessage(
        text: 'The Pass looked slow but clean this morning.',
        time: '2:20 PM',
        isMe: false,
      ),
      DirectChatMessage(
        text: 'Any runners or mostly waiting?',
        time: '2:24 PM',
        isMe: true,
      ),
      DirectChatMessage(
        text: 'Mostly waiting. One good set every fifteen.',
        time: '2:31 PM',
        isMe: false,
      ),
    ],
  ),
  DirectMessageThread(
    id: 'jo',
    name: 'Jo Tide',
    handle: 'jotide',
    initial: 'J',
    location: 'Siargao',
    preview: 'Cloud 9 watch mission sounds good.',
    time: 'Yesterday',
    unreadCount: 0,
    online: false,
    messages: [
      DirectChatMessage(
        text: 'Cloud 9 watch mission sounds good.',
        time: 'Yesterday',
        isMe: false,
      ),
      DirectChatMessage(
        text: 'Might not paddle if it gets too serious haha.',
        time: 'Yesterday',
        isMe: false,
      ),
    ],
  ),
  DirectMessageThread(
    id: 'maya',
    name: 'Maya Surfer',
    handle: 'mayasurfer',
    initial: 'M',
    location: 'Uluwatu',
    preview: 'Friday hang is chill. Bring whoever.',
    time: 'Mon',
    unreadCount: 0,
    online: true,
    messages: [
      DirectChatMessage(
        text: 'Friday hang is chill. Bring whoever.',
        time: 'Mon',
        isMe: false,
      ),
      DirectChatMessage(
        text: 'Good call. I will post it as an event too.',
        time: 'Mon',
        isMe: true,
      ),
    ],
  ),
  DirectMessageThread(
    id: 'tarasets',
    name: 'Tara Sets',
    handle: 'tarasets',
    initial: 'T',
    location: 'Canggu',
    preview: 'Hey, saw your Echo post. Is it beginner friendly today?',
    time: '4m',
    unreadCount: 1,
    online: false,
    messages: [
      DirectChatMessage(
        text: 'Hey, saw your Echo post. Is it beginner friendly today?',
        time: '4m',
        isMe: false,
      ),
    ],
  ),
  DirectMessageThread(
    id: 'reefmilo',
    name: 'Reef Milo',
    handle: 'reefmilo',
    initial: 'R',
    location: 'Siargao',
    preview: 'Do you know if Cloud 9 is worth watching tomorrow?',
    time: '16m',
    unreadCount: 1,
    online: true,
    messages: [
      DirectChatMessage(
        text: 'Do you know if Cloud 9 is worth watching tomorrow?',
        time: '16m',
        isMe: false,
      ),
    ],
  ),
  DirectMessageThread(
    id: 'ellatide',
    name: 'Ella Tide',
    handle: 'ellatide',
    initial: 'E',
    location: 'Uluwatu',
    preview: 'Random question, is Padang too heavy for intermediates?',
    time: '27m',
    unreadCount: 1,
    online: false,
    messages: [
      DirectChatMessage(
        text: 'Random question, is Padang too heavy for intermediates?',
        time: '27m',
        isMe: false,
      ),
    ],
  ),
];

const _demoIncomingMessages = {
  'lina': [
    DirectChatMessage(
      text: 'You around Canggu later? Echo looks fun before dark.',
      time: '2m',
      isMe: false,
    ),
  ],
  'kai': [
    DirectChatMessage(
      text: 'Just checked The Pass. Cleaner than it looked online.',
      time: '8m',
      isMe: false,
    ),
  ],
  'jo': [
    DirectChatMessage(
      text: 'Cloud 9 has a mellow window tomorrow morning if you are around.',
      time: '18m',
      isMe: false,
    ),
  ],
};
