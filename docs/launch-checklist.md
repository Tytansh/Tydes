# Tydes Launch Checklist

Use this as the working launch list before TestFlight and App Store review.

## Already in place

- Production API domain: `https://api.tydes.io/api/v1`
- Public legal pages: Privacy Policy, Terms of Use, and Support
- Account signup, email verification, reset password, and delete account
- Premium screen with Restore Purchases
- RevenueCat entitlement wiring for `premium`
- Report/block controls for posts, profiles, and direct messages
- Blocked surfers sheet in Settings
- Content moderation checks for profile text, posts, comments, events, and messages
- Surf/tide safety disclaimers in Settings and legal pages
- Cloudflare R2 media storage support
- Postgres-backed users/auth/accounts/profile handles

## Before TestFlight

- Create App Store Connect app record for Tydes.
- Create real App Store subscription product `tydes_premium_monthly`.
- Put the real RevenueCat iOS SDK key into the Flutter build command.
- Choose a production map tile provider and set the map `--dart-define` values.
- Create the support/reviewer/App Store email aliases in `docs/email-setup.md`.
- Create one reviewer account in Tydes and include it in App Review Notes.
- Run a fresh install test on a real iPhone.
- Test signup, login, reset password, delete account, premium purchase, Restore Purchases, posting, events, DMs, reports, blocks, map, forecasts, tides, and media uploads.

## Before App Store submission

- Confirm TideCheck commercial terms or paid plan.
- Confirm the map tile provider allows production mobile app traffic.
- Confirm support email receives mail.
- Confirm Privacy Policy URL, Terms URL, and Support URL are reachable publicly.
- Upload App Store screenshots and app icon.
- Remove any test-only RevenueCat keys from release commands.
- Confirm debug banner is off.

## App Review Notes

Include:

- Reviewer email
- Reviewer password
- Steps to test premium or note that RevenueCat sandbox purchase is enabled
- Note that forecasts, tides, and Best Time Today are planning estimates, not navigation or safety-critical tools
- Support contact: `support@tydes.io`
