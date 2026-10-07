# Production Map Provider

Tydes can swap map tile providers at build time with Flutter `--dart-define`
values. Do not ship production App Store/TestFlight builds using the default
public OpenStreetMap tile server unless we have confirmed the usage policy is
safe for the app.

## Required launch decision

Choose a production tile provider before App Store review:

- MapTiler
- Mapbox
- Stadia Maps
- A paid OpenStreetMap-compatible tile provider

## Flutter build values

Pass these values when running or building the app for production:

```bash
--dart-define=MAP_TILE_URL_TEMPLATE='<provider tile url template>'
--dart-define=MAP_ATTRIBUTION='<provider attribution text>'
--dart-define=MAP_ATTRIBUTION_URL='<provider attribution/legal url>'
```

The URL template must support `{z}`, `{x}`, and `{y}` placeholders because
`flutter_map` fills those per tile.

## Example shape

```bash
flutter run \
  --dart-define=API_BASE_URL=https://api.tydes.io/api/v1 \
  --dart-define=MAP_TILE_URL_TEMPLATE='https://example.tiles.com/styles/tydes/{z}/{x}/{y}.png?key=YOUR_KEY' \
  --dart-define=MAP_ATTRIBUTION='© Example Maps © OpenStreetMap contributors' \
  --dart-define=MAP_ATTRIBUTION_URL='https://example.tiles.com/attribution'
```

Keep provider API keys out of GitHub. Use build settings, CI secrets, or local
terminal commands.
