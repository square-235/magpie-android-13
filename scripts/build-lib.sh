#!/usr/bin/env bash
# Shared helpers for the Linux/macOS build scripts. Sourced, not run.
#
# The caller sets ROOT to the repository root and decides how loud it wants
# to be; nothing here exits on a missing dependency that a caller could live
# without (Bun, for one, is optional).

# ---- output ---------------------------------------------------------------

if [[ -t 1 ]]; then
  RESET=$'\033[0m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  BLUE=$'\033[34m'
else
  RESET=
  BOLD=
  DIM=
  RED=
  GREEN=
  YELLOW=
  BLUE=
fi

say() { printf '%s\n' "$*"; }
step() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }
note() { printf '%s%s%s\n' "$DIM" "$*" "$RESET"; }
warn() { printf '%s%s%s\n' "$YELLOW" "warning: $*" "$RESET" >&2; }
die() { printf '%s%s%s\n' "$RED" "error: $*" "$RESET" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not installed or not on PATH"
}

# sort version strings newest-first, falling back to the numeric fields when
# the host's sort has no -V (BSD/macOS does not).
version_sort() {
  if printf '1.2\n1.10\n' | sort -V >/dev/null 2>&1; then
    sort -V "$@"
  else
    sort -t. -k1,1n -k2,2n -k3,3n "$@"
  fi
}

# ---- versions -------------------------------------------------------------

