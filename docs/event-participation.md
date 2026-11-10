# Event host participation

- Creating a `surf_plan` or `looking_for_buddy` automatically joins its host.
  PostgreSQL writes the event and host membership in the same transaction.
- The host cannot leave their own event. Repeated self-RSVP is idempotent.
- `rsvp_count` means **guests excluding the host**. UI totals add the host once;
  attendee lists deduplicate by user ID. Existing host RSVP rows need no deletion.
- Host membership is implicit for older events as well. Engagement includes those
  IDs, and the chat inbox includes hosted rooms even without a historical RSVP.
- `/social/event-chats` lists authenticated hosted/joined event rooms independently
  of the latest 50 feed posts. Visibility and blocks still apply. Empty rooms are
  usable immediately; no fake welcome message or separate paid chat service is
  created. Opening a room fetches its event by ID, not from the recent feed.
- Creation increments the existing social refresh key, refreshing mounted map and
  inbox providers. Map events respect location/search/saved-only filters; **Back
  to full map** clears them while retaining the event overlay switch.
- Signed-in maps paint the viewer's event markers above nearby hosts. When a
  beach has several events, its marker prefers the viewer's host avatar if they
  are organizing one; the popup still lists all permitted events at that beach.

Regression coverage: backend API host/guest membership, old hosted rooms, SQL
counting/visibility/atomic writes; Flutter host auto-selection, attendee counts,
inbox/empty room, own followers event markers, full-map reset at narrow/desktop
widths, refresh after creation, and restored wheel gestures on both maps.
