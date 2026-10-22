#!/bin/zsh
# Publishes a new FlipScroll version end to end.
#   ./release.sh 1.1
# Sets the version in Info.plist and on the website, builds, signs and notarizes,
# commits and tags, uploads the zip to GitHub Releases, and redeploys the website.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version>, e.g. 1.1}"
TAG="v$VERSION"
TODAY=$(date +%Y-%m-%d)

[[ -z "$(git status --porcelain)" ]] || { echo "Working tree not clean; commit or stash first." >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "Tag $TAG already exists." >&2; exit 1; }

BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Info.plist

sed -i '' -E "s/Version [0-9][0-9.]* · Free/Version $VERSION · Free/" site/index.html
sed -i '' -E "s/\"softwareVersion\": \"[^\"]*\"/\"softwareVersion\": \"$VERSION\"/" site/index.html
sed -i '' -E "s|<lastmod>[^<]*</lastmod>|<lastmod>$TODAY</lastmod>|" site/sitemap.xml
grep -q "Version $VERSION · Free" site/index.html && grep -q "\"softwareVersion\": \"$VERSION\"" site/index.html \
    || { echo "Could not stamp version into site/index.html" >&2; exit 1; }

./build.sh --release

git add Info.plist site/index.html site/sitemap.xml
git commit -m "Release $TAG"
git tag "$TAG"
git push origin main "$TAG"

gh release create "$TAG" dist/FlipScroll.zip --title "FlipScroll $VERSION" --generate-notes
firebase deploy --only hosting:flipscroll --project brickandclick

echo "Released FlipScroll $VERSION"
