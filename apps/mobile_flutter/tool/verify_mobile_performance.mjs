import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { gzipSync } from 'node:zlib';

// Validate hint destinations against the generated manifest, not a second
// hard-coded font list. Browser QA separately verifies actual fetch reuse.
export function verifyStartupAssetHints(html, fontManifest, { template = false } = {}) {
  const preloads = [...html.matchAll(/<link\b([^>]*)>/gi)]
    .map(([, attributes]) => Object.fromEntries(
      [...attributes.matchAll(/([\w-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g)]
        .map(([, name, doubleQuoted, singleQuoted, unquoted]) => [
          name.toLowerCase(), doubleQuoted ?? singleQuoted ?? unquoted ?? '',
        ]),
    ))
    .filter(attributes => attributes.rel === 'preload');
  const expected = [
    'assets/assets/branding/tydes-wave-blue-256.png',
    'assets/FontManifest.json',
    'assets/AssetManifest.bin.json',
    ...fontManifest.flatMap(family => family.fonts.map(font => `assets/${font.asset}`)),
  ];
  for (const asset of expected) {
    const matches = preloads.filter(attributes => attributes.href === asset);
    assert.equal(matches.length, 1, `Expected one startup preload for ${asset}.`);
    assert.equal(matches[0].as, 'fetch', `Flutter fetch preload has wrong destination: ${asset}.`);
    assert.equal(matches[0].crossorigin, 'anonymous', `Flutter fetch preload has wrong credentials mode: ${asset}.`);
  }
  assert(!/<script\b[^>]*src\s*=\s*["']flutter_bootstrap\.js["']/i.test(html),
    'Bootstrap must be inlined, not requested as a separate script.');
  if (template) {
    assert.equal(html.match(/\{\{flutter_bootstrap_js\}\}/g)?.length, 1,
      'Expected one supported Flutter bootstrap token.');
  } else {
    assert(!html.includes('{{flutter_bootstrap_js}}'), 'Bootstrap template was not expanded.');
    assert(html.includes('_flutter.loader.load('), 'Built HTML is missing the Flutter bootstrap.');
  }
  return expected;
}

// Both public and signed-in map entrypoints must stay out of the first bundle.
// These existing UI strings are retained in compiled code, unlike class names.
export function verifyDeferredMapCode(main, chunks) {
  const markers = [
    'Tap a pin to explore a break or a host photo to see events.',
    'Show saved spots only',
    'Popular spots',
  ];
  for (const marker of markers) {
    assert(!main.includes(marker), `Map code returned to the initial bundle: ${marker}`);
  }
  const mapChunks = chunks.filter(chunk => markers.every(marker => chunk.source.includes(marker)));
  assert.equal(mapChunks.length, 1, 'Both map entrypoints must share one deferred map chunk.');
  return mapChunks.map(chunk => chunk.file);
}

// Repeatable release-size guard. Browser timings/FPS are measured separately;
// neither bundle size nor widget counts are substitutes for frame profiling.
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const directory = path.resolve(process.argv[2] || 'build/web');
  const main = fs.readFileSync(path.join(directory, 'main.dart.js'));
  const html = fs.readFileSync(path.join(directory, 'index.html'), 'utf8');
  const fontManifest = JSON.parse(fs.readFileSync(path.join(directory, 'assets/FontManifest.json'), 'utf8'));
  const startupFetchPreloads = verifyStartupAssetHints(html, fontManifest);
  const chunks = fs.readdirSync(directory).filter(name => name.endsWith('.part.js'));
  assert(main.length <= 4_650_000, 'Initial JS exceeds the mobile release budget.');
  assert(gzipSync(main).length <= 1_330_000, 'Compressed initial JS exceeds budget.');
  assert(chunks.length > 0, 'Deferred image-processing chunks must be shipped.');
  for (const chunk of chunks) {
    assert(fs.statSync(path.join(directory, chunk)).size > 0, `Empty deferred chunk: ${chunk}`);
  }
  const deferredMapChunks = verifyDeferredMapCode(main.toString('utf8'), chunks.map(file => ({
    file, source: fs.readFileSync(path.join(directory, file), 'utf8'),
  })));
  assert(html.includes('as="script" href="main.dart.js"'), 'Missing early app-script discovery.');
  console.log(JSON.stringify({
    initialJavaScriptBytes: main.length,
    initialJavaScriptGzipBytes: gzipSync(main).length,
    deferredChunks: chunks.map(file => ({ file, bytes: fs.statSync(path.join(directory, file)).size })),
    deferredMapChunks,
    startupFetchPreloads,
    bootstrap: 'inline',
    status: 'Mobile release-size budget passed',
  }, null, 2));
}
