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
