#!/usr/bin/env bash
set -euo pipefail

# A successful incremental Flutter build can still reuse a JavaScript artifact
# without the newly registered web plugin. Check the compiled output, not only
# pubspec.lock or the presence of the vendor asset, before publishing.
web_build_dir="${1:-build/web}"
main_bundle="$web_build_dir/main.dart.js"
vendor_bundle="$web_build_dir/assets/packages/purchases_flutter/assets/web/purchases_js_hybrid_mappings.js"

if [[ ! -s "$main_bundle" || ! -s "$vendor_bundle" ]]; then
  printf '%s\n' 'Billing build check failed: a required JavaScript bundle is missing.' >&2
  exit 1
fi

if rg --fixed-strings --quiet 'Google sign-in is disabled in this local design preview.' "$main_bundle"; then
  printf '%s\n' 'Release build check failed: AUTH_DESIGN_PREVIEW is enabled.' >&2
  printf '%s\n' 'Rebuild without AUTH_DESIGN_PREVIEW before publishing.' >&2
  exit 1
fi

for marker in 'PurchasesHybridMappings' 'web/purchases_js_hybrid_mappings.js'; do
  if ! rg --fixed-strings --quiet "$marker" "$main_bundle"; then
    printf '%s\n' 'Billing build check failed: the compiled web payment plugin is missing.' >&2
    printf '%s\n' 'Recompile with a fresh BILLING_BUILD_REVISION Dart define, then run this check again.' >&2
    exit 1
  fi
done

printf '%s\n' 'Web billing build verified: registered plugin and vendor bundle are present.'
