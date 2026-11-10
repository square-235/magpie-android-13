#!/usr/bin/env bash
# Builds the Android APK: Bun first, then magpie's gateway, then the app
# around them. Linux/macOS counterpart of scripts/build-apk.ps1.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=build-lib.sh
source "$SCRIPT_DIR/build-lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/build-apk.sh [options]

Options:
  -r, --release        build a release APK (signed like debug: with
                       MAGPIE_KEYSTORE if set, else Gradle's debug key)
  -S, --skip-gateway   reuse the libmagpie.so already in jniLibs/
      --no-bun         don't download/package Bun; external plugins stay off
      --abis "LIST"    ABIs to build (default: "arm64-v8a x86_64")
      --bun-mirror URL prefix mirror for Bun downloads
      --sdk PATH       Android SDK (default: ANDROID_HOME or local.properties)
      --ndk PATH       Android NDK (default: ANDROID_NDK_HOME or the SDK's ndk/)
      --api-level N    NDK API for the gateway; 0 = newest (default: minSdk)
      --version STR    version stamped into the gateway (default: upstream tag without v)
      --goproxy URL    Go module proxy (default: GOPROXY or goproxy.cn)
      --no-verify      skip the aapt2/unzip checks
  -h, --help           this help

Environment: ANDROID_HOME, ANDROID_SDK_ROOT, ANDROID_NDK_HOME,
MAGPIE_ABIS, MAGPIE_API_LEVEL, MAGPIE_BUN_MIRROR, MAGPIE_VERSION_NAME,
MAGPIE_VERSION_CODE, MAGPIE_KEYSTORE, MAGPIE_KEYSTORE_PASSWORD,
MAGPIE_KEY_ALIAS, MAGPIE_KEY_PASSWORD, JAVA_HOME, GOPROXY,
GRADLE_BIN (use a system gradle instead of ./gradlew).
EOF
}

RELEASE=0
SKIP_GATEWAY=0
NO_BUN=0
NO_VERIFY=0
ABIS="${MAGPIE_ABIS:-arm64-v8a x86_64}"
API_LEVEL="${MAGPIE_API_LEVEL:-$(api_from_gradle)}"
UPSTREAM_TAG="$(sed -n 's/^tag=//p' "$ROOT/UPSTREAM_VERSION" 2>/dev/null | head -n 1 || true)"
UPSTREAM_NUMERIC="${UPSTREAM_TAG#v}"
VERSION="${UPSTREAM_NUMERIC:-android-port}"
BUN_MIRROR="${MAGPIE_BUN_MIRROR:-}"
SDK_ARG=""
NDK_ARG=""
GOPROXY_ARG="${GOPROXY:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r | --release)
      RELEASE=1
      shift
      ;;
    -S | --skip-gateway)
      SKIP_GATEWAY=1
      shift
      ;;
    --no-bun)
      NO_BUN=1
      shift
      ;;
    --no-verify)
      NO_VERIFY=1
      shift
      ;;
    --abis)
      [[ $# -ge 2 && -n "$2" ]] || die "--abis needs a list"
      ABIS="$2"
      shift 2
      ;;
    --bun-mirror)
      [[ $# -ge 2 && -n "$2" ]] || die "--bun-mirror needs a URL"
      BUN_MIRROR="$2"
      shift 2
      ;;
    --sdk)
      [[ $# -ge 2 && -n "$2" ]] || die "--sdk needs a path"
      SDK_ARG="$2"
      shift 2
      ;;
    --ndk)
      [[ $# -ge 2 && -n "$2" ]] || die "--ndk needs a path"
      NDK_ARG="$2"
      shift 2
      ;;
    --api-level)
      [[ $# -ge 2 && -n "$2" ]] || die "--api-level needs a number"
      API_LEVEL="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || die "--version needs a value"
      VERSION="$2"
      shift 2
      ;;
    --goproxy)
      [[ $# -ge 2 ]] || die "--goproxy needs a URL"
      GOPROXY_ARG="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (try --help)"
      ;;
  esac
done

# Keep Gradle's APK fields aligned with the gateway version. CI also sets these
# explicitly, so an override from the environment always wins.
if [[ -z "${MAGPIE_VERSION_NAME:-}" ]]; then
  export MAGPIE_VERSION_NAME="$VERSION"
fi
if [[ -z "${MAGPIE_VERSION_CODE:-}" ]]; then
  MAGPIE_VERSION_CODE="$(printf '%s\n' "$VERSION" | awk -F. '
    { code = ($1 + 0) * 10000000 + ($2 + 0) * 1000000 + ($3 + 0); if (code < 1) code = 1; printf "%d", code }
  ')"
  export MAGPIE_VERSION_CODE
fi

ABIS="$(normalize_abis "$ABIS")"
[[ -n "$ABIS" ]] || die "no ABI to build"
[[ "$API_LEVEL" =~ ^[0-9]+$ ]] || die "--api-level needs a number"
[[ -z "$SDK_ARG" || -d "$SDK_ARG" ]] || die "--sdk $SDK_ARG is not a directory"
[[ -z "$NDK_ARG" || -d "$NDK_ARG" ]] || die "--ndk $NDK_ARG is not a directory"

for abi in $ABIS; do
  abi_arch "$abi" >/dev/null || die "unknown ABI $abi; one of: arm64-v8a, armeabi-v7a, x86_64, x86"
done

# ---- the SDK and a JDK Gradle can run on ----------------------------------

SDK="$(find_sdk "$SDK_ARG")" || die "Android SDK not found: pass --sdk or set ANDROID_HOME"
say "SDK: $SDK"
if [[ ! -d "$SDK/platforms/android-36" ]]; then
  die "Android SDK platform 36 is missing; run: sdkmanager \"platforms;android-36\""
fi
BUILD_TOOLS="$(find_build_tools "$SDK")"
if [[ -z "$BUILD_TOOLS" ]]; then
  warn "no build-tools under $SDK; Gradle may fail"
else
  say "build-tools: $(basename "$BUILD_TOOLS")"
fi

JAVA_BIN=""
if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]]; then
  JAVA_BIN="$JAVA_HOME/bin/java"
else
  JAVA_BIN="$(command -v java || true)"
fi
[[ -n "$JAVA_BIN" ]] || die "Java not found: install JDK 21 and set JAVA_HOME"
JAVA_VERSION="$("$JAVA_BIN" -version 2>&1 | awk -F '"' '/version/ {print $2; exit}')"
if [[ -n "$JAVA_VERSION" ]]; then
  JAVA_MAJOR="${JAVA_VERSION%%.*}"
  if [[ "$JAVA_MAJOR" =~ ^[0-9]+$ ]] && ((JAVA_MAJOR < 17)); then
    die "JDK 17+ is required (21 recommended); found $JAVA_VERSION"
  fi
  say "JDK: $JAVA_VERSION"
fi

# ---- Bun, the external plugins' runtime -----------------------------------

bun_capable=0
bun_done=0
bun_failed=""

for abi in $ABIS; do
  bun_target "$abi" >/dev/null 2>&1 && bun_capable=$((bun_capable + 1))
done

if [[ "$NO_BUN" == 1 ]]; then
  for abi in $ABIS; do
    out="$ROOT/android/app/src/main/jniLibs/$abi/libmagpiebun.so"
    if [[ -f "$out" ]]; then
      warn "--no-bun: $out is from an earlier build and still goes into the APK (delete it to leave it out)"
    fi
  done
  say "plugins: --no-bun: external plugins won't run in this build"
else
  need_cmd curl
  need_cmd unzip
  step "fetching Bun $BUN_VERSION"
  for abi in $ABIS; do
    if ! bun_target "$abi" >/dev/null 2>&1; then
      warn "Bun has no Android build for $abi; external plugins stay off for it"
      continue
    fi
    if install_bun "$abi" "$BUN_MIRROR"; then
      bun_done=$((bun_done + 1))
    else
      bun_failed="${bun_failed:+$bun_failed }$abi"
    fi
  done
  if [[ "$bun_capable" -eq 0 ]]; then
    warn "no ABI in this build can run Bun; external plugins stay off"
  elif [[ -z "$bun_failed" ]]; then
    say "plugins: Bun $BUN_VERSION goes into the APK"
  else
    warn "no source had Bun $BUN_VERSION for $bun_failed; those ABIs carry no plugin runtime"
  fi
fi

# ---- the gateway ----------------------------------------------------------

if [[ "$SKIP_GATEWAY" == 1 ]]; then
  for abi in $ABIS; do
    out="$ROOT/android/app/src/main/jniLibs/$abi/libmagpie.so"
    [[ -f "$out" ]] || warn "$out is missing; the APK won't carry $abi"
  done
  say "gateway: reusing the binaries in android/app/src/main/jniLibs/"
else
  args=(--abis "$ABIS" --api-level "$API_LEVEL" --version "$VERSION" --sdk "$SDK")
  [[ -n "$NDK_ARG" ]] && args+=(--ndk "$NDK_ARG")
  [[ -n "$GOPROXY_ARG" ]] && args+=(--goproxy "$GOPROXY_ARG")
  "$SCRIPT_DIR/build-magpie-android.sh" "${args[@]}"
fi

# ---- Gradle ---------------------------------------------------------------

local_props="$ROOT/android/local.properties"
current_sdk=""
if [[ -f "$local_props" ]]; then
  current_sdk="$(sed -n 's/^[[:space:]]*sdk\.dir[[:space:]]*=[[:space:]]*//p' \
    "$local_props" | head -n 1)"
fi
if [[ "$current_sdk" != "$SDK" ]]; then
  printf 'sdk.dir=%s\n' "$SDK" > "$local_props"
  say "wrote $local_props (sdk.dir=$SDK)"
fi

cd "$ROOT/android"
GRADLE_CMD=(./gradlew)
if [[ -n "${GRADLE_BIN:-}" ]]; then
  # The wrapper distribution can be very slow to fetch; a packaged Gradle
  # of the same release line is fine for AGP.
  GRADLE_CMD=("$GRADLE_BIN")
else
  [[ -x ./gradlew ]] || chmod +x ./gradlew
fi
task="assembleDebug"
[[ "$RELEASE" == 1 ]] && task="assembleRelease"

step "gradle $task (${GRADLE_CMD[0]})"
"${GRADLE_CMD[@]}" "$task" --console=plain

APK="$(newest_apk "$ROOT/android/app/build/outputs/apk")"
[[ -n "$APK" && -f "$APK" ]] || die "Gradle finished but no APK was found under android/app/build/outputs/apk"
say ""
say "APK: $APK ($(du -h "$APK" | cut -f1))"

# ---- a look at what was packed -------------------------------------------

if [[ "$NO_VERIFY" == 0 ]]; then
  step "checking the APK"
  if [[ -n "$BUILD_TOOLS" && -x "$BUILD_TOOLS/aapt2" ]]; then
    "$BUILD_TOOLS/aapt2" dump badging "$APK" 2>/dev/null |
      grep -E "^(package:|sdkVersion|targetSdkVersion|native-code)" || true
  else
    warn "aapt2 not found under the SDK; skipping the badging check"
  fi
  # grep -q closes the pipe early, and with pipefail unzip's SIGPIPE would
  # make the whole pipeline look failed even when the entry is present.
  apk_entries="$(unzip -l "$APK" 2>/dev/null || true)"
  case "$apk_entries" in
    *"/libmagpie.so"*) ;;
    *) warn "the APK carries no libmagpie.so" ;;
  esac
  case "$apk_entries" in
    *"/libmagpiebun.so"*) ;;
    *) note "the APK carries no libmagpiebun.so (external plugins stay off)" ;;
  esac
fi

say ""
say "install: adb install -r \"$APK\""