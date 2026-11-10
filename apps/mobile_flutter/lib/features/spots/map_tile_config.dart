// Shared by signed-in and public maps. Guest mode never adds a paid provider.
const _override = String.fromEnvironment('MAP_TILE_URL_TEMPLATE');
const _key = String.fromEnvironment('MAPTILER_API_KEY');
const _mapId = String.fromEnvironment(
  'MAPTILER_MAP_ID',
  defaultValue: 'outdoor-v2',
);
const mapTileUserAgent = String.fromEnvironment(
  'MAP_TILE_USER_AGENT',
  defaultValue: 'com.tytaneth.surftravel',
);
const _attribution = String.fromEnvironment('MAP_ATTRIBUTION');
const _attributionUrl = String.fromEnvironment('MAP_ATTRIBUTION_URL');

String get mapTileUrlTemplate => _override.isNotEmpty
    ? _override
    : _key.isNotEmpty
    ? 'https://api.maptiler.com/maps/$_mapId/256/{z}/{x}/{y}.png?key=$_key'
    : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
String get mapAttributionLabel => _attribution.isNotEmpty
    ? _attribution
    : _key.isNotEmpty
    ? '© MapTiler © OpenStreetMap contributors'
    : '© OpenStreetMap contributors';
String get mapAttributionUrl => _attributionUrl.isNotEmpty
    ? _attributionUrl
    : _key.isNotEmpty
    ? 'https://www.maptiler.com/copyright/'
    : 'https://www.openstreetmap.org/copyright';
