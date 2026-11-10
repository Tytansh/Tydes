# Public spot and event links

The existing `https://tydes.io/#/spot/{id}` and `https://tydes.io/#/post/{id}`
links are readable before sign-in. Completed signed-in profiles retain the full
spot/post screens. Copy-link controls are available on spot details, public event
details, and the public event sharing sheet.

Guest previews use explicitly whitelisted `/api/v1/public/spots/{id}` and
`/api/v1/public/events/{id}` responses. They contain static spot guidance and a
public event's description, dates, host's public name/handle/avatar and spot.
They do not request marine forecasts, map tiles, original post media, attendee
lists, engagement state or group chats. Reads are limited to 120 per IP per five
minutes. Event responses are never cached; static spot guides have a one-hour
cache header.

Followers-only, missing, removed-author, banned-author and non-event posts have
the same public-event 404 response, even when the caller is the owner. The social
feed also enforces visibility server-side. Authenticated single-post reads use
the same public/owner/followed-author policy and block filtering instead of
searching the newest 50 feed items.

Sign-in carries an allowlisted internal `next` destination through email,
verification, Google authentication and profile completion. It returns visitors
to the original item without automatically joining an event. Unknown/external
return destinations fall back to `/`.

These are in-browser previews. Flutter's hash URLs still use the website's
general social metadata; per-event Open Graph/link-unfurl cards are not part of
this change.

## Guest explorer

`/explore`, `/explore/map`, and `/explore/events` form a separate read-only guest
shell, available from **Explore as guest** on the sign-in/sign-up card. It uses
only the whitelisted public catalogs: static spots with map coordinates and up
to 100 upcoming public events, sorted by start date. Country, region and search
filters run locally. Spot guides and event details retain their existing share
routes and sign-in return destinations. Signing in from the guest explorer opens
the corresponding normal Spots/Travel account tab.

No guest account is created. The guest shell does not mount the social/video
feed, live forecasts, favorites, alerts, attendee lists, or chats. Public spot
catalogs use a one-hour HTTP cache; event catalogs are `no-store` so privacy
changes are re-evaluated on each fetch. Short in-app provider retention avoids
re-fetching when switching guest tabs; refresh buttons explicitly reload.
The same configured tile provider and attribution are reused, without adding a
new paid map service. Alert monitoring and notification initialization require
a completed signed-in profile and pause while browsing the guest shell.

Verification: API privacy/limiter tests in `test_public_previews.py`; Flutter
guest, responsive layout, copy-link and authentication return tests in
`public_preview_test.dart`. Tests use isolated data and do not create live events
or alter customer accounts.
