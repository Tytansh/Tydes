# Mobile web performance audit — 13 November 2026

## Scope and method

TYDES is Flutter Web / Riverpod, not React. This pass preserves the existing
design, account checks, billing, media controls, maps and refresh behavior.
Production releases were measured incrementally on tydes.io using Chrome
DevTools Lighthouse 13.5, mobile Moto G Power emulation, 4× CPU slowdown and
DevTools Slow 4G throttling. An extension-free Incognito session was used after
the first normal-profile recording exposed substantial password-manager work.
Storage clearing was disabled to preserve the signed-in account. Therefore,
"new bundle" below means a fresh app-script download, **not a completely cold
browser**: the Flutter engine and other assets could already be cached.

Raw reports and traces are retained locally in `output/tydes-mobile-*`. Do not
publish those raw files; they can include account/post URLs and screenshots.
No service credentials were copied into this report or the frontend. No paid
service, billing plan, media access policy or shared API cache was changed.

## Measurements

Single-run lab observations, not field percentiles or an Instagram comparison:

| Production stage | FCP | LCP | Recorded JS work | Total blocking time |
| --- | ---: | ---: | ---: | ---: |
| Original, app script cached | 1.53 s | 14.56 s | 37.96 s | Incomplete: CPU-idle timeout |
| Lazy tabs, new app bundle | 1.28 s | 20.46 s | 30.51 s | 76 ms |
| Lazy feed, new app bundle | 1.64 s | 20.17 s | 4.01 s | 44 ms |
| Media/startup fixes, new app bundle | 1.94 s | 18.69 s | 4.12 s | 55 ms |
| Media/startup fixes, app script cached | 0.96 s | 9.30 s | 3.98 s | 1,204 ms |

The first two reports timed out; later reports finished without warnings.
Capture lengths, cache state and network variation differ. Do not describe
these as a controlled percentage speedup. The cached final run still has
significant blocking work. FCP includes the HTML startup screen; it is not the
time to a usable feed. Flutter canvas content also limits what browser LCP/CLS
can describe. Reported CLS was zero, not proof that every in-app layout is stable.

A 19.57-second production scrolling recording at 390 × 844 and 4× CPU slowdown
captured 437 target-renderer animation callbacks: median 7.10 ms, p95 12.41 ms,
10 above 16.7 ms and 4 above 50 ms. This recording included idle/loading time
and a small set of wheel gestures, with network throttling off after load.
Callback duration is **not frame presentation time or proof of sustained 60 FPS**.
Real iPhone Safari testing and a repeatable long-feed frame benchmark remain.

## Findings and changes

### 1. Initial JavaScript and execution

- Deferred the image codec library until photo composition/profile-image work
  actually needs it; both deferred chunks ship with the release.
- Initial app JavaScript decreased from 5,068,507 to 4,727,038 bytes (about 6.7%).
  Deterministic gzip size decreased from 1,450,257 to 1,350,972 bytes.
- Added early discovery of `main.dart.js` and connection hints for the engine,
  API and legacy media origins. No account data is preloaded publicly.
- Added a release-size gate in `apps/mobile_flutter/tool/verify_mobile_performance.mjs`.
- Remaining: Flutter's engine, font initialization and the automatically
  registered purchases web SDK still contribute startup weight. No renderer
  migration or billing-plugin fork was attempted during this pass.

### 2. Widget updates

- Per-post/per-comment selectors prevent unrelated likes/reposts rebuilding
  every engagement bar. A regression test verifies another post's bar is unchanged.
- Unchanged repost IDs/timestamps no longer trigger feed reordering/rebuilding.
- Reused the verified shell account provider instead of fetching `/users/me`
  again for each post viewer. Authentication gates remain in place.

### 3. Feed scrolling and retained state

- Replaced an eagerly built whole-feed Column with a lazy SliverList and stable
  row identities. A 100-post fixture mounts 3 rows instead of all 100 at startup.
- Retain unsent comment/reply state when its row scrolls away.
- Store selected carousel index in route-local PageStorage rather than keeping
  off-screen media controllers alive. Returning to the post restores its photo.
- Coalesce video visibility checks to one per frame, not every raw scroll event.
- Remaining: long-profile lists and real-device frame presentation need further
  profiling; steady 60 FPS is not yet certified.

