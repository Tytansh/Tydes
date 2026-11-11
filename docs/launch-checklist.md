# Tydes Launch Checklist

Use this as the working launch list before TestFlight and App Store review.

## Already in place

- Production API domain: `https://api.tydes.io/api/v1`
- Open-Meteo paid customer API key support via Render `OPEN_METEO_API_KEY`
- Public legal pages: Privacy Policy, Terms of Use, and Support
- Account signup, email verification, reset password, and delete account
- Website Google sign-in published November 9, 2026; email/password remains
  available. See [setup and verification status](google-sign-in.md). The owner
  reported successful sign-in; signup, account-switching, and deletion
  regressions have dedicated tests. Native Google sign-in is separate work.
- Premium screen with Restore Purchases
- RevenueCat entitlement wiring for `premium`
- Website Premium checkout enabled for authenticated users on November 9, 2026
  (live Stripe/RevenueCat, USD 3.99/month before applicable taxes); verified
  sandbox purchase/cancellation/refund and non-owner live-offer availability.
  Real-phone App Store testing and a first genuine sale/payout are separate.
- Production RevenueCat App Store app, entitlement, offering, and monthly
  product connection
- Public RevenueCat iOS SDK key embedded in the release build
- App Store Connect app record and monthly subscription product at US$3.99
- Blue 1024x1024 App Store icon and subscription review screenshot
- Report/block controls for posts, comments, profiles, and direct messages
- Blocked surfers sheet in Settings
- Content moderation checks for profile text, posts, comments, events, and messages
- Surf/tide safety disclaimers in Settings and legal pages
- Cloudflare R2 media storage support
- Postgres-backed users/auth/accounts/profile handles
- Google Workspace aliases for `support@tydes.io`, `appstore@tydes.io`,
  `reviewer@tydes.io`, and `security@tydes.io`

## Latest native simulator check — November 12, 2026

- Built and launched the current shared Flutter app on the existing iPhone 16
  Plus simulator (iOS 18.6), using Xcode 16.4 and the production API.
- Synchronized the iOS lockfile with the already-selected Flutter payment SDK:
  `purchases_flutter` 10.19.0, `PurchasesHybridCommon` 19.17.0, and RevenueCat
  5.99.0. The Podfile now explicitly matches Runner's iOS 13 minimum.
- Signed-in simulator checks passed for the existing Premium reviewer account:
  Bondi's current five-day outlook (November 12–16, Australia/Sydney), day and
  hour selection, chart tap-to-inspect, swell components, wind/gust charts,
  and the Coogee tide-station curve with its LAT datum and source timestamp.
- Changed System to Dark, fully closed only Tydes through the iOS app switcher,
  and reopened it from its home-screen icon. Both authenticated access and the
  saved Dark selection survived. Restored the original System preference and
  left the signed-in app open. No app data or account content was deleted.
- The native Premium screen recognised backend-granted Premium and displayed
  the current-plan, restore and management controls. This is not proof that an
  Apple offering, purchase or restore succeeded: the displayed price can fall
  back to API pricing, and this account already has Premium. No purchase,
  restore, cancellation or subscription-management action was submitted.
- Added widget regression coverage for vertical scrolling initiated within
  each forecast chart, including a held touch followed by a swipe. Both charts
  still permit parent scrolling and subsequent tap selection; no production
  gesture change was necessary.
- Updated the existing installation without erasing simulator app data. This
  was **not** a fresh-install test, physical-iPhone test, signed release archive,
  TestFlight upload, purchase, or Restore Purchases verification.
- CocoaPods was already installed, but unavailable in the native command's
  default search path. A command-scoped Ruby/CocoaPods path was sufficient;
  no global tool reinstall or shell configuration change was made.

## Before TestFlight

- Set `TYDES_PREMIUM_EMAILS=reviewer@tydes.io` in Render if the reviewer
  account should bypass sandbox purchase setup.
- Add the Open-Meteo customer API key to Render as `OPEN_METEO_API_KEY`.
- Create a MapTiler key and set the map `--dart-define` values.
- Create one reviewer account in Tydes and include it in App Review Notes.
- Run a fresh install test on a real iPhone.
- Test signup, login, reset password, delete account, premium purchase, Restore Purchases, posting, events, DMs, reports, blocks, map, forecasts, tides, and media uploads.

## Before App Store submission

- Confirm TideCheck commercial terms or paid plan.
- Confirm the map tile provider allows production mobile app traffic.
- Confirm Privacy Policy URL, Terms URL, and Support URL are reachable publicly.
- Upload the remaining App Store product-page screenshots.
- Confirm the embedded RevenueCat public SDK key points to the production
  Tydes app.
- Confirm debug banner is off.

## App Review Notes

Include:

- Reviewer email
- Reviewer password
- Steps to test premium or note that RevenueCat sandbox purchase is enabled
- Note that forecasts, tides, and Best Time Today are planning estimates, not navigation or safety-critical tools
- Support contact: `support@tydes.io`
