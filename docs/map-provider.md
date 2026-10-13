# Production Map Provider

Tydes can swap map tile providers at build time with Flutter `--dart-define`
values. Do not ship production App Store/TestFlight builds using the default
public OpenStreetMap tile server unless we have confirmed the usage policy is
safe for the app.

## Required launch decision

Choose a production tile provider before App Store review:

- MapTiler (recommended for v1)
- Mapbox
- Stadia Maps
- A paid OpenStreetMap-compatible tile provider

## Recommended MapTiler build values

For MapTiler, pass these values when running or building the app:

```bash
--dart-define=MAPTILER_API_KEY='<your_maptiler_api_key>'
--dart-define=MAPTILER_MAP_ID='outdoor-v2'
```

`MAPTILER_MAP_ID` can be changed later if we want a different MapTiler style.
Do not commit the API key to GitHub.

## Example run

```bash
flutter run \
  --dart-define=API_BASE_URL=https://api.tydes.io/api/v1 \
  --dart-define=MAPTILER_API_KEY='YOUR_KEY' \
  --dart-define=MAPTILER_MAP_ID='outdoor-v2'
```

## Generic provider override

If we switch to another tile provider later, these older generic overrides still
work:

```bash
--dart-define=MAP_TILE_URL_TEMPLATE='<provider tile url template>'
--dart-define=MAP_ATTRIBUTION='<provider attribution text>'
--dart-define=MAP_ATTRIBUTION_URL='<provider attribution/legal url>'
```

The URL template must support `{z}`, `{x}`, and `{y}` placeholders because
`flutter_map` fills those per tile. Keep provider API keys out of GitHub. Use
build settings, CI secrets, or local terminal commands.
