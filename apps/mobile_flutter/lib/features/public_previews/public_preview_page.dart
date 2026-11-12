import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/network/api_error_message.dart';
import '../../core/network/api_models.dart';
import '../../core/network/public_preview_models.dart';
import '../../core/network/surf_repository.dart';
import '../auth/auth_return_path.dart';
import '../home/home_page.dart';
import '../social/post_detail_page.dart';
import '../social/social_profile.dart';
import '../spots/spot_detail_page.dart';
import 'public_link_button.dart';

final publicSpotPreviewProvider = FutureProvider.autoDispose
    .family<PublicSpotPreview, String>(
      (ref, id) => ref.watch(surfRepositoryProvider).fetchPublicSpot(id),
    );
final publicEventPreviewProvider = FutureProvider.autoDispose
    .family<PublicEventPreview, String>(
      (ref, id) => ref.watch(surfRepositoryProvider).fetchPublicEvent(id),
    );

bool _complete(AsyncValue<UserProfile> me) =>
    !me.isLoading &&
    !me.hasError &&
    me.valueOrNull != null &&
    me.valueOrNull!.emailVerified &&
    me.valueOrNull!.displayName.trim().isNotEmpty &&
    me.valueOrNull!.handle.trim().isNotEmpty &&
    me.valueOrNull!.surfSkill.trim().isNotEmpty;

class SharedSpotPage extends ConsumerWidget {
  const SharedSpotPage({super.key, required this.spotId});
  final String spotId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final verificationRequired =
        ref.watch(emailVerificationRequiredTokenProvider) != null;
    if (!verificationRequired && _complete(me)) {
      return SpotDetailPage(spotId: spotId);
    }
    return _Frame(
      path: '/spot/$spotId',
      profile: me.hasError || me.isLoading ? null : me.valueOrNull,
      child: ref
          .watch(publicSpotPreviewProvider(spotId))
          .when(
            data: (spot) => _SpotContent(
              spot: spot,
              profile: me.hasError || me.isLoading ? null : me.valueOrNull,
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => _Failure(
              error: error,
              event: false,
              retry: () => ref.invalidate(publicSpotPreviewProvider(spotId)),
            ),
          ),
    );
  }
}

class SharedEventPage extends ConsumerWidget {
  const SharedEventPage({super.key, required this.postId});
  final String postId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final verificationRequired =
        ref.watch(emailVerificationRequiredTokenProvider) != null;
    if (!verificationRequired && _complete(me)) {
      return PostDetailPage(postId: postId);
    }
    return _Frame(
      path: '/post/$postId',
      profile: me.hasError || me.isLoading ? null : me.valueOrNull,
      child: ref
          .watch(publicEventPreviewProvider(postId))
          .when(
            data: (event) => _EventContent(
              event: event,
              profile: me.hasError || me.isLoading ? null : me.valueOrNull,
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => _Failure(
              error: error,
              event: true,
              retry: () => ref.invalidate(publicEventPreviewProvider(postId)),
            ),
          ),
    );
  }
}

void _login(BuildContext context, String path, UserProfile? profile) {
  final incomplete =
      profile != null &&
      (profile.displayName.trim().isEmpty ||
          profile.handle.trim().isEmpty ||
          profile.surfSkill.trim().isEmpty);
  context.go(loginForPath(path), extra: incomplete ? profile : null);
}

class _Frame extends StatelessWidget {
  const _Frame({
    required this.path,
    required this.profile,
    required this.child,
  });
  final String path;
  final UserProfile? profile;
  final Widget child;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset(
              'assets/branding/tydes-wave-blue-256.png',
              width: 38,
              height: 38,
            ),
          ),
          const SizedBox(width: 10),
          const Text('TYDES', style: TextStyle(fontWeight: FontWeight.w800)),
        ],
      ),
      leading: IconButton(
        tooltip: 'Explore TYDES',
        icon: const Icon(Icons.arrow_back),
        onPressed: () =>
            context.canPop() ? context.pop() : context.go('/explore'),
      ),
      actions: [
        TextButton(
          onPressed: () => _login(context, path, profile),
          child: const Text('Sign in'),
        ),
        const SizedBox(width: 12),
      ],
    ),
    body: SelectionArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 940),
            child: child,
          ),
        ),
      ),
    ),
  );
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.label,
    required this.title,
    required this.subtitle,
    required this.url,
  });
  final String label, title, subtitle, url;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(28),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(28),
      gradient: const LinearGradient(
        colors: [Color(0xFF07576B), Color(0xFF0CA8AC), Color(0xFF91CAB8)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.waves, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            CopyPublicLinkButton(url: url),
          ],
        ),
        const SizedBox(height: 22),
        Text(
          title,
          style: const TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            subtitle,
            style: const TextStyle(
              fontSize: 17,
              color: Colors.white,
              height: 1.4,
            ),
          ),
        ],
      ],
    ),
  );
}

