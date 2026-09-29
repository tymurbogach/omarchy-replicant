#!/bin/bash
# Fail when shipped code changes without a higher plugin version.
# Usage: ./tests/check-version-bump.sh [--base <ref>]
# Without --base, check the version format and that it never goes below
# the highest reachable tag. With --base, also require a strictly higher
# version when shipped paths change. Shipped paths are bin/, components/,
# replicant.js, and root QML files. Docs-only, test-only, and comment-only
# changes need no bump.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
MANIFEST="$ROOT/manifest.json"

BASE=""
if [[ "${1:-}" == "--base" ]]; then
  BASE="${2:-}"
  [[ -n "$BASE" ]] || { echo "missing base ref after --base" >&2; exit 2; }
fi

current="$(jq -r '.version // ""' "$MANIFEST" 2>/dev/null || true)"
if [[ ! "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "manifest version is not X.Y.Z: '$current'" >&2; exit 1
fi
echo "manifest version is $current"

version_gt() {
  [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]
}

if [[ -z "$BASE" ]]; then
  if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    highest="$(git -C "$ROOT" tag --list 'v*' | sed 's/^v//' | sort -V | tail -n1 || true)"
    if [[ -n "$highest" ]]; then
      if version_gt "$highest" "$current"; then
        echo "version $current is below tag v$highest" >&2; exit 1
      fi
      echo "version $current is at or above tag v$highest"
    else
      echo "no version tags found, format check only"
    fi
  else
    echo "no git checkout found, format check only"
  fi
  echo "version check passed"
  exit 0
fi

if ! git -C "$ROOT" rev-parse --verify "$BASE" >/dev/null 2>&1; then
  echo "unknown base ref: $BASE" >&2; exit 2
fi

committed="$(git -C "$ROOT" diff --name-only "$BASE"...HEAD -- . 2>/dev/null || git -C "$ROOT" diff --name-only "$BASE"..HEAD -- . 2>/dev/null || true)"
worktree="$(git -C "$ROOT" status --porcelain -uall 2>/dev/null | sed -e 's/^...//' -e 's/.* -> //' || true)"
changed="$(printf '%s\n%s\n' "$committed" "$worktree" | sed '/^[[:space:]]*$/d' | sort -u)"
[[ -n "$changed" ]] || { echo "no changes against $BASE"; exit 0; }

shipped="$(printf '%s\n' "$changed" | grep -E '^(bin/|components/|replicant\.js$|[^/]*\.qml$)' || true)"
if [[ -z "$shipped" ]]; then
  echo "no shipped code changed against $BASE, no bump required"
  exit 0
fi
echo "shipped files changed:"
printf '  %s\n' "$shipped"

if ! printf '%s\n' "$changed" | grep -qx 'manifest.json'; then
  echo "shipped code changed without a manifest.json bump" >&2; exit 1
fi

base_version="$(git -C "$ROOT" show "$BASE:manifest.json" 2>/dev/null | jq -r '.version // ""' || true)"
if [[ -z "$base_version" ]]; then
  echo "base $BASE has no manifest version, current $current stands"
  exit 0
fi
if [[ "$current" == "$base_version" ]]; then
  echo "shipped code changed but version still $current" >&2; exit 1
fi
if version_gt "$base_version" "$current"; then
  echo "version went backwards: base $base_version, current $current" >&2; exit 1
fi
echo "version bumped: $base_version -> $current"
echo "version check passed"
