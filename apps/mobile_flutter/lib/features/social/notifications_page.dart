import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'social_profile.dart';

class SocialNotificationsPage extends StatelessWidget {
  const SocialNotificationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: _demoNotifications.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final item = _demoNotifications[index];
          return _NotificationTile(item: item);
        },
      ),
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
                          item.profile?.displayName.characters.first ?? 'T',
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

enum _NotificationType { like, reply, comment, event, repost }

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

const _demoNotifications = [
  _SocialNotification(
    type: _NotificationType.comment,
    profile: PublicProfilePreview(
      userId: 'friend_maya',
      displayName: 'Maya Surfer',
      handle: 'mayasurfer',
      location: 'Uluwatu',
    ),
    message: 'commented on your event.',
    time: '4m',
    preview: 'That warung meetup looks fun.',
    postId: 'post_bd2cdd58',
  ),
  _SocialNotification(
    type: _NotificationType.like,
    profile: PublicProfilePreview(
      userId: 'friend_lina',
      displayName: 'Lina Reef',
      handle: 'linareef',
      location: 'Canggu',
    ),
    message: 'liked your post.',
    time: '18m',
    preview: 'hi fool',
    postId: 'post_bd2cdd58',
  ),
  _SocialNotification(
    type: _NotificationType.event,
    profile: PublicProfilePreview(
      userId: 'friend_ari',
      displayName: 'Ari Dawn',
      handle: 'aridawn',
      location: 'Uluwatu',
    ),
    message: 'is going to your event.',
    time: '32m',
    preview: 'Balangan sunset tomorrow',
    postId: 'post_bd2cdd58',
  ),
  _SocialNotification(
    type: _NotificationType.repost,
    profile: PublicProfilePreview(
      userId: 'friend_jo',
      displayName: 'Jo Tide',
      handle: 'jotide',
      location: 'Siargao',
    ),
    message: 'reposted your event.',
    time: '1h',
    preview: 'Tomorrow paddle out',
    postId: 'post_bd2cdd58',
  ),
  _SocialNotification(
    type: _NotificationType.comment,
    profile: PublicProfilePreview(
      userId: 'friend_kai',
      displayName: 'Kai Glass',
      handle: 'kaiglass',
      location: 'Byron Bay',
    ),
    message: 'commented on your post.',
    time: '2h',
    preview: 'This spot looks firing.',
    postId: 'post_bd2cdd58',
  ),
];
