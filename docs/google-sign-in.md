# Website Google sign-in

## Production setup

Google sign-in was published on November 9, 2026. It supplements the existing
email/password flow; native iOS/Android Google sign-in is not included yet.

- Google Cloud project: `tydes-sign-in` (Tydes Sign In), under `tydes.io`.
- Google Auth Platform app: Tydes, External audience, In production.
- Web client: Tydes Website. Only basic sign-in identity is used; no Gmail or
  Drive API access, Google Cloud billing, or paid APIs were enabled.
- Authorized JavaScript origins: `https://tydes.io`, `https://www.tydes.io`, and
  `https://tydes-surf-travel.tytaneth.chatgpt.site`.
- Brand URLs: `https://tydes.io`, `/privacy`, and `/terms`.
- Render: `GOOGLE_WEB_CLIENT_ID` contains the public web client ID;
  `GOOGLE_AUTH_ALLOWED_ORIGINS` contains those three exact origins. No Google
  client secret is used by this ID-token flow.
- Hosted frontend: Site version 62, source commit `07cda71253683a7a293748e430ab2ba1ac0f502e`,
  with the matching approved Google privacy disclosure. Backend signup/session
  fixes: `0ada753` (initial Google implementation: `68caab9`).

`ALLOWED_ORIGINS` and `BUNNY_STREAM_ENABLED` are deliberately `sync: false` in
the Render Blueprint so a later sync cannot revert the live website origin or
disable the existing Bunny upload service. Update those values directly in
Render when needed; preserve website checkout configuration.

## Account behavior

- Google returns a stable account identifier and a verified email. The server
  verifies the ID token's signature, audience, issuer, expiry, and nonce. An
  expiring, single-use challenge is bound to a browser-held random verifier.
- An already linked Google identifier reuses the same Tydes account, even if
  the Google email subsequently changes. It does not change the Tydes email or
  billing identity automatically.
- A verified existing Tydes account can be linked automatically only when the
  emails match exactly (case-insensitively) and Google is authoritative for the
  address: Gmail or the matching verified Google Workspace domain.
- Only the Sign up tab can create a new Google account. Sign in requires an
  existing account and does not recreate a deleted account. The API requires
  explicit `allow_signup: true` for account creation; it defaults to false.
- A different email on Sign up creates a separate blank profile. Do not merge accounts or
  transfer Premium based solely on matching display names or a user's claim.
- For a Google account using an external, non-Workspace email, new Tydes
  accounts must complete Tydes email verification. Existing accounts must use
  their verified email/password flow instead of unsafe automatic linking.
- Linking preserves the existing password, user ID, profile, posts, and billing
  identity. Suspended accounts remain suspended.
- Google tokens and the browser verifier are not persisted or logged. Only the
  Google subject link is stored alongside the normal Tydes account.

## Verification and troubleshooting

Automated checks passed: 106 backend tests (including 23 Google-auth tests),
45 Flutter tests, Flutter analysis, the release web build, and the website
billing build guard. The live public config reports Google enabled, the button
renders on `tydes.io`, the API readiness check passes, and CORS allows the
current Sites origin.

The first existing-account test reached a blank profile-setup sheet because the owner selected a
different Google email from the existing Tydes account (confirmed by the owner).
The owner subsequently reported that Google sign-in works. Account-switching
regressions were reproduced locally and covered by tests: late old-session
success/401/403 responses and logout must not erase or replace a newer login;
the auth gate must not log out a new session using a retained blank profile.
Login now waits for a fresh profile before navigating.

Google and verified email signups now share the same inline profile form in the
main signup card, not a bottom sheet. It displays the signed-in email, supports
switching accounts without deleting the account, and enforces the server's
32-character name and 20-character handle limits. Failed account deletion is
reported to the user, keeping their session for retry; media cleanup is queued
instead of delaying the response on third-party storage. Tests cover deletion,
old-session rejection, and reusing the email via either signup method.

Deployment `appgdep_6af1842d67b88191ad931f1c11711faa` succeeded on November 9,
2026. The live `tydes.io` page was observed displaying the new inline profile
form for the owner's unfinished Google profile, with no bottom sheet and no
account modification performed during that check. The live API schema confirms
`allow_signup` defaults to false and its readiness endpoint returns ready.
Deletion/recreation checks were performed with isolated test users, not by
deleting the owner's live account.

If a user unexpectedly sees **Create your profile**, first ask which Google
email they selected and compare it with their existing Tydes login email. Do
not ask for passwords, copy ID tokens, or silently attach a different Google
account to an existing paid account.

To disable this optional feature, clear `GOOGLE_WEB_CLIENT_ID` in Render and
restart the service. The button then hides; email/password access remains.
Do not delete users, subject links, or the Google project as a rollback step.

## References

- [Google ID-token verification](https://developers.google.com/identity/gsi/web/guides/verify-google-id-token)
- [Google Identity Services JavaScript reference](https://developers.google.com/identity/gsi/web/reference/js-reference)
- [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy)
