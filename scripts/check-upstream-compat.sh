#!/usr/bin/env bash
# Checks the integration points Android relies on inside upstream/. This is
# deliberately static: the build workflow runs the real Android build as the
# final gate, while this catches the usual breakages before spending minutes
# on Gradle and the NDK.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

checks=0
failures=0

pass() { checks=$((checks + 1)); printf 'ok   %s\n' "$*"; }
bad() { checks=$((checks + 1)); failures=$((failures + 1)); printf 'FAIL %s\n' "$*" >&2; }

need_file() {
  local rel="$1"
  if [[ -f "$ROOT/$rel" ]]; then pass "file $rel"; else bad "missing $rel"; fi
}

need_literal() {
  local rel="$1" literal="$2"
  if [[ -f "$ROOT/$rel" ]] && grep -qF -- "$literal" "$ROOT/$rel"; then
    pass "$rel contains $literal"
  else
    bad "$rel no longer contains $literal"
  fi
}

printf 'checking %s against %s\n' "$ROOT" \
  "$(sed -n 's/^tag=//p' "$ROOT/UPSTREAM_VERSION" 2>/dev/null | head -n 1)"

need_file "UPSTREAM_VERSION"
need_file "upstream/go.mod"
need_file "upstream/main.go"
need_file "upstream/internal/cli/web_cli.go"
need_file "upstream/internal/cli/main.go"
need_file "upstream/internal/plugin/bun.go"
need_file "upstream/internal/gui/web.go"
need_file "upstream/internal/settings/settings.go"
need_file "upstream/internal/gui/assets/index.html"
need_file "upstream/internal/gui/assets/plugins.js"
need_file "upstream/internal/gui/assets/plugins.css"
need_file "android/app/src/main/assets/magpie-mobile.js"
need_file "android/app/src/main/assets/magpie-mobile.css"
need_file "android/app/src/main/java/com/magpie/android/MagpieGateway.java"

if grep -q '^module github.com/yetone/magpie$' "$ROOT/upstream/go.mod" 2>/dev/null; then
  pass "upstream module is github.com/yetone/magpie"
else
  bad "upstream/go.mod no longer declares module github.com/yetone/magpie"
fi

go_version="$(sed -n 's/^go //p' "$ROOT/upstream/go.mod" 2>/dev/null | head -n 1)"
if [[ -n "$go_version" ]]; then
  pass "upstream asks for Go $go_version"
else
  bad "upstream/go.mod has no go directive"
fi

need_literal "upstream/internal/cli/web_cli.go" "serve"
need_literal "upstream/internal/cli/web_cli.go" "--web="
need_literal "upstream/internal/settings/settings.go" "MAGPIE_ADDR"
need_literal "upstream/internal/gui/web.go" "MAGPIE_WEB_KEY"
need_literal "upstream/internal/plugin/bun.go" "MAGPIE_BUN"

bun_version="$(sed -n 's/^const BunVersion = "\([^"]*\)"/\1/p' \
  "$ROOT/upstream/internal/plugin/bun.go" 2>/dev/null | head -n 1)"
if [[ -n "$bun_version" ]]; then
  pass "bundled Bun version is $bun_version"
else
  bad "internal/plugin/bun.go has no BunVersion constant"
fi

bun_sha="$(sed -n \
  's/.*"bun-linux-aarch64-android\.zip"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{64\}\)".*/\1/p' \
  "$ROOT/upstream/internal/plugin/bun.go" 2>/dev/null | head -n 1)"
if [[ "$bun_sha" =~ ^[0-9a-f]{64}$ ]]; then
  pass "bun-linux-aarch64-android.zip is pinned by SHA-256"
else
  bad "internal/plugin/bun.go has no SHA-256 for bun-linux-aarch64-android.zip"
fi

# The phone skin hooks into these upstream selectors. A rename here is the
# most common way an upstream bump quietly breaks the WebView page.
for selector in view-plugins pm-body pm-act pm-foot pm-check pm-manual \
  pm-row pm-dact pm-dhead builtinList lib-switch; do
  if grep -RqF -- "$selector" "$ROOT/upstream/internal/gui/assets"; then
    pass "upstream assets keep .$selector"
  else
    bad "upstream assets no longer contain $selector"
  fi
done

for selector in view-plugins pm-body pm-act pm-foot pm-check pm-manual \
  pm-row pm-dact pm-dhead builtinList; do
  if grep -qF -- "$selector" "$ROOT/android/app/src/main/assets/magpie-mobile.js"; then
    pass "magpie-mobile.js still uses $selector"
  else
    bad "magpie-mobile.js no longer uses $selector"
  fi
done

need_literal "android/app/build.gradle.kts" "minSdk = 33"
need_literal "android/app/build.gradle.kts" "compileSdk = 36"
need_literal "android/app/build.gradle.kts" "targetSdk = 36"
need_literal "android/app/src/main/AndroidManifest.xml" 'foregroundServiceType="specialUse"'
need_literal "android/app/src/main/java/com/magpie/android/MagpieGateway.java" "MAGPIE_ADDR"
need_literal "android/app/src/main/java/com/magpie/android/MagpieGateway.java" "MAGPIE_WEB_KEY"
need_literal "android/app/src/main/java/com/magpie/android/MagpieGateway.java" "libmagpiebun.so"
need_literal "android/app/src/main/java/com/magpie/android/MagpieService.java" "startForeground"

need_file "scripts/build-lib.sh"
for script in scripts/build-apk.sh scripts/build-magpie-android.sh; do
  if [[ -x "$ROOT/$script" ]]; then pass "$script is executable"; else bad "$script is not executable"; fi
done

printf '\ncompat: %d checks, %d failed\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]