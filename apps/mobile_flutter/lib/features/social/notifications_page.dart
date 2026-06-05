import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import 'social_profile.dart';

final socialNotificationsProvider = FutureProvider((ref) {
  return ref.watch(surfRepositoryProvider).fetchSocialNotifications();
});

class SocialNotificationsPage extends ConsumerWidget {
  const SocialNotificationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifications = ref.watch(socialNotificationsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: RefreshIndicator.adaptive(
        onRefresh: () => ref.refresh(socialNotificationsProvider.future),
        child: notifications.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => const _NotificationsMessage(
            title: 'Could not load notifications.',
            body: 'Pull down to try again.',
          ),
          data: (items) {
            if (items.isEmpty) {
              return const _NotificationsMessage(
                title: 'No notifications yet.',
                body:
                    'Likes, follows, comments, and event updates will show here.',
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final item = _notificationFromModel(items[index]);
                return _NotificationTile(item: item);
              },
            );
          },
        ),
      ),
    );
  }
}

class _NotificationsMessage extends StatelessWidget {
  const _NotificationsMessage({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.notifications_none_rounded,
                  color: scheme.primary,
                  size: 30,
                ),
                const SizedBox(height: 10),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.item});

  final _SocialNotification item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => _openNotificationPost(context, item),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _openNotificationProfile(context, item),
                child: CircleAvatar(
                  radius: 24,
                  backgroundColor: tydesAvatarBackground,
                  backgroundImage: item.profile?.avatarUrl == null
                      ? null
                      : NetworkImage(item.profile!.avatarUrl!),
                  child: item.profile?.avatarUrl == null
                      ? Text(
                          tydesProfileInitial(
                            item.profile?.displayName,
                            fallback: 'T',
                          ),
                          style: const TextStyle(
                            color: tydesAvatarForeground,
                            fontWeight: FontWeight.w900,
                          ),
                        )
                      : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    RichText(
                      text: TextSpan(
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface,
                          height: 1.25,
                        ),
                        children: [
                          WidgetSpan(
                            alignment: PlaceholderAlignment.baseline,
                            baseline: TextBaseline.alphabetic,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(6),
                              onTap: () =>
                                  _openNotificationProfile(context, item),
                              child: Text(
                                item.profile?.displayName ?? 'Someone',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ),
                          TextSpan(text: ' ${item.message}'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      item.time,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (item.preview != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8F7F2),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          item.preview!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _NotificationIcon(type: item.type),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotificationIcon extends StatelessWidget {
  const _NotificationIcon({required this.type});

  final _NotificationType type;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (type) {
      _NotificationType.like => Icons.favorite_rounded,
      _NotificationType.follow => Icons.person_add_alt_1_rounded,
      _NotificationType.reply => Icons.reply_rounded,
      _NotificationType.comment => Icons.chat_bubble_outline_rounded,
      _NotificationType.event => Icons.groups_2_rounded,
      _NotificationType.repost => Icons.autorenew_rounded,
    };

    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.1),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: scheme.primary, size: 20),
    );
  }
}

void _openNotificationProfile(BuildContext context, _SocialNotification item) {
  final profile = item.profile;
  if (profile == null) return;
  context.push('/profile/${profile.userId}', extra: profile);
}

void _openNotificationPost(BuildContext context, _SocialNotification item) {
  if (item.postId != null) {
    context.push('/post/${item.postId}');
    return;
  }
  _openNotificationProfile(context, item);
}

enum _NotificationType { follow, like, reply, comment, event, repost }

class _SocialNotification {
  const _SocialNotification({
    required this.type,
    required this.profile,
    required this.message,
    required this.time,
    this.preview,
    this.postId,
  });

  final _NotificationType type;
  final PublicProfilePreview? profile;
  final String message;
  final String time;
  final String? preview;
  final String? postId;
}

_SocialNotification _notificationFromModel(SocialNotificationModel item) {
  return _SocialNotification(
    type: _notificationTypeFromString(item.type),
    profile: PublicProfilePreview(
      userId: item.actorUserId,
      displayName: item.actorName,
      handle: item.actorHandle,
      avatarUrl: item.actorAvatarUrl,
      premium: item.actorPremium,
    ),
    message: item.message,
    time: _relativeTime(item.createdAt),
    preview: item.preview,
    postId: item.postId,
  );
}

_NotificationType _notificationTypeFromString(String type) {
  return switch (type) {
    'follow' => _NotificationType.follow,
    'like' => _NotificationType.like,
    'reply' => _NotificationType.reply,
    'event' => _NotificationType.event,
    'repost' => _NotificationType.repost,
    _ => _NotificationType.comment,
  };
}

String _relativeTime(String createdAt) {
  final timestamp = DateTime.tryParse(createdAt)?.toLocal();
  if (timestamp == null) return 'now';
  final diff = DateTime.now().difference(timestamp);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  final weeks = (diff.inDays / 7).floor();
  if (weeks < 5) return '${weeks}w';
  return '${timestamp.month}/${timestamp.day}/${timestamp.year}';
}
