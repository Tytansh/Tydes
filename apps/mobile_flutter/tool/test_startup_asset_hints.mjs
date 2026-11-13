import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { verifyDeferredMapCode, verifyStartupAssetHints } from './verify_mobile_performance.mjs';

const html = readFileSync(new URL('../web/index.html', import.meta.url), 'utf8');
const fontManifest = [
  { family: 'MaterialIcons', fonts: [{ asset: 'fonts/MaterialIcons-Regular.otf' }] },
  { family: 'Pacifico', fonts: [{ asset: 'assets/fonts/Pacifico-Regular.ttf' }] },
  { family: 'Sora', fonts: [{ asset: 'assets/fonts/Sora-Variable.ttf', weight: 800 }] },
  { family: 'packages/cupertino_icons/CupertinoIcons', fonts: [{ asset: 'packages/cupertino_icons/assets/CupertinoIcons.ttf' }] },
];
const options = { template: true };

test('startup hints retain the app script, logo, fonts and both manifests', () => {
  assert.equal(verifyStartupAssetHints(html, fontManifest, options).length, 7);
  assert(html.includes('as="script" href="main.dart.js"'));
  assert(html.includes('as="fetch" href="assets/assets/branding/tydes-wave-blue-256.png" crossorigin="anonymous"'));
});

test('release guard detects a missing or duplicated startup asset hint', () => {
  const manifestHint = '<link rel="preload" as="fetch" href="assets/FontManifest.json" crossorigin="anonymous">';
  assert.throws(() => verifyStartupAssetHints(html.replace(manifestHint, ''), fontManifest, options), /one startup preload/);
  assert.throws(() => verifyStartupAssetHints(html.replace(manifestHint, manifestHint + manifestHint), fontManifest, options), /one startup preload/);
});

test('font hints use fetch-compatible destination and credentials', () => {
  assert.throws(() => verifyStartupAssetHints(html.replace('as="fetch"', 'as="font"'), fontManifest, options), /wrong destination/);
  assert.throws(() => verifyStartupAssetHints(html.replace('href="assets/assets/branding/tydes-wave-blue-256.png" crossorigin="anonymous"', 'href="assets/assets/branding/tydes-wave-blue-256.png" crossorigin="use-credentials"'), fontManifest, options), /wrong credentials/);
});

test('new manifest fonts must receive a matching preload', () => {
  const changed = [...fontManifest, { family: 'NewFont', fonts: [{ asset: 'fonts/NewFont.ttf' }] }];
  assert.throws(() => verifyStartupAssetHints(html, changed, options), /fonts\/NewFont.ttf/);
});

test('bootstrap is expanded exactly once and never requested separately', () => {
  assert.throws(() => verifyStartupAssetHints(html.replace('{{flutter_bootstrap_js}}', ''), fontManifest, options), /bootstrap token/);
  assert.throws(() => verifyStartupAssetHints(html + '<script src="flutter_bootstrap.js" async></script>', fontManifest, options), /must be inlined/);
  assert.throws(() => verifyStartupAssetHints(html, fontManifest), /not expanded/);
  assert.equal(verifyStartupAssetHints(html.replace('{{flutter_bootstrap_js}}', '_flutter.loader.load();'), fontManifest).length, 7);
});

test('logo hint matches the engine fetch rather than creating a second image request', () => {
  const original = 'as="fetch" href="assets/assets/branding/tydes-wave-blue-256.png"';
  assert.throws(() => verifyStartupAssetHints(html.replace(original, original.replace('fetch', 'image')), fontManifest, options), /wrong destination/);
});

test('both map entrypoints share one non-startup chunk', () => {
  const mapSource = 'Tap a pin to explore a break or a host photo to see events. Show saved spots only Popular spots';
  assert.deepEqual(verifyDeferredMapCode('app code', [{ file: 'maps.part.js', source: mapSource }]), ['maps.part.js']);
  assert.throws(() => verifyDeferredMapCode(mapSource, []), /initial bundle/);
  assert.throws(() => verifyDeferredMapCode('app code', []), /one deferred map chunk/);
});
