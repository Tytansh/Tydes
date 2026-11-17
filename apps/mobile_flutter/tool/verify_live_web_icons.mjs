#!/usr/bin/env node
// Anonymous, bounded GET-only verification. Never prints response bodies,
// cookies, credentials, query strings, or redirect destinations.
import { readFile, realpath, stat } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

export const USER_AGENTS = Object.freeze({
  Safari: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1',
  CriOS: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/139.0.7258.123 Mobile/15E148 Safari/604.1',
});
// Sites serves the source 404.html document at its extensionless canonical URL.
const PAGES = ['/', '/about/', '/support/', '/privacy/', '/terms/', '/404'];
const ROOT_ICONS = [
  ['/apple-touch-icon.png', 180], ['/apple-touch-icon-precomposed.png', 180],
  ['/apple-touch-icon-180x180.png', 180], ['/favicon.png', 32],
];
const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
const CRC_TABLE = Array.from({ length: 256 }, (_, value) => {
  for (let i = 0; i < 8; i++) value = (value >>> 1) ^ ((value & 1) ? 0xedb88320 : 0);
  return value >>> 0;
});

class VerificationError extends Error {
  constructor(code, agent = 'configuration', resource = '/') {
    // Resource paths are public, bounded and scrubbed; never include queries.
    super(`${code} (${agent}: ${resource.replace(/[^A-Za-z0-9_./-]/g, '_').slice(0, 160)})`);
    this.name = 'VerificationError';
    this.code = code;
  }
}
function requireValue(condition, code, agent, resource) {
  if (!condition) throw new VerificationError(code, agent, resource);
}
function crc32(bytes) {
  let value = 0xffffffff;
  for (const byte of bytes) value = CRC_TABLE[(value ^ byte) & 255] ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}

export function verifyPng(bytes, expectedSize, agent = 'PNG', resource = '/') {
  requireValue(bytes.length >= 57 && bytes.subarray(0, 8).equals(PNG_SIGNATURE), 'not_png', agent, resource);
  let offset = 8, chunks = 0, imageData = false, ended = false;
  while (offset < bytes.length) {
    requireValue(++chunks <= 1024 && offset + 12 <= bytes.length, 'invalid_png_chunks', agent, resource);
    const length = bytes.readUInt32BE(offset);
    const end = offset + 12 + length;
    requireValue(end <= bytes.length, 'truncated_png', agent, resource);
    const type = bytes.toString('ascii', offset + 4, offset + 8);
    requireValue(crc32(bytes.subarray(offset + 4, end - 4)) === bytes.readUInt32BE(end - 4), 'invalid_png_crc', agent, resource);
    if (chunks === 1) {
      requireValue(type === 'IHDR' && length === 13, 'invalid_png_header', agent, resource);
      requireValue(bytes.readUInt32BE(offset + 8) === expectedSize && bytes.readUInt32BE(offset + 12) === expectedSize,
        'wrong_png_dimensions', agent, resource);
      requireValue(bytes[offset + 16] === 8 && bytes[offset + 17] === 2, 'png_not_opaque_rgb', agent, resource);
    } else {
      requireValue(type !== 'IHDR' && type !== 'tRNS', 'png_not_opaque_rgb', agent, resource);
    }
    if (type === 'IDAT') imageData = true;
    if (type === 'IEND') {
      requireValue(length === 0 && end === bytes.length && imageData, 'invalid_png_end', agent, resource);
      ended = true;
      break;
    }
    offset = end;
  }
  requireValue(ended, 'invalid_png_end', agent, resource);
}

