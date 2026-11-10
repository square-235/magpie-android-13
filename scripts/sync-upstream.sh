#!/usr/bin/env bash
# Replaces upstream/ with the latest magpie release (or a named tag/ref) and
# records what was taken in UPSTREAM_VERSION. Android's own shell, scripts and
# Gradle files are left alone; the sync workflow commits whatever this writes.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
VERSION_FILE="$ROOT/UPSTREAM_VERSION"
UPSTREAM_URL="https://github.com/yetone/magpie"
API_URL="https://api.github.com/repos/yetone/magpie"

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar >/dev/null 2>&1 || die "tar is required"
command -v git >/dev/null 2>&1 || die "git is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

tag="${1:-}"
force="${SYNC_FORCE:-0}"

if [[ "$tag" == "--force" || "$tag" == "-f" ]]; then
  force=1
  tag=""
fi

if [[ -z "$tag" ]]; then
  curl_args=(-fsSL --retry 3 --connect-timeout 15
    -H 'Accept: application/vnd.github+json')
  if [[ -n "${GH_TOKEN:-}" ]]; then
    curl_args+=(-H "Authorization: Bearer $GH_TOKEN")
  fi
  json="$(curl "${curl_args[@]}" "$API_URL/releases/latest")" ||
    die "could not ask GitHub for magpie's latest release"
  tag="$(printf '%s' "$json" | python3 -c \
    'import json, sys; print(json.load(sys.stdin).get("tag_name", ""))')"
  [[ -n "$tag" ]] || tag="main"
fi

current=""
if [[ -f "$VERSION_FILE" ]]; then
  current="$(sed -n 's/^tag=//p' "$VERSION_FILE" | head -n 1)"
fi
if [[ "$tag" == "$current" && "$force" != "1" ]]; then
  log "upstream is already $tag (set SYNC_FORCE=1 to replace it anyway)"
  exit 0
fi

ref="refs/tags/$tag"
if [[ "$tag" == "main" || "$tag" == "master" ]]; then
  ref="refs/heads/$tag"
fi

log "looking up $UPSTREAM_URL $ref"
lines="$(git ls-remote "$UPSTREAM_URL.git" "$ref" "${ref}^{}" 2>/dev/null)" ||
  die "could not read $ref from $UPSTREAM_URL"
commit="$(printf '%s\n' "$lines" | awk '$2 ~ /\^\{\}$/ {print $1; exit}')"
[[ -n "$commit" ]] || commit="$(printf '%s\n' "$lines" | awk 'NR == 1 {print $1}')"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "could not find the commit for $tag"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/magpie-upstream.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

archive="$UPSTREAM_URL/archive/$ref.tar.gz"
log "downloading $archive"
curl -fL --retry 3 --connect-timeout 15 -o "$tmp/upstream.tar.gz" "$archive" ||
  die "could not download $archive"

mkdir -p "$tmp/src"
tar -xzf "$tmp/upstream.tar.gz" -C "$tmp/src" ||
  die "could not unpack $archive"
src="$(find "$tmp/src" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[[ -n "$src" && -f "$src/go.mod" && -f "$src/main.go" ]] ||
  die "the downloaded tree does not look like magpie (go.mod/main.go missing)"
rm -rf "$src/.git"

log "replacing upstream/ with $tag ($commit)"
rm -rf "$ROOT/upstream"
mv "$src" "$ROOT/upstream"

cat >"$VERSION_FILE" <<EOF
tag=$tag
commit=$commit
source=$UPSTREAM_URL
fetched=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

log "upstream: $tag $commit"