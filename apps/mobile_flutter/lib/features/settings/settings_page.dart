import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as image_tools;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/router.dart';
import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';
import '../home/home_page.dart';
import '../social/social_feed.dart';
import '../spots/spot_detail_page.dart';
import '../spots/spots_page.dart';

final friendsProvider = FutureProvider((ref) {
  ref.watch(socialRefreshKeyProvider);
  return ref.watch(surfRepositoryProvider).fetchFriends();
});

final socialPostsProvider = FutureProvider((ref) {
  ref.watch(socialRefreshKeyProvider);
  return ref.watch(surfRepositoryProvider).fetchSocialPosts();
});

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  Future<void> _openProfileSettings(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<UserProfile> me,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ProfileSettingsSheet(
        profile: me.valueOrNull,
        premium: me.valueOrNull?.premium ?? false,
        selectedLocale: ref.watch(localeProvider),
        onLocaleChanged: (locale) =>
            ref.read(localeProvider.notifier).state = locale,
        onEditProfile: me.valueOrNull == null
            ? null
            : () async {
                Navigator.of(context).pop();
                await showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (context) => _EditProfileSheet(
                    profile: me.valueOrNull!,
                  ),
                );
              },
        onManagePremium: () {
          Navigator.of(context).pop();
          context.push('/paywall');
        },
        onLogout: () async {
          await ref.read(surfRepositoryProvider).logout();
          ref.invalidate(meProvider);
          ref.invalidate(dashboardProvider);
          ref.invalidate(homeAdsProvider);
          ref.invalidate(spotsProvider);
          ref.invalidate(spotForecastProvider);
          ref.invalidate(spotTideProvider);
          ref.invalidate(spotDetailBundleProvider);
          if (!context.mounted) return;
          Navigator.of(context).pop();
          context.push('/login');
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final friends = ref.watch(friendsProvider);
    final posts = ref.watch(socialPostsProvider);
    final spots = ref.watch(spotsProvider);

    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        children: [
          me.when(
            data: (profile) => _ProfileHero(
              profile: profile,
              friendsCount: friends.valueOrNull?.length ?? 0,
              postsCount:
                  posts.valueOrNull
                      ?.where((post) => post.userId == profile.id)
                      .length ??
                  0,
              onSettingsPressed: () => _openProfileSettings(context, ref, me),
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Friends nearby',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              TextButton(onPressed: () {}, child: const Text('Find more')),
            ],
          ),
          const SizedBox(height: 10),
          friends.when(
            data: (items) => SizedBox(
              height: 124,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) =>
                    _FriendCard(friend: items[index]),
              ),
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Text('Could not load crew: $error'),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Your posts',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              TextButton.icon(
                onPressed: () =>
                    ref.read(currentTabProvider.notifier).state = 0,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Post'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          me.when(
            data: (profile) => posts.when(
              data: (items) => _ProfilePostFeed(
                profile: profile,
                posts: items
                    .where((post) => post.userId == profile.id)
                    .toList(),
                spots: spots.valueOrNull ?? const [],
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Text('Could not load posts: $error'),
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _ProfileHero extends StatelessWidget {
  const _ProfileHero({
    required this.profile,
    required this.friendsCount,
    required this.postsCount,
    required this.onSettingsPressed,
  });

  final UserProfile profile;
  final int friendsCount;
  final int postsCount;
  final VoidCallback onSettingsPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF082D35), Color(0xFF0D6F65), Color(0xFFE9B872)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: CircleAvatar(
                  radius: 34,
                  backgroundColor: Colors.white,
                  backgroundImage: profile.avatarUrl == null
                      ? null
                      : NetworkImage(profile.avatarUrl!),
                  child: profile.avatarUrl == null
                      ? Text(
                          profile.displayName.characters.first,
                          style: const TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF0B6E6E),
                          ),
                        )
                      : null,
                ),
              ),
              const Spacer(),
              _ProfileStat(value: postsCount.toString(), label: 'Posts'),
              const SizedBox(width: 18),
              _ProfileStat(value: friendsCount.toString(), label: 'Friends'),
              const SizedBox(width: 18),
              const _ProfileStat(value: '14', label: 'Followers'),
              const SizedBox(width: 10),
              IconButton(
                onPressed: onSettingsPressed,
                tooltip: 'Profile settings',
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.14),
                  foregroundColor: Colors.white,
                  side: BorderSide(
                    color: Colors.white.withValues(alpha: 0.24),
                  ),
                ),
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  profile.displayName,
                  style: Theme.of(
                    context,
                  ).textTheme.headlineMedium?.copyWith(color: Colors.white),
                ),
              ),
              if (profile.premium) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.24),
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.verified_rounded,
                        size: 14,
                        color: Colors.white,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'Premium',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '@${profile.handle} • ${profile.homeRegion} • ${_skillLabel(profile.surfSkill)}',
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 12),
          Text(
            profile.bio,
            style: TextStyle(color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _ProfileStat extends StatelessWidget {
  const _ProfileStat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w900,
          ),
        ),
        Text(label, style: const TextStyle(color: Colors.white70)),
      ],
    );
  }
}

