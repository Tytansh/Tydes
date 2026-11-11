// Share the device preference with the Flutter app. Run synchronously in the
// head so the correct background is selected before the first public-page paint.
(function () {
  'use strict';

  const key = 'tydes.appearance.v1';
  const root = document.documentElement;
  let media;
  try {
    media = window.matchMedia('(prefers-color-scheme: dark)');
  } catch (_) {
    // Older browsers can still use an explicitly saved light/dark preference.
  }

  function normalize(value) {
    return value === 'light' || value === 'dark' ? value : 'system';
  }

  function readPreference() {
    try {
      return normalize(window.localStorage.getItem(key));
    } catch (_) {
      // Private/blocked storage must not stop a public page from loading.
      return 'system';
    }
  }

  let mode = readPreference();
  let themeMeta = document.querySelector('meta[name="theme-color"]');
  const lightChrome = themeMeta?.getAttribute('content') || '#F8F7F2';
  if (!themeMeta) {
    themeMeta = document.createElement('meta');
    themeMeta.setAttribute('name', 'theme-color');
    document.head.appendChild(themeMeta);
  }

  function apply() {
    const dark = mode === 'dark' || (mode === 'system' && Boolean(media?.matches));
    const appearance = dark ? 'dark' : 'light';
    root.setAttribute('data-theme', appearance);
    root.style.colorScheme = appearance;
    themeMeta.setAttribute('content', dark ? '#0C171B' : lightChrome);
  }

  apply();

  const onSystemChange = function () {
    if (mode === 'system') apply();
  };
  if (media?.addEventListener) {
    media.addEventListener('change', onSystemChange);
  } else if (media?.addListener) {
    media.addListener(onSystemChange);
  }

  window.addEventListener('storage', function (event) {
    if (event.key !== key && event.key !== null) return;
    mode = event.key === null ? readPreference() : normalize(event.newValue);
    apply();
  });
})();
