# Tydes Email Setup

This keeps App Store, support, reviewer, and transactional email separated.

## Recommended addresses

- `appstore@tydes.io` - Apple Developer and App Store Connect account
- `support@tydes.io` - public support email shown in the app, website, and App Store
- `reviewer@tydes.io` - App Store reviewer Tydes test account
- `security@tydes.io` - optional security/contact address
- `verify@send.tydes.app` - transactional verification/password-reset sender through Resend

## Simple launch setup

Use Google Workspace for receiving `@tydes.io` mail and Resend for app
verification emails.

### Google Workspace aliases

In Google Admin:

1. Open `Directory` -> `Users`.
2. Open the main Tydes user, currently `tytan@tydes.io`.
3. Use `Add alternative emails` / `Alternative email addresses`.
4. Add these aliases under the real `tydes.io` domain:
   - `appstore@tydes.io`
   - `support@tydes.io`
   - `reviewer@tydes.io`
   - `security@tydes.io`
5. Test each alias from a non-Workspace email address and confirm it lands in
   the `tytan@tydes.io` Gmail inbox.

Cloudflare should only handle DNS for this setup. Do not enable Cloudflare
Email Routing for `tydes.io` while Google Workspace is the active mail provider,
or mail routing can get confusing.

If Google Workspace ever gets removed, Cloudflare Email Routing can be used as a
free receiving/forwarding fallback, but it does not replace a real mailbox for
replying as `support@tydes.io`.

### Resend transactional email

Keep Resend for app emails only:

```text
AUTH_EMAIL_FROM="Tydes <verify@send.tydes.app>"
RESEND_API_KEY=<real_resend_key>
```

Do not use Resend as the inbox for `support@tydes.io`; it sends app emails but
does not replace a support mailbox.

## Apple account choice

Use `appstore@tydes.io` for the Apple Developer/App Store Connect Apple Account
if possible. It keeps Tydes separate from personal email and looks cleaner long
term.

Use your personal Gmail only if you enroll as an individual and need the
fastest setup. If you enroll as an individual, Apple may show your legal name as
the seller instead of Tydes.

## App reviewer account

Create an actual Tydes app account with:

```text
Email: reviewer@tydes.io
Premium: active test subscription or backend/admin premium override
```

Store the password only in App Store Connect review notes, not in GitHub.

## Production links that use support email

- `docs/support/index.html`
- `docs/privacy/index.html`
- `docs/terms/index.html`
- Flutter `TYDES_SUPPORT_EMAIL` dart-define fallback in `lib/core/legal/legal_links.dart`
