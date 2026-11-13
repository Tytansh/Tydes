import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_models.dart';
import '../../core/network/social_feed_page.dart';
import '../../core/network/surf_repository.dart';
import '../home/home_page.dart' show meProvider;
import 'feed_engagement.dart';

final StateNotifierProvider<FeedPaginationController, FeedPaginationState>
feedPaginationProvider =
    StateNotifierProvider<FeedPaginationController, FeedPaginationState>((ref) {
      final refreshKey = ref.watch(socialRefreshKeyProvider);
      final accountId = ref.watch(
        meProvider.select((account) => account.valueOrNull?.id),
      );
      final repository = ref.watch(surfRepositoryProvider);
      return FeedPaginationController(
        accountId: accountId,
        loadPage: (cursor) => repository.fetchSocialFeedPage(cursor: cursor),
        onPageLoaded: (page) {
          final current = ref.read(feedPaginationProvider);
          applyFeedPageEngagement(
            ref,
            page,
            accountId: accountId,
            refreshKey: refreshKey,
            // A repost can expose its original again on a later page. Do not
            // overwrite a newer like/comment action with that older request.
            preservePostIds: current.isLoadingInitial
                ? const {}
                : current.entries.map((entry) => entry.post.id).toSet(),
          );
        },
      );
    });

class FeedPaginationState {
  const FeedPaginationState({
    this.entries = const [],
    this.nextCursor,
    this.initialized = false,
    this.isLoadingInitial = false,
    this.isLoadingMore = false,
    this.error,
    this.refreshFailed = false,
  });

  final List<SocialFeedEntry> entries;
  final String? nextCursor;
  final bool initialized;
  final bool isLoadingInitial;
  final bool isLoadingMore;
  final Object? error;
  final bool refreshFailed;

  bool get canLoadMore =>
      initialized &&
      nextCursor != null &&
      !isLoadingInitial &&
      !isLoadingMore &&
      error == null;

  FeedPaginationState update({
    List<SocialFeedEntry>? entries,
    String? nextCursor,
    bool replaceCursor = false,
    bool? initialized,
    bool? isLoadingInitial,
    bool? isLoadingMore,
    Object? error,
    bool? refreshFailed,
  }) => FeedPaginationState(
    entries: entries ?? this.entries,
    nextCursor: replaceCursor ? nextCursor : this.nextCursor,
    initialized: initialized ?? this.initialized,
    isLoadingInitial: isLoadingInitial ?? this.isLoadingInitial,
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    error: error,
    refreshFailed: refreshFailed ?? this.refreshFailed,
  );
}

/// Account-scoped paging. Only the initial page Future affects first-load UI;
/// appends keep the existing rows and cursor intact until confirmed successful.
class FeedPaginationController extends StateNotifier<FeedPaginationState> {
  FeedPaginationController({
    required this.accountId,
    required Future<SocialFeedPage> Function(String? cursor) loadPage,
    void Function(SocialFeedPage page)? onPageLoaded,
  }) : _loadPage = loadPage,
       _onPageLoaded = onPageLoaded,
       super(const FeedPaginationState());

  final String? accountId;
  final Future<SocialFeedPage> Function(String? cursor) _loadPage;
  final void Function(SocialFeedPage page)? _onPageLoaded;
  int _revision = 0;
  bool _disposed = false;
  Future<void>? _append;

  Future<List<SocialPostModel>> refreshInitial() async {
    final revision = ++_revision;
    _append = null;
    // This method is called by a FutureProvider facade. Do not write another
    // provider synchronously while that provider is being constructed.
    await Future<void>.value();
    if (!_current(revision) || accountId == null) return const [];
    state = state.update(isLoadingInitial: true, isLoadingMore: false);
    try {
      final page = await _loadPage(null);
      if (!_current(revision)) return const [];
      _onPageLoaded?.call(page);
      final entries = _merge(const [], page.items);
      state = FeedPaginationState(
        entries: entries,
        nextCursor: page.nextCursor,
        initialized: true,
      );
      return _uniquePosts(entries);
    } catch (error, stackTrace) {
      if (!_current(revision)) return const [];
      state = state.update(
        isLoadingInitial: false,
        isLoadingMore: false,
        error: error,
        refreshFailed: true,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> loadMore({bool retry = false}) {
    if (_disposed || accountId == null || state.isLoadingInitial) {
      return Future<void>.value();
    }
    if (_append != null) return _append!;
    if (!state.initialized ||
        state.nextCursor == null ||
        (state.error != null && !retry)) {
      return Future<void>.value();
    }
    final cursor = state.nextCursor!;
    final revision = _revision;
    late final Future<void> operation;
    operation = _loadMore(cursor, revision).whenComplete(() {
      if (identical(_append, operation)) _append = null;
    });
    return _append = operation;
  }

  Future<void> _loadMore(String cursor, int revision) async {
    await Future<void>.value();
    if (!_current(revision)) return;
    state = state.update(isLoadingMore: true, refreshFailed: false);
    try {
      final page = await _loadPage(cursor);
      if (!_current(revision)) return;
      if (page.nextCursor == cursor) {
        throw StateError('The feed cursor did not advance. Try refreshing.');
      }
      _onPageLoaded?.call(page);
      state = state.update(
        entries: _merge(state.entries, page.items),
        nextCursor: page.nextCursor,
        replaceCursor: true,
        isLoadingMore: false,
      );
    } catch (error) {
      if (_current(revision)) {
        state = state.update(isLoadingMore: false, error: error);
      }
    }
  }

  Future<void> retry() async {
    if (_disposed) return;
    if (state.refreshFailed || !state.initialized) {
      try {
        await refreshInitial();
      } catch (_) {
        // Confirmed errors remain in state; a retry never invents success.
      }
    } else {
      await loadMore(retry: true);
    }
  }

  bool _current(int revision) => !_disposed && revision == _revision;

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    super.dispose();
  }
}

/// The compatibility FutureProvider may retain its previous value while a new
/// account loads. Tag real results so those previous-account rows stay hidden.
class AccountScopedFeedPosts extends UnmodifiableListView<SocialPostModel> {
  AccountScopedFeedPosts({
    required this.accountId,
    required List<SocialPostModel> posts,
  }) : super(posts);

  final String? accountId;
}

List<SocialFeedEntry> _merge(
  List<SocialFeedEntry> previous,
  List<SocialFeedEntry> incoming,
) {
  final seen = {for (final entry in previous) entry.entryId};
  return List.unmodifiable([
    ...previous,
    for (final entry in incoming)
      if (seen.add(entry.entryId)) entry,
  ]);
}

List<SocialPostModel> _uniquePosts(List<SocialFeedEntry> entries) {
  final seen = <String>{};
  return [
    for (final entry in entries)
      if (seen.add(entry.post.id)) entry.post,
  ];
}