### 4. Images and video delivery

- Found repeating animated video loaders mounted behind already loaded posters.
  Loaded posters now remove that hidden animation entirely.
- Videos pause/mute when their tab/route is hidden or the app backgrounds;
  hidden tabs do not initialize players. Late initialization after lazy disposal
  is ignored safely. Removed redundant poster prefetch requests.
- Observed legacy `media.tydes.io` byte-fetch requests fail CORS before the
  browser successfully displayed the same image via the existing HTML fallback.
  That exact host now uses HTML image display directly. Other CDNs retain the
  existing canvas/fallback strategy. Failed legacy XHRs disappeared in the
  final startup waterfall. This is not an infrastructure CORS-policy repair.
- Remaining: locate the owning legacy R2 configuration if canvas image access
  is needed. Current Cloudflare account views did not expose the active bucket;
  no new R2 subscription was activated.
- Remaining: Bunny web playback still prefers the existing MP4 fallback where
  supplied, rather than universally using adaptive HLS. This audit's startup
  feed loaded legacy-media images/posters, so it does not establish Bunny
  stream startup or adaptive bitrate performance. Do not promise Instagram-like
  video delivery based on this pass.

### 5. Mobile layout and animation

- Kept post widths/aspect ratios, arrows, zoom, logo, theme and visual design.
- Disable tickers in hidden retained tabs.
- Fixed the invisible repeating poster-loader work without removing the
  visible branded loading state while media actually loads.
- No mobile CSS redesign or global animation removal was used.

### 6. API times and waterfall

- Final startup made five application XHRs: account, spots, posts, engagement,
  and relationships. Original startup also mounted hidden-tab alerts, profiles,
  ads, friends and next-swell requests and duplicated account/spots/posts fetches.
- Final throttled responses measured approximately 0.8–1.1 s for the account,
  2.0–2.1 s for spots and 2.3–2.7 s for posts, including the emulated network.
  These are not server-only processing times.
- Remaining: backend timing instrumentation, pagination and spot-payload
  splitting should be measured before further API changes. The current spots
  response is about 177 KB decoded / 31 KB transferred.

### 7. Initial fetching

- Only the selected tab mounts at startup (test: `[1,0,0,0,0]` rather than
  `[1,1,1,1,1]`). A tab mounts on its first visit and then retains its state.
- This removes hidden-page startup fetches rather than hiding their results.
- No public/private endpoint or verification behavior was weakened.

### 8. Caching and navigation

- Visited tabs retain scroll/form state; unvisited tabs no longer preload
  their full page. The stack is keyed by account ID for account isolation.
- Shared account-provider reuse avoids duplicate identity fetches.
- Existing in-place refresh/navigation regressions still pass. Private API
  responses were not made publicly cacheable to improve benchmark scores.
- The new bundle took about 8.2 s to transfer under this Slow 4G setup; a cached
  bundle revalidation took about 0.6 s. First-visit engine/download time and
  cached-start blocking work remain high-priority follow-ups.

## Validation and release

- `flutter analyze --no-pub`: no issues.
- `flutter test --no-pub`: 409 passed, including refresh, auth, carousel/zoom,
  unread-state, maps, forecast, billing, lazy state and video lifecycle checks.
- Web billing-plugin registration/vendor-bundle check: passed.
- Public-page/navigation/assets check: passed.
- Public appearance script: 7 passed.
- Production size/deferred-chunk/preload gate: passed.
- Production Site versions 90/91/92 were measured incrementally; version 93
  adds the tested carousel-index retention fix (572 extra initial JS bytes).

The release substantially reduces unnecessary work but does **not** complete
the Instagram-level performance target. Next priorities are cold startup,
cached-start blocking work, adaptive mobile video delivery, and an actual
iPhone Safari frame/interaction benchmark. No additional paid product is
required to investigate those items.

## Playback follow-up — 13 November 2026 (published)

The live player was observing only its nearest Scrollable, which is the
horizontal photo/video carousel, not the outer vertical feed. This prevented
scrolling from triggering both visible autoplay and off-screen silence. A live
390 × 844 check showed a loaded, ready video still paused at 0 seconds after
scrolling fully into view.