Widget _card(Widget child) => Card(
  child: Padding(padding: const EdgeInsets.all(24), child: child),
);

class _SpotContent extends StatelessWidget {
  const _SpotContent({required this.spot, required this.profile});
  final PublicSpotPreview spot;
  final UserProfile? profile;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Hero(
        label: 'SURF SPOT',
        title: spot.name,
        subtitle: '${spot.area}, ${spot.region}, ${spot.country}',
        url: publicSpotLink(spot.id),
      ),
      const SizedBox(height: 18),
      _card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'About this break',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Text(
              spot.summary,
              style: const TextStyle(fontSize: 17, height: 1.5),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                Chip(label: Text('Level: ${spot.difficulty}')),
                if (spot.bestMonths.isNotEmpty)
                  Chip(
                    label: Text(
                      'Typical season: ${spot.bestMonths.join(', ')}',
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'A spot guide, not a live forecast. Check local hazards and conditions before surfing.',
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      _Action(
        title: 'Make it your next surf stop',
        text:
            'Sign in to save this spot, open the surf map, and view the forecast options available to your account.',
        button: 'Sign in to explore this spot',
        onTap: () => _login(context, '/spot/${spot.id}', profile),
      ),
    ],
  );
}

class _EventContent extends StatelessWidget {
  const _EventContent({required this.event, required this.profile});
  final PublicEventPreview event;
  final UserProfile? profile;
  String _date(String? date) => date == null
      ? 'Date to be confirmed'
      : DateFormat('EEE, MMM d, y').format(DateTime.parse(date));
  @override
  Widget build(BuildContext context) {
    final firstLine = event.body.trim().split('\n').first;
    final title = firstLine.isEmpty
        ? 'Surf meetup'
        : firstLine.length > 100
        ? '${firstLine.substring(0, 100)}…'
        : firstLine;
    final spot = event.spot;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Hero(
          label: event.ended ? 'PAST PUBLIC EVENT' : 'PUBLIC SURF EVENT',
          title: title,
          subtitle:
              '${_date(event.meetupDate)}${event.meetupEndDate != null && event.meetupEndDate != event.meetupDate ? ' – ${_date(event.meetupEndDate)}' : ''}',
          url: publicEventLink(event.id),
        ),
        const SizedBox(height: 18),
        _card(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  TydesProfileAvatar(
                    displayName: event.hostName,
                    imageUrl: event.hostAvatarUrl,
                    size: 48,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Hosted by ${event.hostName}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        if (event.hostHandle != null &&
                            event.hostHandle!.isNotEmpty)
                          Text('@${event.hostHandle}'),
                      ],
                    ),
                  ),
                ],
              ),
              if (event.body.isNotEmpty) ...[
                const SizedBox(height: 22),
                Text(
                  event.body,
                  style: const TextStyle(fontSize: 17, height: 1.5),
                ),
              ],
              if (spot != null) ...[
                const Divider(height: 36),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.place_outlined),
                  title: Text(spot.name),
                  subtitle: Text(
                    '${spot.area}, ${spot.region}, ${spot.country}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/spot/${spot.id}'),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        _Action(
          title: event.ended ? 'This event has ended' : 'Surf with the crew',
          text: event.ended
              ? 'Sign in to view the original event post.'
              : 'Sign in to join this event, see who’s going, and access its group chat. Joining is confirmed inside TYDES.',
          button: event.ended
              ? 'Sign in to view event'
              : 'Sign in to join event',
          onTap: () => _login(context, '/post/${event.id}', profile),
        ),
      ],
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.title,
    required this.text,
    required this.button,
    required this.onTap,
  });
  final String title, text, button;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).brightness == Brightness.dark
        ? Theme.of(context).colorScheme.surfaceContainerHigh
        : const Color(0xFFE7F4F2),
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          Text(text, style: const TextStyle(height: 1.5)),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onTap,
            icon: const Icon(Icons.login),
            label: Text(button),
          ),
        ],
      ),
    ),
  );
}

class _Failure extends StatelessWidget {
  const _Failure({
    required this.error,
    required this.event,
    required this.retry,
  });
  final Object error;
  final bool event;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => _card(
    Column(
      children: [
        const Icon(Icons.info_outline, size: 36),
        const SizedBox(height: 16),
        Text(
          event
              ? 'This event isn’t available publicly. It may be private or no longer available.'
              : 'This spot preview is unavailable.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        Text(friendlyErrorMessage(error), textAlign: TextAlign.center),
        const SizedBox(height: 18),
        OutlinedButton.icon(
          onPressed: retry,
          icon: const Icon(Icons.refresh),
          label: const Text('Retry'),
        ),
      ],
    ),
  );
}
