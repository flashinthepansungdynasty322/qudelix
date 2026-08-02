#!/bin/zsh
# Builds a universal Qudelix.app and packages it as a distributable DMG.
#   ./make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0.0"
VOLNAME="Qudelix"
DMG="../Qudelix-${VERSION}.dmg"

./build-app.sh --universal

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R ../Qudelix.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp INSTALL.txt "$STAGE/READ ME FIRST.txt"

rm -f "$DMG"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -quiet \
  "$DMG"

echo "Built: $(cd .. && pwd)/$(basename "$DMG")"
du -h "$DMG" | sed 's/^/  size: /'
shasum -a 256 "$DMG" | awk '{print "  sha256: " $1}'
