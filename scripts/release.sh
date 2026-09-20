#!/usr/bin/env bash
# =============================================================================
# release.sh — WorldMonitor pup release driver (run from this repo root)
# =============================================================================
# Builds the full-stack tarball from the fork, publishes it as a GitHub
# release asset, then prints the sha256 + exact remaining steps (the version
# bump/commit/tag order is deliberate — dogeboxd reads the pup version from
# the manifest INSIDE the tag, so the bump must be committed before tagging).
#
# Usage: scripts/release.sh <fork-tag>     e.g. scripts/release.sh v2.10.0-wm1
# Requires: node 22+, gh authed as PennybagsCX
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?usage: scripts/release.sh <fork-tag>}"
FORK="${FORK_REPO:-PennybagsCX/worldmonitor}"
PUPDIR="worldmonitor"

echo "== [1/3] build fork tarball =="
( cd "../worldmonitor" && ./scripts/build-dist.sh "$TAG" )

TARBALL="../worldmonitor/build-out/worldmonitor-fullstack-${TAG}.tar.gz"
[ -f "$TARBALL" ] || { echo "tarball missing: $TARBALL"; exit 1; }

echo "== [2/3] commit fork branch + tag + release =="
( cd "../worldmonitor"
  git push origin dogebox --tags
  git tag -f "$TAG"
  git push origin "$TAG"
  gh release create "$TAG" "$TARBALL" --repo "$FORK" \
    --title "WorldMonitor ${TAG} — pup release" \
    --notes "Full-stack pup bundle built from koala73/worldmonitor (see scripts/build-dist.sh). AGPL-3.0." \
    || gh release upload "$TAG" "$TARBALL" --repo "$FORK" --clobber
)

echo "== [3/3] sha256 wiring (paste into the pup repo) =="
SHA=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
NIXSHA=$(shasum -a 256 "${PUPDIR}/pup.nix" | awk '{print $1}')
echo ""
echo "1) pup.nix       fetchurl sha256: $SHA"
echo "2) manifest.json nixFileSha256   : $NIXSHA  (recompute AFTER editing pup.nix!)"
echo ""
echo "Then: edit ${PUPDIR}/manifest.json meta.version (bump FIRST) → commit → git tag v<version> → git push --tags"
echo "Then: register/install per the dashboard playbook (see worldmonitor/README.md)."