# Bun's version and the SHA-256s of its builds come from upstream, the one
# place they are maintained (internal/plugin/bun.go). The fallbacks are the
# values at the commit this repository vendors; they are only used when
# upstream cannot be parsed.
bun_version() {
  local v
  v="$(sed -n 's/^const BunVersion = "\([^"]*\)".*/\1/p' \
    "$ROOT/upstream/internal/plugin/bun.go" 2>/dev/null | head -n 1)"
  [[ -n "$v" ]] || v="1.4.2"
  printf '%s\n' "$v"
}

BUN_VERSION="$(bun_version)"

# ---- Android SDK / NDK ----------------------------------------------------

# The SDK may be named by --sdk, ANDROID_HOME/SDK_ROOT, local.properties, or
# live in one of the usual places. Prints its path, or returns 1.
find_sdk() {
  local given="${1:-}"
  local -a candidates=()
  [[ -n "$given" ]] && candidates+=("$given")
  [[ -n "${ANDROID_HOME:-}" ]] && candidates+=("$ANDROID_HOME")
  [[ -n "${ANDROID_SDK_ROOT:-}" ]] && candidates+=("$ANDROID_SDK_ROOT")
  if [[ -f "$ROOT/android/local.properties" ]]; then
    local from_file
    from_file="$(sed -n 's/^[[:space:]]*sdk\.dir[[:space:]]*=[[:space:]]*//p' \
      "$ROOT/android/local.properties" 2>/dev/null | head -n 1)"
    [[ -n "$from_file" ]] && candidates+=("$from_file")
  fi
  candidates+=("$HOME/Android/Sdk" "$HOME/Android/sdk" "$HOME/Library/Android/sdk" "/opt/android-sdk")
  local c
  for c in "${candidates[@]}"; do
    if [[ -d "$c" ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

# The bin directory of an NDK's LLVM toolchain for this host. Prints it, or
# returns 1.
ndk_bin_dir() {
  local ndk="$1"
  local host="" p
  case "$(uname -s)" in
    Linux) host="linux-x86_64" ;;
    Darwin) host="darwin-x86_64" ;;
  esac
  if [[ -n "$host" && -d "$ndk/toolchains/llvm/prebuilt/$host/bin" ]]; then
    printf '%s\n' "$ndk/toolchains/llvm/prebuilt/$host/bin"
    return 0
  fi
  # An NDK built for another host layout (e.g. linux-aarch64); the wrappers
  # are named the same.
  for p in "$ndk"/toolchains/llvm/prebuilt/*/bin; do
    if [[ -d "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

# The NDK may be named by --ndk, ANDROID_NDK_*, the SDK's ndk/ folder (newest
# first), or the legacy ndk-bundle. Prints its path, or returns 1.
find_ndk() {
  local given="${1:-}"
  local -a candidates=()
  [[ -n "$given" ]] && candidates+=("$given")
  [[ -n "${ANDROID_NDK_HOME:-}" ]] && candidates+=("$ANDROID_NDK_HOME")
  [[ -n "${ANDROID_NDK_ROOT:-}" ]] && candidates+=("$ANDROID_NDK_ROOT")
  [[ -n "${ANDROID_NDK:-}" ]] && candidates+=("$ANDROID_NDK")
  local sdk="${SDK:-}"
  if [[ -z "$sdk" ]]; then
    sdk="$(find_sdk "" || true)"
  fi
  if [[ -n "$sdk" && -d "$sdk/ndk" ]]; then
    local d
    while IFS= read -r d; do
      candidates+=("$d")
    done < <(find "$sdk/ndk" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | version_sort -r)
  fi
  if [[ -n "$sdk" && -d "$sdk/ndk-bundle" ]]; then
    candidates+=("$sdk/ndk-bundle")
  fi
  candidates+=("/opt/android-ndk" "$HOME/Android/Sdk/ndk-bundle")
  local c
  for c in "${candidates[@]}"; do
    if ndk_bin_dir "$c" >/dev/null 2>&1; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

# The clang wrapper for arch at api, e.g.
#   aarch64-linux-android33-clang
#   armv7a-linux-androideabi33-clang
# api 0 means "the newest the NDK carries". Prints the wrapper, or returns 1
# when an exact api was asked for and the NDK doesn't have it: linking at a
# newer API is how a binary ends up naming a symbol Android 13 lacks.
wrapper_for() {
  local bin="$1" arch="$2" api="$3"
  local name level best="" best_level=""
  if [[ "$api" -gt 0 ]]; then
    case "$arch" in
      armv7a) name="armv7a-linux-androideabi${api}-clang" ;;
      *) name="$arch-linux-android${api}-clang" ;;
    esac
    if [[ -x "$bin/$name" ]]; then
      printf '%s\n' "$bin/$name"
      return 0
    fi
    return 1
  fi
  for name in "$bin"/*-clang; do
    [[ -f "$name" ]] || continue
    case "$arch" in
      armv7a) [[ "$(basename "$name")" == armv7a-linux-androideabi*-clang ]] || continue ;;
      *) [[ "$(basename "$name")" == "$arch-linux-android"*-clang ]] || continue ;;
    esac
    if [[ "$(basename "$name")" =~ android(eabi)?([0-9]+)-clang$ ]]; then
      level="${BASH_REMATCH[2]}"
      if [[ -z "$best_level" || "$level" -gt "$best_level" ]]; then
        best_level="$level"
        best="$name"
      fi
    fi
  done
  if [[ -n "$best" ]]; then
    printf '%s\n' "$best"
    return 0
  fi
  return 1
}

# ---- ABIs -----------------------------------------------------------------

abi_arch() {
  case "$1" in
    arm64-v8a) printf '%s\n' aarch64 ;;
    armeabi-v7a) printf '%s\n' armv7a ;;
    x86_64) printf '%s\n' x86_64 ;;
    x86) printf '%s\n' i686 ;;
    *) return 1 ;;
  esac
}

abi_goarch() {
  case "$1" in
    arm64-v8a) printf '%s\n' arm64 ;;
    armeabi-v7a) printf '%s\n' arm ;;
    x86_64) printf '%s\n' amd64 ;;
    x86) printf '%s\n' 386 ;;
    *) return 1 ;;
  esac
}

# Bun ships Android builds for these two only.
bun_target() {
  case "$1" in
    arm64-v8a) printf '%s\n' bun-linux-aarch64-android ;;
    x86_64) printf '%s\n' bun-linux-x64-android-baseline ;;
    *) return 1 ;;
  esac
}

# The SHA-256 of a Bun build, read from upstream's bunSums; the hardcoded
# values are the fallback for when that file can't be read.
bun_sha() {
  local target="$1" sum
  sum="$(grep -o "\"$target\.zip\"[^0-9a-f]*[0-9a-f]\{64\}" \
    "$ROOT/upstream/internal/plugin/bun.go" 2>/dev/null | grep -o '[0-9a-f]\{64\}' | head -n 1)"
  if [[ -z "$sum" ]]; then
    case "$target" in
      bun-linux-aarch64-android) sum="a1c7e2983f1bb65146beb256a4d72449f23042412bc2cf278aa6397ba27e0274" ;;
      bun-linux-x64-android-baseline) sum="fe36d8d4795e0eadc22fb6696d44d168491c2e5b9b7cbb12b8c96b0c0c40a4f9" ;;
      *) return 1 ;;
    esac
  fi
  printf '%s\n' "$sum"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "sha256sum or shasum is needed to verify Bun"
  fi
}

# ---- Bun download ---------------------------------------------------------

download_file() {
  local url="$1" out="$2"
  curl -L --fail --silent --show-error \
    --connect-timeout 20 --speed-time 60 --speed-limit 1024 \
    --output "$out" "$url"
}

# The cached zip for abi, downloaded when absent or wrong. Mirror first (a
# prefix mirror such as https://mirror.example/), then GitHub, then
# gh-proxy.com in front of GitHub: that last one is what a phone build
# machine in China can usually still reach.
bun_zip() {
  local abi="$1" mirror="${2:-}"
  local target sha cache tmp url
  target="$(bun_target "$abi")" || return 1
  sha="$(bun_sha "$target")" || return 1
  cache="$ROOT/android/build/bun-cache/$target.zip"
  mkdir -p "$(dirname "$cache")"

  if [[ -f "$cache" ]]; then
    if [[ "$(sha256_file "$cache")" == "$sha" ]]; then
      note "  $abi  cached $target.zip"
      return 0
    fi
    warn "the cached $target.zip doesn't match its SHA-256; downloading it again"
    rm -f "$cache"
  fi

  local url_path="https://github.com/oven-sh/bun/releases/download/bun-v$BUN_VERSION/$target.zip"
  local -a sources=()
  [[ -n "$mirror" ]] && sources+=("${mirror%/}/$url_path")
  sources+=("$url_path")
  sources+=("https://gh-proxy.com/$url_path")

  for url in "${sources[@]}"; do
    tmp="$cache.part"
    rm -f "$tmp"
    say "  $abi  downloading $url"
    if download_file "$url" "$tmp" && [[ -s "$tmp" ]]; then
      if [[ "$(sha256_file "$tmp")" == "$sha" ]]; then
        mv "$tmp" "$cache"
        return 0
      fi
      warn "what was downloaded isn't Bun $BUN_VERSION for $abi (SHA-256 mismatch); trying the next source"
    else
      warn "that source failed; trying the next one"
    fi
    rm -f "$tmp"
  done
  return 1
}

# Puts Bun where MagpieGateway looks for it: jniLibs/<abi>/libmagpiebun.so.
install_bun() {
  local abi="$1" mirror="${2:-}"
  local target out zip
  target="$(bun_target "$abi")" || return 1
  out="$ROOT/android/app/src/main/jniLibs/$abi/libmagpiebun.so"
  bun_zip "$abi" "$mirror" || return 1
  zip="$ROOT/android/build/bun-cache/$target.zip"
  mkdir -p "$(dirname "$out")"
  # the zip holds <target>/bun, an ELF the native library directory runs
  if ! unzip -p "$zip" "$target/bun" > "$out" 2>/dev/null || [[ ! -s "$out" ]]; then
    rm -f "$out"
    return 1
  fi
  chmod 755 "$out"
  say "               -> $out ($(du -h "$out" | cut -f1))"
}

# The shell's minSdk is the API the gateway should link against: a binary
# linked at a newer API can name a libc symbol Android 13 doesn't have.
api_from_gradle() {
  local v
  v="$(sed -n 's/.*minSdk = \([0-9][0-9]*\).*/\1/p' \
    "$ROOT/android/app/build.gradle.kts" 2>/dev/null | head -n 1)"
  [[ -n "$v" ]] || v="33"
  printf '%s\n' "$v"
}

# "arm64-v8a,x86_64" -> "arm64-v8a x86_64", without duplicates.
normalize_abis() {
  local raw="${1//[,;]/ }"
  if [[ -z "${raw// /}" ]]; then
    printf '%s\n' ""
    return
  fi
  printf '%s\n' $raw | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ *$//'
}

# ---- Gradle / APK ---------------------------------------------------------

# The newest build-tools folder, or nothing.
find_build_tools() {
  local sdk="$1" d
  for d in "$sdk"/build-tools/*; do
    [[ -d "$d" ]] && printf '%s\n' "$d"
  done | version_sort | tail -n 1
}

newest_apk() {
  find "$1" -type f -name '*.apk' -exec ls -t {} + 2>/dev/null | head -n 1
}

# 1 when a is older than b (versions as dotted numbers).
version_lt() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | version_sort | head -n 1)" == "$1" ]]
}