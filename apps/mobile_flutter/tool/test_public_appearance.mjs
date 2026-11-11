import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const script = readFileSync(new URL('../web/appearance.js', import.meta.url), 'utf8');
const storageKey = 'tydes.appearance.v1';

function boot({ saved, systemDark = false, blockedStorage = false, legacyMedia = false, noMedia = false, initialChrome } = {}) {
  const attributes = new Map();
  const storage = new Map(saved === undefined ? [] : [[storageKey, saved]]);
  const windowEvents = new Map();
  const mediaEvents = new Map();
  const root = { style: {}, setAttribute: (key, value) => attributes.set(key, value) };
  let meta = initialChrome === undefined ? null : makeMeta(initialChrome);
  const media = {
    matches: systemDark,
    ...(legacyMedia
      ? { addListener: (listener) => mediaEvents.set('change', listener) }
      : { addEventListener: (event, listener) => mediaEvents.set(event, listener) }),
  };
  const window = {
    get localStorage() {
      if (blockedStorage) throw new Error('Storage access denied');
      return { getItem: (key) => storage.get(key) ?? null };
    },
    ...(noMedia ? {} : { matchMedia: () => media }),
    addEventListener: (event, listener) => windowEvents.set(event, listener),
  };
  const document = {
    documentElement: root,
    querySelector: () => meta,
    createElement: () => makeMeta(),
    head: { appendChild: (element) => { meta = element; } },
  };
  vm.runInNewContext(script, { window, document });
  return {
    get theme() { return attributes.get('data-theme'); },
    get colorScheme() { return root.style.colorScheme; },
    get chrome() { return meta.getAttribute('content'); },
    systemChange(dark) {
      media.matches = dark;
      mediaEvents.get('change')?.();
    },
    storageChange(value, key = storageKey) {
      if (value === null) storage.delete(key);
      else storage.set(key, value);
      windowEvents.get('storage')?.({ key, newValue: value });
    },
    clearStorage() {
      storage.clear();
      windowEvents.get('storage')?.({ key: null, newValue: null });
    },
  };
}

function makeMeta(color) {
  const attributes = new Map(color === undefined ? [] : [['content', color]]);
  return {
    setAttribute: (key, value) => attributes.set(key, value),
    getAttribute: (key) => attributes.get(key),
  };
}

test('first paint follows system when no preference is saved', () => {
  const dark = boot({ systemDark: true });
  assert.equal(dark.theme, 'dark');
  assert.equal(dark.colorScheme, 'dark');
  assert.equal(dark.chrome, '#0C171B');
  assert.equal(boot({ systemDark: false }).theme, 'light');
});

test('explicit choices override the OS, without changing saved values', () => {
  const dark = boot({ saved: 'dark', systemDark: false });
  assert.equal(dark.theme, 'dark');
  dark.systemChange(true);
  dark.systemChange(false);
  assert.equal(dark.theme, 'dark');
  const light = boot({ saved: 'light', systemDark: true });
  assert.equal(light.theme, 'light');
  light.systemChange(false);
  light.systemChange(true);
  assert.equal(light.theme, 'light');
});

test('system and invalid preferences follow live OS changes', () => {
  for (const saved of ['system', 'invalid']) {
    const app = boot({ saved, systemDark: false });
    assert.equal(app.theme, 'light');
    app.systemChange(true);
    assert.equal(app.theme, 'dark');
    app.systemChange(false);
    assert.equal(app.theme, 'light');
  }
});

test('blocked storage falls back safely to system appearance', () => {
  const app = boot({ blockedStorage: true, systemDark: true });
  assert.equal(app.theme, 'dark');
  app.systemChange(false);
  assert.equal(app.theme, 'light');
});

test('a setting changed in another Tydes tab updates public pages', () => {
  const app = boot({ saved: 'light', systemDark: false });
  app.storageChange('dark');
  assert.equal(app.theme, 'dark');
  app.storageChange('light', 'unrelated-storage-key');
  assert.equal(app.theme, 'dark');
  app.storageChange('system');
  assert.equal(app.theme, 'light');
  app.systemChange(true);
  assert.equal(app.theme, 'dark');
  app.storageChange('light');
  assert.equal(app.theme, 'light');
  app.clearStorage();
  assert.equal(app.theme, 'dark');
});

test('browser chrome restores the original light color', () => {
  const app = boot({ initialChrome: '#123f45' });
  assert.equal(app.chrome, '#123f45');
  app.storageChange('dark');
  assert.equal(app.chrome, '#0C171B');
  app.storageChange('light');
  assert.equal(app.chrome, '#123f45');
});

test('legacy media listeners and browsers without matchMedia do not fail', () => {
  const legacy = boot({ legacyMedia: true });
  legacy.systemChange(true);
  assert.equal(legacy.theme, 'dark');
  assert.equal(boot({ noMedia: true }).theme, 'light');
  assert.equal(boot({ noMedia: true, saved: 'dark' }).theme, 'dark');
});
