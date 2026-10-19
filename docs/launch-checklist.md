# Tydes Launch Checklist

Use this as the working launch list before TestFlight and App Store review.

## Already in place

- Production API domain: `https://api.tydes.io/api/v1`
- Open-Meteo paid customer API key support via Render `OPEN_METEO_API_KEY`
- Public legal pages: Privacy Policy, Terms of Use, and Support
- Account signup, email verification, reset password, and delete account
- Premium screen with Restore Purchases
- RevenueCat entitlement wiring for `premium`
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