class _ProfileSettingsSheet extends StatelessWidget {
  const _ProfileSettingsSheet({
    required this.profile,
    required this.premium,
    required this.selectedLocale,
    required this.onLocaleChanged,
    required this.onEditProfile,
    required this.onManagePremium,
    required this.onLogout,
  });

  final UserProfile? profile;
  final bool premium;
  final Locale selectedLocale;
  final ValueChanged<Locale> onLocaleChanged;
  final VoidCallback? onEditProfile;
  final VoidCallback onManagePremium;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD5D0C6),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Profile settings',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 14),
            if (profile != null) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit profile'),
                subtitle: Text('@${profile!.handle}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: onEditProfile,
              ),
              const Divider(),
            ],
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                premium ? Icons.verified : Icons.workspace_premium_outlined,
              ),
              title: Text(premium ? 'Premium active' : 'Manage premium'),
              subtitle: const Text('Forecast access and future upgrades'),
              trailing: const Icon(Icons.chevron_right),
              onTap: onManagePremium,
            ),
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.language),
              title: const Text('Language'),
              subtitle: const Text('App display language'),
              trailing: SegmentedButton<Locale>(
                segments: const [
                  ButtonSegment<Locale>(value: Locale('en'), label: Text('EN')),
                  ButtonSegment<Locale>(value: Locale('id'), label: Text('ID')),
                ],
                selected: {selectedLocale},
                onSelectionChanged: (selection) =>
                    onLocaleChanged(selection.first),
              ),
            ),
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.logout),
              title: const Text('Log out'),
              subtitle: const Text('Switch demo account'),
              onTap: onLogout,
            ),
          ],
        ),
      ),
    );
  }
}

class _EditProfileSheet extends ConsumerStatefulWidget {
  const _EditProfileSheet({required this.profile});

  final UserProfile profile;