The published repair observes all enclosing scroll positions, clips playback
visibility to actual painted viewports, starts new controllers muted, and
reconciles playback after every asynchronous command. It immediately mutes and
pauses off-screen/hidden players even when a play promise is pending. Browser
policy-error events now get one muted recovery attempt, then an explicit retry;
stale-controller errors cannot disable a replacement player. Volume is no longer
mutated from build. Nearby preloading and the existing ten-loop limit remain.

Startup also overlaps independent theme/logo/native-favorites preparation and
skips unsupported web file restoration. The existing logo readiness gate and
theme-first behavior are retained. No measured startup-time reduction is claimed
for this small change; the major engine/billing-SDK startup work remains.

Validation: full Flutter analysis clean; 427 tests pass, including 14 nested-feed
playback regressions and four startup tests. Release-size, deferred-chunk,
billing-plugin, public-page, and appearance checks pass. Initial JS is 4,732,906
bytes (1,352,568 gzip bytes). Release output is available locally at
`/private/tmp/tydes-feed-playback-fixed`; the Site checkout's `dist/` contains it.

Published as Site version 94 at 2026-11-13 04:59 UTC after source access recovered.
Site source commit: `b2b1d7eda723484f436398870587d900a5481e88`.
Deployment: `appgdep_6af699139a388191b73b81732f27de0f` (succeeded).
The public `https://tydes.io/main.dart.js` matches the tested release SHA-256:
`322ba1e700f8a51963d295357c3785cc9ca5c20f5d20cefb2f6902656bf0b30b`.

Live Chrome verification at 390 × 844 showed an existing feed video advancing
without a play tap, initially muted (`paused: false`, `readyState: 4`). After
unmuting and scrolling away, the old video element was removed. Returning to
the video resumed playback; switching to Profile left its retained HTML video
paused and muted. Returning to Feed resumed playback again. The browser was
left muted and its temporary viewport override reset. Evidence:
`output/tydes-feed-playback-live.png` (local only). This does not certify iPhone
Safari performance or establish a sustained 60 FPS result.

A local release browser check used the production player and retained-tab stack
inside the same nested vertical-list/horizontal-carousel structure, with an
existing in-scope feed video. Chrome showed Clip A advancing without a play tap;
after unmuting and scrolling it away, its actual HTML video was paused/muted
while Clip B advanced. Switching to Profile left both video elements paused and
muted. This was a local desktop Chrome check, not a live-site deployment or an
iPhone Safari certification. The test-only entrypoint is
`tool/feed_video_playback_preview.dart`; it accepts the video URL as a build
define rather than storing personal media URLs in source. The temporary preview
and viewport overrides were cleaned up after verification.

## Startup waterfall and Safari streaming — 13 November 2026 (version 95)

### Incremental changes

- Inlined Flutter's official bootstrap template instead of fetching a separate
  bootstrap script before discovering the application script.
- Preloaded the two Flutter asset/font manifests and the four existing fonts
  with fetch destinations matching the Flutter engine. All six start alongside
  the application script. Local Chrome and iOS 18.6 Safari server logs show one
  request per resource, not duplicate downloads. The fonts, theme-first behavior,
  logo readiness gate, appearance and billing registration are unchanged.
- On browsers reporting native HLS support, the feed player now uses an existing
  supplied Bunny master playlist. Other web browsers retain the supplied MP4
  fallback. A genuine HLS initialization/decode/load failure tries that exact
  fallback once; autoplay denials instead retry muted on the same source.
  Native Flutter and legacy direct-file playback remain unchanged. Signed URL
  queries, off-screen pause/mute, asynchronous controller guards, zoom, carousel
  arrows and the ten-loop limit are preserved.

### Matched mobile lab runs

Chrome Incognito, extension-free, Lighthouse 13.5 Mobile Moto G Power, 4x CPU
slowdown and DevTools Slow 4G (562.5 ms request latency, 1,474.56 Kbps download,
675 Kbps upload). Clear Storage was off to retain the signed-in account.
These are two cached runs per stage, not field percentiles or physical iPhone
results. Flutter canvas rendering also limits what LCP alone can establish.

