import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/app/router.dart';
import 'package:mobile_flutter/core/network/api_models.dart';
import 'package:mobile_flutter/core/widgets/media_image_strategy.dart';
import 'package:mobile_flutter/features/core/app_scaffold.dart';
import 'package:mobile_flutter/features/home/home_page.dart';
import 'package:mobile_flutter/features/social/social_feed.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

UserProfile _viewer() => UserProfile.fromJson({
  'id': 'performance-viewer',
  'email': 'performance@example.invalid',
  'display_name': 'Performance Surfer',
  'handle': 'performance',
  'surf_skill': 'intermediate',
  'home_region': 'Bali',
  'locale': 'en',
  'email_verified': true,
});

class _PageProbe extends StatefulWidget {
  const _PageProbe(this.index, this.mounts);
  final int index;
  final List<int> mounts;

  @override
  State<_PageProbe> createState() => _PageProbeState();
}

class _PageProbeState extends State<_PageProbe> {
  int taps = 0;
  @override
  void initState() {
    super.initState();
    widget.mounts[widget.index]++;
  }

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => taps++),
    child: Text('Page ${widget.index}: $taps'),
  );
}

void main() {
  testWidgets('lazy feed restores the selected photo without retaining media', (
    tester,
  ) async {
    final bucket = PageStorageBucket();
    final media = List.generate(
      3,
      (i) => SocialMediaAttachmentModel.fromJson({
        'id': 'retained-photo-$i',
        'media_type': 'photo',
        'url': 'https://image.example.invalid/$i.jpg',
        'thumbnail_url': 'https://image.example.invalid/$i.jpg',
      }),
    );
    Widget host(bool visible) => MaterialApp(
      home: Scaffold(
        body: PageStorage(
          bucket: bucket,
          child: visible
              ? SocialPostMediaCarousel(media: media)
              : const SizedBox(),
        ),
      ),
    );
    await tester.pumpWidget(host(true));
    tester.widget<PageView>(find.byType(PageView)).controller!.jumpToPage(2);
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(false));
    await tester.pumpWidget(host(true));
    await tester.pumpAndSettle();
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 2);
    expect(tester.takeException(), isNull);
  });

  test(
    'legacy media skips failed byte fetch; other CDNs keep canvas decoding',
    () {
      expect(
        mediaImageStrategy('https://media.tydes.io/image.jpg'),
        WebHtmlElementStrategy.prefer,
      );
      expect(
        mediaImageStrategy('https://example.b-cdn.net/thumbnail.jpg'),
        WebHtmlElementStrategy.fallback,
      );
      expect(
        mediaImageStrategy('https://media.tydes.io.attacker.invalid/image.jpg'),
        WebHtmlElementStrategy.fallback,
      );
    },
  );

  test('post viewer shares the verified shell account request', () async {
    var reads = 0;
    final container = ProviderContainer(
      overrides: [
        meProvider.overrideWith((_) async {
          reads++;
          return _viewer();
        }),
      ],
    );
    addTearDown(container.dispose);
    final profile = await container.read(meProvider.future);
    expect(await container.read(currentViewerProvider.future), same(profile));
    expect(reads, 1);
  });

  testWidgets('liking one post does not rebuild another engagement bar', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [currentViewerProvider.overrideWith((_) async => _viewer())],
    );
    addTearDown(container.dispose);
    SocialPostModel post(String id) => SocialPostModel.fromJson({
      'id': id,
      'user_id': 'other-surfer',
      'author_name': 'Surfer',
      'post_type': 'post',
      'body': 'Surf post',
      'created_at': '2026-11-12',
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                PostEngagementBar(
                  key: const ValueKey('bar-a'),
                  post: post('a'),
                ),
                PostEngagementBar(
                  key: const ValueKey('bar-b'),
                  post: post('b'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Column body(String id) => tester.widget<Column>(
      find
          .descendant(
            of: find.byKey(ValueKey(id)),
            matching: find.byType(Column),
          )
          .first,
    );
    final beforeA = body('bar-a');
    final beforeB = body('bar-b');
    container.read(likedPostIdsProvider.notifier).state = {'a'};
    await tester.pump();
    expect(body('bar-a'), isNot(same(beforeA)));
    expect(body('bar-b'), same(beforeB));
  });

  testWidgets('mobile shell defers unvisited tabs and retains visited state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final mounts = List.filled(5, 0);
    final container = ProviderContainer(
      overrides: [
        meProvider.overrideWith((_) async => _viewer()),
        shellPagesProvider.overrideWithValue([
          for (var i = 0; i < 5; i++) _PageProbe(i, mounts),
        ]),
        socialRelationshipHydrationProvider.overrideWith((_) async {}),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AppScaffold()),
      ),
    );
    await tester.pumpAndSettle();
    // This also bounds the startup work/data providers inside the other tabs.
    expect(mounts, [1, 0, 0, 0, 0]);
    await tester.tap(find.text('Page 0: 0'));
    await tester.pump();
    container.read(currentTabProvider.notifier).state = 4;
    await tester.pumpAndSettle();
    expect(mounts, [1, 0, 0, 0, 1]);
    container.read(currentTabProvider.notifier).state = 0;
    await tester.pumpAndSettle();
    expect(find.text('Page 0: 1'), findsOneWidget);
    expect(mounts, [1, 0, 0, 0, 1]);
  });

  testWidgets('100-post mobile feed mounts only viewport and cache rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final posts = List.generate(
      100,
      (i) => SocialPostModel.fromJson({
        'id': 'performance-post-$i',
        'user_id': 'surfer-$i',
        'author_name': 'Surfer $i',
        'author_handle': 'surfer$i',
        'post_type': 'post',
        'body': 'Performance fixture post $i',
        'created_at': DateTime.utc(
          2026,
          11,
          12,
        ).subtract(Duration(minutes: i)).toIso8601String(),
      }),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          meProvider.overrideWith((_) async => _viewer()),
          currentViewerProvider.overrideWith((_) async => _viewer()),
          travelFeedPostsProvider.overrideWith((_) async => posts),
          travelFeedSpotsProvider.overrideWith((_) async => []),
          socialEngagementHydrationProvider.overrideWith((_) async {}),
          socialRelationshipHydrationProvider.overrideWith((_) async {}),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();
    final mountedRows = find.byType(PostEngagementBar).evaluate().length;
    // A deterministic regression budget, not a synthetic claim about FPS.
    // ignore: avoid_print
    print('MOBILE_FEED_MOUNTED_ROWS=$mountedRows / ${posts.length}');
    expect(mountedRows, lessThan(10));
    await tester.enterText(find.byType(TextField).first, 'Unsent surf comment');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(find.byType(PostEngagementBar).evaluate().length, lessThan(10));
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(6000);
    await tester.pumpAndSettle();
    position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('Unsent surf comment'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