function attributes(tag) {
  const result = new Map();
  for (const match of tag.matchAll(/([^\s=<>/]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g)) {
    const name = match[1].toLowerCase();
    result.set(name, match[2] ?? match[3] ?? match[4] ?? '');
  }
  return result;
}
function metadata(html, agent, resource) {
  const head = html.match(/<head\b[^>]*>([\s\S]*?)<\/head\s*>/i)?.[1]
    ?.replace(/<!--[\s\S]*?-->/g, '').replace(/<script\b[^>]*>[\s\S]*?<\/script\s*>/gi, '');
  requireValue(head !== undefined, 'missing_html_head', agent, resource);
  const links = [...head.matchAll(/<link\b[^>]*>/gi)].map(([tag]) => attributes(tag));
  const matching = (rel) => links.filter((attrs) => attrs.get('rel')?.toLowerCase().split(/\s+/).includes(rel));
  const apple = matching('apple-touch-icon');
  const manifest = matching('manifest');
  requireValue(apple.length === 1 && apple[0].get('sizes') === '180x180' && apple[0].get('href'),
    'missing_or_ambiguous_apple_icon', agent, resource);
  requireValue(manifest.length === 1 && manifest[0].get('href'), 'missing_or_ambiguous_manifest', agent, resource);
  const metas = [...head.matchAll(/<meta\b[^>]*>/gi)].map(([tag]) => attributes(tag));
  requireValue(metas.some((attrs) => attrs.get('name')?.toLowerCase() === 'apple-mobile-web-app-title'
    && attrs.get('content') === 'TYDES'), 'wrong_apple_app_title', agent, resource);
  return { apple: apple[0].get('href'), manifest: manifest[0].get('href') };
}

export async function verifyLiveWebIcons(baseURL, localDirectory, options = {}) {
  let base;
  try { base = new URL(baseURL); } catch { throw new VerificationError('invalid_base_url'); }
  const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(base.hostname);
  requireValue((base.protocol === 'https:' || (base.protocol === 'http:' && loopback))
    && !base.username && !base.password && !base.search && !base.hash && base.pathname === '/', 'invalid_base_url');
  const maxBytes = Math.min(options.maxBytes ?? 4 * 1024 * 1024, 4 * 1024 * 1024);
  const maxRequests = 40;
  const deadline = Date.now() + Math.min(options.timeoutMs ?? 60_000, 60_000);
  const localRoot = localDirectory ? await realpath(localDirectory) : null;
  const cache = new Map(), checkedIcons = new Set(), checkedManifests = new Set();
  let bytesRead = 0, requests = 0, pageCount = 0;

  function resolvePublic(value, current, agent) {
    let url;
    try { url = new URL(value, current); } catch { throw new VerificationError('invalid_asset_url', agent); }
    requireValue(url.origin === base.origin && !url.username && !url.password && !url.hash,
      'asset_not_same_origin', agent, url.pathname);
    return url;
  }
  async function get(url, agent, type) {
    const key = `${agent}:${url.href}`;
    if (cache.has(key)) return cache.get(key);
    const task = (async () => {
      requireValue(++requests <= maxRequests && Date.now() < deadline, 'request_budget_exceeded', agent, url.pathname);
      const perFile = type === 'html' ? 512 * 1024 : type === 'json' ? 64 * 1024 : 1024 * 1024;
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), Math.min(8000, deadline - Date.now()));
      try {
        const response = await fetch(url, { method: 'GET', redirect: 'manual', credentials: 'omit',
          headers: { 'User-Agent': USER_AGENTS[agent], Accept: type === 'html' ? 'text/html' : type === 'json' ? 'application/manifest+json, application/json' : 'image/png' },
          signal: controller.signal });
        requireValue(response.status === 200, response.status >= 300 && response.status < 400
          ? 'unexpected_redirect' : `http_${response.status}`, agent, url.pathname);
        requireValue(response.headers.get('cf-mitigated') !== 'challenge', 'edge_challenge', agent, url.pathname);
        const contentType = response.headers.get('content-type')?.split(';')[0].trim().toLowerCase();
        const validType = type === 'html' ? contentType === 'text/html'
          : type === 'json' ? ['application/json', 'application/manifest+json'].includes(contentType) : contentType === 'image/png';
        requireValue(validType, 'wrong_content_type', agent, url.pathname);
        const declaredLength = response.headers.get('content-length');
        requireValue(declaredLength === null || (/^\d+$/.test(declaredLength) && Number(declaredLength) <= perFile),
          'response_too_large', agent, url.pathname);
        const chunks = [];
        let size = 0;
        for await (const chunk of response.body) {
          size += chunk.length;
          bytesRead += chunk.length;
          requireValue(size <= perFile && bytesRead <= maxBytes, 'download_budget_exceeded', agent, url.pathname);
          chunks.push(chunk);
        }
        return Buffer.concat(chunks, size);
      } catch (error) {
        if (error instanceof VerificationError) throw error;
        throw new VerificationError('request_failed_or_timed_out', agent, url.pathname);
      } finally {
        controller.abort();
        clearTimeout(timer);
      }
    })();
    cache.set(key, task);
    return task;
  }
  async function icon(url, size, agent) {
    const key = `${agent}:${url.href}:${size}`;
    if (checkedIcons.has(key)) return;
    const bytes = await get(url, agent, 'png');
    verifyPng(bytes, size, agent, url.pathname);
    if (localRoot) {
      let local;
      try {
        const decoded = decodeURIComponent(url.pathname);
        requireValue(!decoded.includes('\\') && !decoded.includes('\0'), 'invalid_local_asset_path', agent, url.pathname);
        local = await realpath(path.resolve(localRoot, `.${decoded}`));
        requireValue(local.startsWith(localRoot + path.sep), 'local_asset_outside_root', agent, url.pathname);
        requireValue((await stat(local)).size <= 1024 * 1024, 'local_asset_too_large', agent, url.pathname);
        requireValue(bytes.equals(await readFile(local)), 'local_artwork_mismatch', agent, url.pathname);
      } catch (error) {
        if (error instanceof VerificationError) throw error;
        throw new VerificationError('local_asset_missing', agent, url.pathname);
      }
    }
    checkedIcons.add(key);
  }
  async function manifest(url, agent) {
    const key = `${agent}:${url.href}`;
    if (checkedManifests.has(key)) return;
    let value;
    try { value = JSON.parse((await get(url, agent, 'json')).toString('utf8')); }
    catch (error) {
      if (error instanceof VerificationError) throw error;
      throw new VerificationError('invalid_manifest_json', agent, url.pathname);
    }
    requireValue(value && value.name === 'TYDES' && value.short_name === 'TYDES'
      && Array.isArray(value.icons) && value.icons.length >= 2 && value.icons.length <= 8,
    'invalid_manifest_icons', agent, url.pathname);
    const sizes = new Set();
    for (const entry of value.icons) {
      const match = typeof entry?.sizes === 'string' && entry.sizes.match(/^(192|512)x\1$/);
      requireValue(match && entry.type === 'image/png' && typeof entry.src === 'string', 'invalid_manifest_icon', agent, url.pathname);
      sizes.add(Number(match[1]));
      await icon(resolvePublic(entry.src, url, agent), Number(match[1]), agent);
    }
    requireValue(sizes.has(192) && sizes.has(512), 'missing_manifest_icon_sizes', agent, url.pathname);
    checkedManifests.add(key);
  }
  async function page(route, agent) {
    const url = new URL(route, base);
    const tags = metadata((await get(url, agent, 'html')).toString('utf8'), agent, url.pathname);
    await icon(resolvePublic(tags.apple, url, agent), 180, agent);
    await manifest(resolvePublic(tags.manifest, url, agent), agent);
    pageCount++;
  }
  for (const route of PAGES) await page(route, 'Safari');
  await page('/', 'CriOS');
  for (const agent of Object.keys(USER_AGENTS)) {
    for (const [route, size] of ROOT_ICONS) await icon(new URL(route, base), size, agent);
  }
  return { pages: pageCount, icons: checkedIcons.size, requests, bytes: bytesRead, userAgents: Object.keys(USER_AGENTS) };
}

async function main() {
  if (process.argv.length < 3 || process.argv.length > 4) {
    process.stderr.write('Usage: node tool/verify_live_web_icons.mjs https://tydes.io/ [web-or-release-directory]\n');
    process.exitCode = 2;
    return;
  }
  try {
    const result = await verifyLiveWebIcons(process.argv[2], process.argv[3]);
    process.stdout.write(`PASS: ${result.pages} pages, ${result.icons} icon checks, ${result.requests} anonymous GETs, ${result.bytes} bytes; Safari + CriOS.\n`);
  } catch (error) {
    process.stderr.write(`FAIL: ${error instanceof VerificationError ? error.message : 'local_configuration_error'}\n`);
    process.exitCode = 1;
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) await main();
