import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

import { USER_AGENTS, verifyLiveWebIcons, verifyPng } from './verify_live_web_icons.mjs';

const webRoot = fileURLToPath(new URL('../web/', import.meta.url));
const apple = readFileSync(path.join(webRoot, 'icons/tydes-apple-touch-v3.png'));
const favicon = readFileSync(path.join(webRoot, 'favicon.png'));
const image192 = readFileSync(path.join(webRoot, 'icons/tydes-app-192.png'));
const image512 = readFileSync(path.join(webRoot, 'icons/tydes-app-512.png'));
const html = '<!doctype html><html><head><meta name="apple-mobile-web-app-title" content="TYDES">'
  + '<link rel="apple-touch-icon" sizes="180x180" href="/icons/tydes-apple-touch-v3.png">'
  + '<link rel="manifest" href="/manifest.json?v=fixture"></head><body>Fixture only</body></html>';
const manifest = JSON.stringify({ name: 'TYDES', short_name: 'TYDES', icons: [
  { src: '/icons/tydes-app-192.png?v=fixture', type: 'image/png', sizes: '192x192' },
  { src: '/icons/tydes-app-512.png?v=fixture', type: 'image/png', sizes: '512x512' },
] });

async function fixture(run, override = () => null) {
  const seen = [];
  const server = http.createServer((request, response) => {
    seen.push({ path: request.url, headers: request.headers, method: request.method });
    const url = new URL(request.url, 'http://fixture.invalid');
    let body, type;
    if (url.pathname === '/manifest.json') [body, type] = [manifest, 'application/manifest+json'];
    else if (url.pathname === '/favicon.png') [body, type] = [favicon, 'image/png'];
    else if (url.pathname.endsWith('.png')) {
      body = url.pathname.includes('192') ? image192 : url.pathname.includes('512') ? image512 : apple;
      type = 'image/png';
    } else [body, type] = [html, 'text/html; charset=utf-8'];
    const changed = override(url, request, body, type) ?? {};
    response.writeHead(changed.status ?? 200, { 'content-type': changed.type ?? type, ...changed.headers });
    response.end(changed.body ?? body);
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  try { await run(`http://127.0.0.1:${server.address().port}/`, seen); }
  finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
}

test('all pages and root aliases are checked anonymously under both iOS browser agents', async () => {
  await fixture(async (base, seen) => {
    const result = await verifyLiveWebIcons(base, webRoot);
    assert.equal(result.pages, 7);
    assert.deepEqual(result.userAgents, ['Safari', 'CriOS']);
    assert(result.bytes < 4 * 1024 * 1024);
    assert.equal(seen.length, result.requests);
    assert(result.requests <= 25);
    for (const request of seen) {
      assert.equal(request.method, 'GET');
      assert.equal(request.headers.cookie, undefined);
      assert.equal(request.headers.authorization, undefined);
      assert(Object.values(USER_AGENTS).includes(request.headers['user-agent']));
    }
    for (const agent of Object.values(USER_AGENTS)) {
      assert(seen.some((request) => request.path === '/' && request.headers['user-agent'] === agent));
      assert.equal(seen.filter((request) => request.path === '/icons/tydes-apple-touch-v3.png'
        && request.headers['user-agent'] === agent).length, 1, 'deduplicate common icon references per user agent');
    }
  });
});

test('the 404 document also needs explicit Apple icon and manifest metadata', async () => {
  await fixture(async (base) => {
    await assert.rejects(verifyLiveWebIcons(base), /missing_or_ambiguous_apple_icon.*404/);
  }, (url) => url.pathname === '/404' ? { body: '<html><head><title>Not found</title></head></html>' } : null);
});

test('a user-agent-specific HTML icon challenge fails without logging its body', async () => {
  const sensitiveBody = '<html>DO_NOT_PRINT_PRIVATE_DEBUG_BODY</html>';
  await fixture(async (base) => {
    await assert.rejects(verifyLiveWebIcons(base), (error) => {
      assert.match(error.message, /wrong_content_type.*CriOS/);
      assert(!error.message.includes(sensitiveBody));
      return true;
    });
  }, (url, request) => url.pathname.endsWith('.png') && request.headers['user-agent'].includes('CriOS')
    ? { type: 'text/html', body: sensitiveBody } : null);
});

test('edge challenges and redirects are errors, not followed or accepted as icons', async () => {
  await fixture(async (base, seen) => {
    await assert.rejects(verifyLiveWebIcons(base), /unexpected_redirect/);
    assert.equal(seen.length, 1);
  }, () => ({ status: 302, headers: { location: 'https://never-request.invalid/login?private=query' } }));
  await fixture(async (base) => {
    await assert.rejects(verifyLiveWebIcons(base), /edge_challenge/);
  }, () => ({ headers: { 'cf-mitigated': 'challenge' } }));
});

test('cross-origin asset URLs are never requested', async () => {
  await fixture(async (base, seen) => {
    await assert.rejects(verifyLiveWebIcons(base), /asset_not_same_origin/);
    assert.equal(seen.length, 1);
  }, () => ({ body: html.replace('/icons/tydes-apple-touch-v3.png', 'https://never-request.invalid/icon.png?token=hidden') }));
});

test('wrong PNG bytes, dimensions and corruption are rejected', () => {
  assert.throws(() => verifyPng(Buffer.from('<html>not an icon</html>'), 180), /not_png/);
  assert.throws(() => verifyPng(favicon, 180), /wrong_png_dimensions/);
  const corrupted = Buffer.from(apple);
  corrupted[corrupted.length - 1] ^= 1;
  assert.throws(() => verifyPng(corrupted, 180), /invalid_png_crc/);
});

test('remote PNG bytes must match the exact approved local release file', async () => {
  // An extra valid ancillary chunk keeps the PNG decodable and the same size,
  // but deliberately makes it byte-different from the approved release file.
  const payload = Buffer.from('fixture\0different-release');
  const chunk = Buffer.alloc(payload.length + 12);
  chunk.writeUInt32BE(payload.length, 0);
  chunk.write('tEXt', 4);
  payload.copy(chunk, 8);
  let crc = 0xffffffff;
  for (const byte of chunk.subarray(4, chunk.length - 4)) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  chunk.writeUInt32BE((crc ^ 0xffffffff) >>> 0, chunk.length - 4);
  const changed = Buffer.concat([favicon.subarray(0, -12), chunk, favicon.subarray(-12)]);
  verifyPng(changed, 32);
  await fixture(async (base) => {
    await assert.rejects(verifyLiveWebIcons(base, webRoot), /local_artwork_mismatch/);
  }, (url) => url.pathname === '/favicon.png'
    ? { body: changed } : null);
});

test('response size and total transfer budgets are enforced', async () => {
  await fixture(async (base) => {
    await assert.rejects(verifyLiveWebIcons(base, undefined, { maxBytes: 1024 }), /download_budget_exceeded/);
  });
  await fixture(async (base) => {
    await assert.rejects(verifyLiveWebIcons(base), /response_too_large/);
  }, () => ({ headers: { 'content-length': '99999999' }, body: '' }));
});

test('manifest JSON and icon declarations cannot silently become HTML or wrong-sized artwork', async () => {
  await fixture(async (base) => {
    await assert.rejects(verifyLiveWebIcons(base), /invalid_manifest_json/);
  }, (url) => url.pathname === '/manifest.json' ? { body: '<html>challenge</html>' } : null);
  await fixture(async (base) => {
    await assert.rejects(verifyLiveWebIcons(base), /invalid_manifest_icon/);
  }, (url) => url.pathname === '/manifest.json' ? { body: manifest.replace('192x192', '180x180') } : null);
});

test('base URLs reject embedded credentials, queries, hashes and cleartext non-loopback hosts', async () => {
  for (const value of ['https://user:secret@example.invalid/', 'https://example.invalid/?token=secret',
    'https://example.invalid/#/login', 'http://example.invalid/', 'https://example.invalid/nested/']) {
    await assert.rejects(verifyLiveWebIcons(value), /invalid_base_url/);
  }
});