| Release/run | FCP | LCP | Speed Index | Total blocking time |
| --- | ---: | ---: | ---: | ---: |
| v94 cached 1 | 0.69 s | 10.86 s | 8.41 s | 1.42 s |
| v94 cached 2 | 1.19 s | 11.08 s | 8.78 s | 1.39 s |
| v95 cached 1 | 1.58 s | 8.09 s | 6.00 s | 1.40 s |
| v95 cached 2 | 1.75 s | 8.46 s | 6.54 s | 1.43 s |

Mean cached LCP decreased from 10.97 to 8.28 seconds (about 24.5%); mean
Speed Index decreased from 8.59 to 6.27 seconds (about 27%). FCP did not improve
and includes the HTML loader, not a usable feed. Cached blocking work remained
approximately 1.4 seconds; this optimization does not resolve CPU/input stalls.

Before, FontManifest started around 2.09–2.33 s, fonts around 2.91–3.88 s,
and AssetManifest around 4.45–4.58 s. After, all six started around 1.53–1.68 s
and completed around 2.10–2.30 s, with no external bootstrap request.

A separate first-new-bundle run measured FCP 1.72 s, LCP 15.66 s, Speed Index
11.16 s and blocking time 0.08 s. It was not a completely cold browser: engine
and font caches already existed. Do not compare it directly with the cached
before runs. The new script transferred 1,340,860 bytes in about 8.18 seconds
under Slow 4G. Initial download weight remains a substantial problem.

Raw reports are local-only under `output/`: `tydes-mobile-v94-baseline.json`,
`tydes-mobile-v94-baseline-repeat.json`, `tydes-mobile-v95-new-bundle.json`,
`tydes-mobile-v95-warm.json`, and `tydes-mobile-v95-warm-repeat.json`.

### Safari playback verification

With permission, uploaded one generated, silent, 82,464-byte test-pattern clip
to the existing Bunny library. No personal file or public post was used, and no
plan, key, DNS or access policy was changed. The clearly named test fixture
remains in that library for reproducibility; existing user assets were not
migrated or removed.

The resulting master playlist exposed 240p, 360p, 480p and 720p variants. Normal
TYDES-referrer requests succeeded; referrer-free access remained blocked. The
720p MP4 returned video/mp4, byte-range support and a public cache lifetime.

In actual iOS 18.6 Safari in the iPhone 16 Plus simulator, a release harness
using the production carousel selected HLS and advanced automatically, muted,
with readyState 4. Switching to the retained Profile tab left the hidden video
paused and muted. A separately built forced-MP4 baseline also played without a
play tap. The test-only harness observes the HTML video state and does not
change production behavior. Safari was restored to the signed-in live TYDES
feed after testing.

This tiny, unthrottled simulator clip verifies delivery compatibility and
playback lifecycle, not cellular buffering, time to first frame, physical
iPhone CPU performance, or sustained 60 FPS. Local screenshots:
`output/tydes-safari-native-hls-verified.jpg`,
`output/tydes-safari-mp4-baseline.jpg`, and
`output/tydes-mobile-v95-audit.jpg`.

### Validation and publication

- Full Flutter analysis: clean. Full Flutter tests: 440 passed.
- Startup regression tests: five passed. Release size/deferred chunks,
  billing vendor/plugin registration, public pages and diff checks passed.
- Initial JavaScript: 4,733,642 bytes; deterministic gzip: 1,353,098 bytes.
  Deferred chunks: 350,970 and 1,413 bytes. Relative to v94, the initial script
  grew by 736 bytes / 530 gzip bytes; this is a waterfall/playback improvement,
  not a bundle-size reduction.
- Main source commit: `9ee6c0f`.
- Site version 95 source: `d3dc641cf66855821b3234edd7926742aaea69f6`.
- Deployment: `appgdep_6af6aa93fd1881919563775211c75068`, succeeded at
  2026-11-13 06:13:47 UTC.
- Live `https://tydes.io/main.dart.js` SHA-256 matches the tested release:
  `eebb6b1b800e270fd62964950ff5dad934f4443be86e945af2ffffd98b48cce6`.

### Remaining work

1. Reduce cold-start script/engine cost and the approximately 1.4 s cached
   blocking work without risking billing or changing the design. The billing
   vendor is eagerly loaded, but its measured cached CPU contribution was only
   about 77–86 ms; it is not the dominant measured blocker.
