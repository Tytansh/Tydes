import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { verifyStartupAssetHints } from './verify_mobile_performance.mjs';

const html = readFileSync(new URL('../web/index.html', import.meta.url), 'utf8');
const fontManifest = [
  { family: 'MaterialIcons', fonts: [{ asset: 'fonts/MaterialIcons-Regular.otf' }] },
  { family: 'Pacifico', fonts: [{ asset: 'assets/fonts/Pacifico-Regular.ttf' }] },
  { family: 'Sora', fonts: [{ asset: 'assets/fonts/Sora-Variable.ttf', weight: 800 }] },
  { family: 'packages/cupertino_icons/CupertinoIcons', fonts: [{ asset: 'packages/cupertino_icons/assets/CupertinoIcons.ttf' }] },
];
const options = { template: true };

test('startup hints retain the app script, logo, fonts and both manifests', () => {
  assert.equal(verifyStartupAssetHints(html, fontManifest, options).length, 6);
  assert(html.includes('as="script" href="main.dart.js"'));
  assert(html.includes('as="image" href="assets/assets/branding/tydes-wave-blue-256.png"'));
});

test('release guard detects a missing or duplicated startup asset hint', () => {
  const manifestHint = '<link rel="preload" as="fetch" href="assets/FontManifest.json" crossorigin="anonymous">';
  assert.throws(() => verifyStartupAssetHints(html.replace(manifestHint, ''), fontManifest, options), /one startup preload/);
  assert.throws(() => verifyStartupAssetHints(html.replace(manifestHint, manifestHint + manifestHint), fontManifest, options), /one startup preload/);
});

test('font hints use fetch-compatible destination and credentials', () => {
  assert.throws(() => verifyStartupAssetHints(html.replace('as="fetch"', 'as="font"'), fontManifest, options), /wrong destination/);
  assert.throws(() => verifyStartupAssetHints(html.replace('crossorigin="anonymous"', 'crossorigin="use-credentials"'), fontManifest, options), /wrong credentials/);
});

test('new manifest fonts must receive a matching preload', () => {
  const changed = [...fontManifest, { family: 'NewFont', fonts: [{ asset: 'fonts/NewFont.ttf' }] }];
  assert.throws(() => verifyStartupAssetHints(html, changed, options), /fonts\/NewFont.ttf/);
});

test('bootstrap is expanded exactly once and never requested separately', () => {
  assert.throws(() => verifyStartupAssetHints(html.replace('{{flutter_bootstrap_js}}', ''), fontManifest, options), /bootstrap token/);
  assert.throws(() => verifyStartupAssetHints(html + '<script src="flutter_bootstrap.js" async></script>', fontManifest, options), /must be inlined/);
  assert.throws(() => verifyStartupAssetHints(html, fontManifest), /not expanded/);
  assert.equal(verifyStartupAssetHints(html.replace('{{flutter_bootstrap_js}}', '_flutter.loader.load();'), fontManifest).length, 6);
});
