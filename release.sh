#!/bin/bash
# Cut a release: bump VERSION, build + sign the dmg, tag, and publish it on GitHub.
#   ./release.sh            bump the patch version  (0.2.0 -> 0.2.1)
#   ./release.sh minor|major
#   ./release.sh 1.4.0      an explicit version
# Needs `gh auth login` once. Signing must use your own certificate (the updater only installs an app signed
# by the same signer as the running one), which is why this runs locally and not in CI.
set -euo pipefail
cd "$(dirname "$0")"

REPO=aahannp/gazehop
command -v gh >/dev/null || { echo "error: gh is not installed (brew install gh)" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: not logged in — run: gh auth login" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: working tree is not clean; commit or stash first" >&2; exit 1; }

CUR="$(tr -d '[:space:]' < VERSION)"
IFS=. read -r MA MI PA <<<"$CUR"
case "${1:-patch}" in
  patch) NEW="$MA.$MI.$((PA + 1))" ;;
  minor) NEW="$MA.$((MI + 1)).0" ;;
  major) NEW="$((MA + 1)).0.0" ;;
  [0-9]*.[0-9]*.[0-9]*) NEW="$1" ;;
  *) echo "usage: ./release.sh [patch|minor|major|X.Y.Z]" >&2; exit 2 ;;
esac
TAG="v$NEW"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "error: tag $TAG already exists" >&2; exit 1; }

echo "==> $CUR -> $NEW"
echo "$NEW" > VERSION
REQUIRE_SIGNING=1 ./build.sh

DMG="build/GazeHop-$NEW.dmg"
[[ -f "$DMG" ]] || { echo "error: $DMG was not built" >&2; exit 1; }
(cd build && shasum -a 256 "GazeHop-$NEW.dmg" > "GazeHop-$NEW.dmg.sha256")

git add VERSION
git commit -q -m "Release $TAG"
git tag "$TAG"
git push origin HEAD "$TAG"
gh release create "$TAG" "$DMG" "$DMG.sha256" --repo "$REPO" --title "$TAG" --generate-notes
echo "==> published https://github.com/$REPO/releases/tag/$TAG"
rm -f "$DMG.sha256"
