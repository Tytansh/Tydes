import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error_message.dart';
import '../home/home_page.dart' show meProvider;
import 'direct_message_api.dart';

final eventChatInboxRevisionProvider = StateProvider<int>((ref) => 0);
final eventChatControlsProvider =
    StateNotifierProvider<EventChatControlsController, EventChatControlState>((
      ref,
    ) {
      return EventChatControlsController(
        api: ref.watch(directMessageApiProvider),
        ownerId: ref.watch(meProvider.select((value) => value.valueOrNull?.id)),
        onConfirmedChange: () =>
            ref.read(eventChatInboxRevisionProvider.notifier).state++,
      );
    });

class EventChatSettings {
  const EventChatSettings({
    required this.userId,
    required this.postId,
    required this.muted,
    required this.left,
  });
  final String userId, postId;
  final bool muted, left;

  static EventChatSettings confirmed(
    Map<String, dynamic> data,
    String owner,
    String postId,
  ) {
    if (data['user_id'] != owner ||
        data['post_id'] != postId ||
        data['muted'] is! bool ||
        data['left'] is! bool) {
      throw StateError(
        'The event chat setting was not confirmed. Please retry.',
      );
    }
    return EventChatSettings(
      userId: owner,
      postId: postId,
      muted: data['muted'] as bool,
      left: data['left'] as bool,
    );
  }
}

class EventChatControlState {
  const EventChatControlState({
    this.settings = const {},
    this.pending = const {},
  });
  final Map<String, EventChatSettings> settings;
  final Set<String> pending;
}

/// Only confirmed account-bound server settings are retained in memory. The
/// server persists preferences; this is not a second device-local preference.
class EventChatControlsController extends StateNotifier<EventChatControlState> {
  EventChatControlsController({
    required DirectMessageApi api,
    required this.ownerId,
    required VoidCallback onConfirmedChange,
  }) : _api = api,
       _onConfirmedChange = onConfirmedChange,
       super(const EventChatControlState());
  final DirectMessageApi _api;
  final String? ownerId;
  final VoidCallback _onConfirmedChange;
  bool _disposed = false;
  final Map<String, int> _revisions = {};
  int revisionFor(String postId) => _revisions[postId] ?? 0;
  EventChatSettings? current(String postId) => state.settings[postId];
  void _check() {
    if (_disposed || ownerId == null) {
      throw StateError('Your account changed. Reopen this chat.');
    }
  }

  String _path(String postId) =>
      '/social/posts/${Uri.encodeComponent(postId)}/chat';

  Future<EventChatSettings> fetch(String postId) async {
    _check();
    final revision = revisionFor(postId);
    final session = await _api.openSession(ownerId!);
    final data = await session.getMap('${_path(postId)}/settings');
    _check();
    final settings = EventChatSettings.confirmed(data, ownerId!, postId);
    if (revision != revisionFor(postId)) {
      final latest = current(postId);
      if (latest != null) return latest;
      throw StateError('The event chat changed. Please retry.');
    }
    _store(settings);
    return settings;
  }

  Future<void> setMuted(String postId, bool muted) =>
      _change(postId, 'settings', {'muted': muted}, expectedMuted: muted);
  Future<void> leave(String postId) =>
      _change(postId, 'leave', const {}, expectedLeft: true);
  Future<void> join(String postId) =>
      _change(postId, 'join', const {}, expectedLeft: false);

  Future<void> _change(
    String postId,
    String action,
    Map<String, dynamic> data, {
    bool? expectedMuted,
    bool? expectedLeft,
  }) async {
    _check();
    if (state.pending.contains(postId)) {
      throw StateError('This event chat is still updating.');
    }
    _revisions[postId] = revisionFor(postId) + 1;
    state = EventChatControlState(
      settings: state.settings,
      pending: {...state.pending, postId},
    );
    try {
      final session = await _api.openSession(ownerId!);
      final response = action == 'settings'
          ? await session.patchMap('${_path(postId)}/settings', data)
          : await session.postMap('${_path(postId)}/$action', data);
      _check();
      final settings = EventChatSettings.confirmed(response, ownerId!, postId);
      if ((expectedMuted != null && settings.muted != expectedMuted) ||
          (expectedLeft != null && settings.left != expectedLeft)) {
        throw StateError(
          'The event chat change was not confirmed. Please retry.',
        );
      }
      _revisions[postId] = revisionFor(postId) + 1;
      _store(settings);
      _onConfirmedChange();
    } finally {
      if (!_disposed) {
        state = EventChatControlState(
          settings: state.settings,
          pending: {...state.pending}..remove(postId),
        );
      }
    }
  }

  void _store(EventChatSettings settings) {
    final previous = current(settings.postId);
    if (previous?.muted == settings.muted && previous?.left == settings.left) {
      return;
    }
    state = EventChatControlState(
      settings: {...state.settings, settings.postId: settings},
      pending: state.pending,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

enum _EventChatAction { mute, leave }

class EventChatOptionsButton extends ConsumerWidget {
  const EventChatOptionsButton({
    super.key,
    required this.postId,
    this.initialMuted = false,
    this.disabled = false,
  });
  final String postId;
  final bool initialMuted, disabled;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controls = ref.watch(eventChatControlsProvider);
    final settings = controls.settings[postId];
    final muted = settings?.muted ?? initialMuted;
    return PopupMenuButton<_EventChatAction>(
      tooltip: 'Event chat options',
      enabled: !disabled && !controls.pending.contains(postId),
      icon: const Icon(Icons.more_horiz_rounded),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: _EventChatAction.mute,
          child: Text(muted ? 'Unmute chat' : 'Mute chat'),
        ),
        if (settings?.left != true)
          const PopupMenuItem(
            value: _EventChatAction.leave,
            child: Text('Leave chat'),
          ),
      ],
      onSelected: (action) async {
        final controller = ref.read(eventChatControlsProvider.notifier);
        try {
          if (action == _EventChatAction.mute) {
            await controller.setMuted(postId, !muted);
          } else {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const Text('Leave event chat?'),
                content: const Text(
                  'This removes the chat from your messages. Your event RSVP will not change. You can rejoin the chat from the event.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                    child: const Text('Leave chat'),
                  ),
                ],
              ),
            );
            if (confirmed != true) return;
            await controller.leave(postId);
          }
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
