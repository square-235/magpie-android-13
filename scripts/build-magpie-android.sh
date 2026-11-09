#!/usr/bin/env bash
# Builds magpie's gateway for Android and puts it where the app finds it:
# android/app/src/main/jniLibs/<abi>/libmagpie.so. Linux/macOS counterpart of
# scripts/build-magpie-android.ps1.
#
# cgo and the NDK are not optional here: Go's own DNS resolver is documented
# not to work on Android (golang/go#10714), and a CGO_ENABLED=0 build reads a
# /etc/resolv.conf Android doesn't have. With cgo it goes through bionic and
# netd, exactly as Termux's install does.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=build-lib.sh
source "$SCRIPT_DIR/build-lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/build-magpie-android.sh [options]

Builds magpie's Android gateway into
android/app/src/main/jniLibs/<abi>/libmagpie.so.

Options:
  --abis "LIST"       ABIs to build (default: "arm64-v8a x86_64")
  --api-level N       NDK API to link against; 0 = newest (default: minSdk)
  --version STR       version stamped into the binary (default: android-port)
  --ndk PATH          Android NDK (default: ANDROID_NDK_HOME or the SDK's ndk/)
  --sdk PATH          Android SDK, used to find the NDK
  --goproxy URL       Go module proxy (default: GOPROXY or goproxy.cn)
  -h, --help          this help

Environment: ANDROID_HOME, ANDROID_SDK_ROOT, ANDROID_NDK_HOME, ANDROID_NDK_ROOT,
MAGPIE_API_LEVEL, MAGPIE_ABIS, GOPROXY, GOFLAGS.
EOF
}

ABIS="${MAGPIE_ABIS:-arm64-v8a x86_64}"
API_LEVEL="${MAGPIE_API_LEVEL:-$(api_from_gradle)}"
VERSION="android-port"
NDK_ARG=""
SDK_ARG=""
GOPROXY_ARG="${GOPROXY:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --abis)
      [[ $# -ge 2 && -n "$2" ]] || die "--abis needs a list"
      ABIS="$2"
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
    --ndk)
      [[ $# -ge 2 && -n "$2" ]] || die "--ndk needs a path"
      NDK_ARG="$2"
      shift 2
      ;;
    --sdk)
      [[ $# -ge 2 && -n "$2" ]] || die "--sdk needs a path"
      SDK_ARG="$2"
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

# Keep the stamped version to what a version is spelled with; it goes into
# -ldflags, where spaces and quotes would split the argument.
VERSION="$(printf '%s' "$VERSION" | tr -cd 'A-Za-z0-9._+-')"
[[ -n "$VERSION" ]] || VERSION="android-port"

ABIS="$(normalize_abis "$ABIS")"
[[ -n "$ABIS" ]] || die "no ABI to build"
[[ "$API_LEVEL" =~ ^[0-9]+$ ]] || die "--api-level needs a number"

[[ -z "$SDK_ARG" || -d "$SDK_ARG" ]] || die "--sdk $SDK_ARG is not a directory"
[[ -z "$NDK_ARG" || -d "$NDK_ARG" ]] || die "--ndk $NDK_ARG is not a directory"

for abi in $ABIS; do
  abi_arch "$abi" >/dev/null || die "unknown ABI $abi; one of: arm64-v8a, armeabi-v7a, x86_64, x86"
done

need_cmd go
need_cmd sed

SDK="$(find_sdk "$SDK_ARG" || true)"
NDK="$(find_ndk "$NDK_ARG")" || die "Android NDK not found: pass --ndk, set ANDROID_NDK_HOME, or install one under \$ANDROID_HOME/ndk"
NDK_BIN="$(ndk_bin_dir "$NDK")" || die "the NDK at $NDK has no LLVM toolchain for this host"
say "NDK: $NDK"

# Go refuses a go.mod that asks for a newer toolchain unless GOTOOLCHAIN lets
# it fetch one. Say so before a build dies on it.
required_go="$(sed -n 's/^go //p' "$ROOT/upstream/go.mod" | head -n 1)"
have_go="$(go env GOVERSION 2>/dev/null || true)"
have_go="${have_go#go}"
if [[ -n "$required_go" && -n "$have_go" ]] && version_lt "$have_go" "$required_go"; then
  toolchain="$(go env GOTOOLCHAIN 2>/dev/null || true)"
  if [[ "$toolchain" == "local" ]]; then
    die "Go $have_go is older than the $required_go go.mod requires; install Go $required_go or set GOTOOLCHAIN=auto"
  fi
  warn "Go $have_go is older than the $required_go go.mod requires; GOTOOLCHAIN=${toolchain:-auto} will fetch it"
fi

if [[ -n "$GOPROXY_ARG" ]]; then
  export GOPROXY="$GOPROXY_ARG"
elif [[ -z "${GOPROXY:-}" ]]; then
  export GOPROXY="https://goproxy.cn,direct"
fi
if [[ " ${GOFLAGS:-} " != *" -trimpath "* ]]; then
  export GOFLAGS="${GOFLAGS:+$GOFLAGS }-trimpath"
fi

mkdir -p "$ROOT/android/app/src/main/jniLibs"

step "building the gateway"
for abi in $ABIS; do
  arch="$(abi_arch "$abi")"
  goarch="$(abi_goarch "$abi")"
  wrapper="$(wrapper_for "$NDK_BIN" "$arch" "$API_LEVEL")" ||
    die "the NDK at $NDK has no API $API_LEVEL clang wrapper for $abi ($arch)"
  out="$ROOT/android/app/src/main/jniLibs/$abi/libmagpie.so"
  mkdir -p "$(dirname "$out")"
  say "  $abi  android/$goarch  $(basename "$wrapper")"

  if [[ "$abi" == "armeabi-v7a" ]]; then
    if ! (
      cd "$ROOT/upstream"
      env CC="$wrapper" CGO_ENABLED=1 GOOS=android GOARCH="$goarch" GOARM=7 \
        go build -tags nogui -buildvcs=false \
        -ldflags "-s -w -X main.version=$VERSION" -o "$out" .
    ); then
      die "go build for $abi failed"
    fi
  else
    if ! (
      cd "$ROOT/upstream"
      env CC="$wrapper" CGO_ENABLED=1 GOOS=android GOARCH="$goarch" \
        go build -tags nogui -buildvcs=false \
        -ldflags "-s -w -X main.version=$VERSION" -o "$out" .
    ); then
      die "go build for $abi failed"
    fi
  fi

  say "               -> $out ($(du -h "$out" | cut -f1))"
done

step "done"
say "the gateway is in android/app/src/main/jniLibs/"
say "build the app with scripts/build-apk.sh"