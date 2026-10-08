# Tydes Email Setup

This keeps App Store, support, reviewer, and transactional email separated.

## Recommended addresses

- `appstore@tydes.io` - Apple Developer and App Store Connect account
- `support@tydes.io` - public support email shown in the app, website, and App Store
- `reviewer@tydes.io` - App Store reviewer Tydes test account
- `security@tydes.io` - optional security/contact address
- `verify@send.tydes.app` - transactional verification/password-reset sender through Resend

## Simple launch setup

Use Cloudflare Email Routing for receiving mail and Resend for app verification emails.

### Cloudflare Email Routing

In Cloudflare:

1. Open `tydes.io`.
2. Go to `Email` -> `Email Routing`.
3. Add your destination mailbox, usually `tytansherter@gmail.com`.
4. Verify the destination email from the email Cloudflare sends you.
5. Create custom addresses:
   - `appstore@tydes.io` -> `tytansherter@gmail.com`
   - `support@tydes.io` -> `tytansherter@gmail.com`
   - `reviewer@tydes.io` -> `tytansherter@gmail.com`
   - `security@tydes.io` -> `tytansherter@gmail.com`
6. Leave Cloudflare Email Routing DNS records enabled.

Cloudflare Email Routing is mainly for receiving and forwarding. If we want to
reply from `support@tydes.io` instead of Gmail later, use Google Workspace,
Fastmail, Zoho Mail, iCloud custom email domain, or another real mailbox
provider.

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