  @override
  ConsumerState<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends ConsumerState<_EditProfileSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _handleController;
  late final TextEditingController _bioController;
  final _imagePicker = ImagePicker();
  String _skill = 'intermediate';
  XFile? _avatarImage;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.profile.displayName);
    _handleController = TextEditingController(text: widget.profile.handle);
    _bioController = TextEditingController(text: widget.profile.bio);
    _skill = widget.profile.surfSkill;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _handleController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final displayName = _nameController.text.trim();
    final handle = _handleController.text.trim().replaceAll('@', '');
    final bio = _bioController.text.trim();

    if (displayName.isEmpty || handle.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name and @tag are required.')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      String? avatarUrl = widget.profile.avatarUrl;
      final avatarImage = _avatarImage;
      if (avatarImage != null) {
        final thumbnail = await _createProfileThumbnail(avatarImage);
        final uploaded = await ref
            .read(surfRepositoryProvider)
            .uploadPostPhoto(image: avatarImage, thumbnail: thumbnail);
        avatarUrl = uploaded.thumbnailUrl;
      }
      await ref.read(surfRepositoryProvider).updateProfile(
            displayName: displayName,
            handle: handle,
            bio: bio,
            surfSkill: _skill,
            avatarUrl: avatarUrl,
          );
      ref.invalidate(meProvider);
      ref.invalidate(socialPostsProvider);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Bad state: ', ''))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickAvatar() async {
    final picked = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1400,
      imageQuality: 80,
      requestFullMetadata: false,
    );
    if (picked == null || !mounted) return;
    setState(() => _avatarImage = picked);
  }

  Future<XFile> _createProfileThumbnail(XFile source) async {
    final bytes = await source.readAsBytes();
    final decoded = image_tools.decodeImage(bytes);
    if (decoded == null) return source;

    final resized = image_tools.copyResizeCropSquare(decoded, size: 500);
    final encoded = image_tools.encodeJpg(resized, quality: 72);
    final tempDir = await getTemporaryDirectory();
    final path =
        '${tempDir.path}/profile_thumb_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final file = await File(path).writeAsBytes(encoded, flush: true);
    return XFile(
      file.path,
      name: file.uri.pathSegments.last,
      mimeType: 'image/jpeg',
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 24 + bottomInset),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD5D0C6),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Edit profile',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              Center(
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 42,
                      backgroundColor: const Color(0xFFE6F3F1),
                      backgroundImage: _avatarImage != null
                          ? FileImage(File(_avatarImage!.path))
                          : (widget.profile.avatarUrl != null
                                ? NetworkImage(widget.profile.avatarUrl!)
                                : null) as ImageProvider<Object>?,
                      child: _avatarImage == null && widget.profile.avatarUrl == null
                          ? Text(
                              widget.profile.displayName.characters.first,
                              style: const TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF0B6E6E),
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(height: 10),
                    TextButton.icon(
                      onPressed: _saving ? null : _pickAvatar,
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('Change profile picture'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _nameController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Your display name',
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _handleController,
                decoration: const InputDecoration(
                  labelText: '@tag',
                  hintText: 'yourtag',
                  prefixText: '@',
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Surf level',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment<String>(
                    value: 'beginner',
                    label: Text('Beginner'),
                  ),
                  ButtonSegment<String>(
                    value: 'intermediate',
                    label: Text('Skilled'),
                  ),
                  ButtonSegment<String>(
                    value: 'pro',
                    label: Text('Pro'),
                  ),
                ],
                selected: {_skill},
                onSelectionChanged: _saving
                    ? null
                    : (selection) => setState(() => _skill = selection.first),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _bioController,
                maxLines: 4,
                maxLength: 180,
                decoration: const InputDecoration(
                  labelText: 'Bio',
                  hintText: 'Tell people what kind of waves and surf trips you are into.',
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Saving...' : 'Save profile'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _skillLabel(String skill) {
  switch (skill) {
    case 'beginner':
      return 'Beginner';
    case 'pro':
      return 'Pro';
    default:
      return 'Skilled';
  }
}

class _FriendCard extends StatelessWidget {
  const _FriendCard({required this.friend});

  final FriendProfileModel friend;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 116,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CircleAvatar(radius: 22, child: Text(friend.avatarEmoji)),
              const SizedBox(height: 6),
              Text(
                friend.displayName,
                maxLines: 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                friend.homeRegion,
                maxLines: 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfilePostFeed extends StatelessWidget {
  const _ProfilePostFeed({
    required this.profile,
    required this.posts,
    required this.spots,
  });

  final UserProfile profile;
  final List<SocialPostModel> posts;
  final List<SpotModel> spots;

  @override
  Widget build(BuildContext context) {
    if (posts.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              const Icon(Icons.forum_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Your posts, photos, and surf notes will show up here.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: posts
          .map(
            (post) => Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: _ProfilePostCard(
                profile: profile,
                post: post,
                spots: spots,
              ),
            ),
          )
          .toList(),
    );
  }
}

class _ProfilePostCard extends StatelessWidget {
  const _ProfilePostCard({
    required this.profile,
    required this.post,
    required this.spots,
  });

  final UserProfile profile;
  final SocialPostModel post;
  final List<SpotModel> spots;

  @override
  Widget build(BuildContext context) {
    final spot = _profileSpotForId(spots, post.spotId);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: Colors.white,
                  backgroundImage: profile.avatarUrl == null
                      ? null
                      : NetworkImage(profile.avatarUrl!),
                  child: profile.avatarUrl == null
                      ? Text(profile.displayName.characters.first)
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              profile.displayName,
                              style: const TextStyle(fontWeight: FontWeight.w800),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (profile.premium) ...[
                            const SizedBox(width: 6),
                            const Icon(
                              Icons.verified_rounded,
                              size: 16,
                              color: Color(0xFF2AA7A1),
                            ),
                          ],
                        ],
                      ),
                      Text(
                        '@${profile.handle} • ${_profileVisibilityLabel(post.visibility)} post',
                      ),
                    ],
                  ),
                ),
                if (spot != null)
                  ActionChip(
                    avatar: const Icon(Icons.place_outlined, size: 16),
                    label: Text(spot.name),
                    onPressed: () => context.push('/spot/${spot.id}'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (post.media.isNotEmpty) ...[
              SocialPostMediaCarousel(
                media: post.media,
                borderRadius: 20,
              ),
              const SizedBox(height: 12),
            ],
            if (post.body.isNotEmpty)
              Text(post.body, style: Theme.of(context).textTheme.bodyLarge),
          ],
        ),
      ),
    );
  }
}

SpotModel? _profileSpotForId(List<SpotModel> spots, String? spotId) {
  if (spotId == null) return null;
  for (final spot in spots) {
    if (spot.id == spotId) return spot;
  }
  return null;
}

String _profileVisibilityLabel(String visibility) {
  switch (visibility) {
    case 'friends':
      return 'Friends';
    default:
      return 'Public';
  }
}