2. Measure real-device iPhone Safari interaction/scroll frames. Simulator
   playback and Chrome throttling do not certify the 60 FPS target.
3. Plan a separately verified migration for older direct MOV uploads. Choosing
   HLS when available does not transcode existing assets automatically.
4. Investigate a potential low-resolution fallback issue: the backend currently
   constructs a 720p MP4 path without retaining Bunny's available-resolution/
   fallback metadata. A source below 720p may need a different fallback. This
   risk was identified but not reproduced against a user's upload or changed
   in this release.

Implementation references: [Flutter web initialization](https://docs.flutter.dev/platform-integration/web/initialization)
and [Apple HTTP Live Streaming](https://developer.apple.com/streaming/).

## On-demand maps, logo reuse and lazy own-profile posts — version 98

Published 13 November 2026, 07:44:55 UTC. This increment keeps the design,
post sizing, account/verification gates, billing, map controls/events and media
playback behaviour intact. No provider plan, credentials, security settings or
customer content changed.

### Measured changes

1. **Map code is downloaded on demand on the web.** Both the guest and signed-in
   map entrypoints share one deferred module. Native navigation remains
   synchronous. The web loader shares concurrent downloads, retains loaded page
   state, caches code only (not account data), and permits retry after failure.
   A release guard checks that both map entrypoints remain outside initial JS.
   The 158,477-byte map chunk was absent from both live feed startup waterfalls,
   then loaded successfully when opening the map. The guest map was verified on
   the already-allowed `http://127.0.0.1:4173` preview origin; the live signed-in
   map retained the events and saved-spots switches. A preliminary 4198 preview
   could load code but was not an allowed API origin; no CORS policy was relaxed.
2. **The awaited logo no longer makes two differently classified requests.**
   The old image preload was followed by a second Flutter Fetch around 570 ms
   long in the before traces. Matching the preload to Fetch reuses the request.
   Both before reports show two logo requests, both after reports show one.
   The local server also observed one logo GET. Logo readiness, the inline
   branded loader and theme-first behaviour remain unchanged.
3. **Own-profile posts are now lazy rows.** The previous single Column mounted
   every post and its media. At 390x844, a 100-photo fixture mounted 100 media
   carousels before and one initially after; fewer than eight remained mounted
   after scrolling to post 25. Stable post/repost keys and index lookup preserve
   ordering; tests retain an unsaved comment when scrolling away and returning.
   Refresh and account-isolation assertions still pass. This change is specific
   to the current user's profile; the other-user profile list is not yet lazy.

### Incremental release payloads

| Build | Initial JS | Deterministic gzip |
| --- | ---: | ---: |
| v97 baseline | 4,733,803 B | 1,353,152 B |
| Map split | 4,579,693 B | 1,305,729 B |
| Final, including lazy profile | 4,585,276 B | 1,307,265 B |

The final initial script saves 148,527 bytes / 45,887 gzip bytes relative to v97
(about 3.1% / 3.4%). The map's code still exists and is fetched on first map
use; this is not feature removal. First map use can briefly show a small loading
indicator. Successful code loads are cached for subsequent visits.

### Repeated live mobile lab checks

Same Chrome Incognito account, Lighthouse 13.5, Moto G Power, DevTools Slow 4G
and 4x CPU slowdown as above; storage clearing stayed off and both application
bundles were warmed before recording. These are two cached runs per stage,
not physical iPhone or field measurements. No Lighthouse run warnings occurred.

| Release/run | FCP | LCP | Speed Index | Total blocking time |
| --- | ---: | ---: | ---: | ---: |
| v97 before 1 | 0.88 s | 6.54 s | 4.53 s | 1.30 s |
| v97 before 2 | 1.50 s | 12.02 s | 3.78 s | 1.37 s |
| v98 after 1 | 0.69 s | 5.47 s | 3.89 s | 1.32 s |
| v98 after 2 | 0.70 s | 6.45 s | 4.58 s | 1.31 s |

The second baseline had substantially slower API requests (about 3.1–3.9 s for
account/spots/posts versus about 0.6–2.0 s in the first). Do not turn these
variable two-run LCP samples into a blanket percentage speed claim. Speed Index
was not consistently better and blocking time remains around 1.3 s. The
deterministic payload, logo-request and mounted-widget reductions are stronger
evidence for these changes than the small timing sample.

Private raw reports remain local under `output/`:
`tydes-mobile-v97-before-1.json`, `tydes-mobile-v97-before-2.json`,
`tydes-mobile-v98-after-1.json`, `tydes-mobile-v98-after-2.json`.
The visual audit screenshot is `output/tydes-mobile-v98-audit.jpg`.

### Validation and provenance

- Flutter analysis: clean. Full Flutter suite: 455 passed.
- Startup/chunk Node checks: seven passed. Billing plugin/vendor and public
  pages/assets checks passed. Independent review found no blocking issue.
- GitHub source: `ab3493e`; Site source:
  `0011799c6a6b97d588b8014aee9400c249ab0182`.
- Site version 98 deployment:
  `appgdep_6af6bfeebef48191bd2eeb13e89b5ff3` (succeeded).
- Live initial script matches release SHA-256:
  `32bdfb29abcb1f6166b9bd32b9c8d4e5b4507aa098d4514c61191245c64c2c90`.

Next: investigate remaining main-thread blocking, public-profile lazy rendering,
and duplicated account-scoped data fetches. Physical iPhone Safari scroll/frame
testing and older MOV migration remain separate work; this release does not
certify sustained 60 FPS or Instagram-level performance.

Implementation reference: [Dart deferred loading](https://dart.dev/language/libraries#lazily-loading-a-library).

## Cursor-paged feed — version 99

Published 13 November 2026, 18:47:10 UTC. The signed-in feed now requests at
most 25 activity rows, then appends another page when the outer feed scroll is
within 900 logical pixels of the bottom. The previous endpoint returned only
the latest 50 posts; it did not provide access to subsequent pages. Profiles,
maps, travel and people search retain their existing independent data paths.

- Server-side keyset pagination applies visibility and bidirectional block
  checks before the page limit. A snapshot and activity tie-breaker avoid
  duplicate/omitted rows when newer posts arrive. Original posts and recent
  reposts have distinct stable row IDs, including reposts of older originals.
- Page-scoped comments/likes/RSVP state arrive with the page, avoiding the
  feed's separate global engagement hydration request. Legacy engagement reads
  were also corrected to filter comment visibility before their existing cap.
- Appends preserve loaded rows, scroll position and drafts. Requests coalesce;
  failed pages retain their cursor and require explicit retry. Account changes
  and refresh generations reject late responses. An overlapping original on a
  later page cannot overwrite more recent engagement on an already loaded row.
- This bounds initial feed work and future database reads. It is not a claim
  that the Flutter engine startup or sustained 60 FPS has been solved. There
  are not enough real posts to exercise a second 25-row production page without
  creating filler content; multi-page coverage uses isolated test fixtures.

### Verification

- Full Flutter suite: 474 passed; analysis clean. Backend suite: 412 passed,
  three skipped. Tests cover 25/25/5 batches, history beyond the old 50-row
  cutoff, deleted cursor rows, account isolation, private/blocked content,
  stable repost ordering, retry, stale responses and retained drafts.
- Actual nested scroll widget tests prove that only the outer near-bottom
  vertical viewport requests another page; horizontal media scrolling and
  nested vertical scrolling do not trigger it.
- Live backend commit `573c4ba93ba1deed4e49ba2e8e6b77279f134614` confirmed by
  Render. OpenAPI exposes `/api/v1/social/feed`; anonymous access returns 401
  with `Cache-Control: private, no-store` and Cloudflare `DYNAMIC`.
- Production release checked locally before publication, then signed-in live
  feed checked at 390x844 and desktop widths, scrolling down and back up.
  Temporary viewport override restored. No real posts/accounts were created
  or deleted, no provider plans changed, and no credentials exposed.
- Initial JS: 4,597,716 bytes / 1,311,316 deterministic gzip bytes, versus
  v98's 4,585,276 / 1,307,265 (+12,440 / +4,051). Release-size, seven startup
  checks, billing and public-page guards pass. This increment trades a small
  code increase for bounded data loading; no new timing/60 FPS claim is made.
- Site source `2c8a9db4c3dc03f5467d7cff85802c88b10b0c87`; version 99 deployment
  `appgdep_6af75b273edc8191b1ae4f6d3bb8bca6` succeeded. Live initial script
  SHA-256 matches the release:
  `f64e742d54515477e85531193b711f147072451c5a596ef690b1d7d4f7bd54aa`.
- Visual check: `output/tydes-feed-pagination-mobile.jpg`.

## Profile navigation and targeted rebuilds — version 100

Published 14 November 2026, 13:35 GMT+8 (05:35 UTC). This is a modest
incremental improvement, not a new claim of Instagram-level startup or 60 FPS.
The design, billing, media playback rules and provider plans are unchanged.

### Changes and repeatable evidence

- **Two fewer profile-navigation requests.** Opening another user's profile
  reuses the already verified `meProvider` and the feed's loaded spot catalog,
  rather than downloading/decoding those again. Friends, posts and social
  profiles still refresh from the server. Tests prime shared data and confirm
  zero additional account/catalog reads on navigation and refresh, while the
  other three reads refresh normally. Account changes reject stale results and
  hide previous-account data; loss of verification prevents private requests
  and cannot retain the old profile's posts on screen. No global private HTTP
  cache or relaxed authorization was introduced.
- **Other-user profiles build post configurations on demand.** The former
  `ListView(children:)` already mounted media lazily: the 100-photo mobile
  baseline mounted one carousel, so this release does not claim to fix 100
  simultaneously mounted videos there. The new builder instead avoids
  constructing every post widget on each update, with stable row identity and
  a single spot index. The old lookup algorithm could scan 384 spots for each
  of 100 configured posts (38,400 reads per rebuild); the instrumented new
  fixture records 384 reads. Tests scroll to post 25 and return with the draft
  intact, keep fewer than eight mounted media widgets, and preserve blocking.
- **Comment changes are scoped to their own post.** The regression test fails
  before the selector change because an unrelated engagement bar rebuilds,
  then passes afterward. The changed post updates, the other post's TextField
  widget stays identical, and its unsaved draft remains intact. The expanded
  comments sheet uses the same post-specific subscription.
- **Admin-only rendering code loads on first use on web.** Native navigation
  remains synchronous. The 19,819-byte deferred module preserves existing
  backend admin checks, coalesces downloads, retries failures, retains page
  state after loading and ignores completion after disposal. It caches code,
  not user data. Eight loader/widget tests and a release-chunk guard cover this.

| Production build | Initial JS | Deterministic gzip |
| --- | ---: | ---: |
| v99 | 4,597,716 B | 1,311,316 B |
| v100 | 4,582,488 B | 1,307,704 B |

The reduction is 15,228 raw bytes / 3,612 gzip bytes, around 0.3%, not a major
startup speedup. The profile request and indexed-lookup reductions are the
more meaningful gains in this increment. No new throttled timing or physical
iPhone frame-rate measurement was made; historical main-thread blocking still
needs attention. The large composer extraction is a candidate for a separate,
carefully tested future code split.

### Verification and provenance

- Full Flutter suite: 491 passed. Analysis clean. Eight startup/chunk checks,
  release-size, billing and public-page guards passed. Independent review and
  the admin loader tests found no blocking issue.
- Local production preview and guest map verified. The preview was reloaded
  after the final build was copied so main and deferred chunks matched.
- Signed-in live feed, another user's profile, post controls and deferred
  admin page verified. Fresh 390x844 load checked; temporary viewport override
  restored and the browser returned to the feed. Changing the viewport/DPR
  mid-session initially produced a scaled screenshot; reloading at the target
  viewport produced the correct responsive layout. No customer posts, account
  settings, reports or subscriptions were changed during QA.
- Site source `0a63cca04c89f4ca44a5a83c3370a62442c0e038`; deployment
  `appgdep_6af7f316f72881919f25e28a2306a1bf` succeeded.
- Live script SHA-256 matches the release:
  `fde831a296ac55e21aca15f2effa749b02ef150bd0ca7e96be490a19ffde57c6`.
- Visual check: `output/tydes-v100-mobile-profile.jpg`.
