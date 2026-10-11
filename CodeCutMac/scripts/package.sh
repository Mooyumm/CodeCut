#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
STAMP="${CODECUT_PACKAGE_STAMP:-$(date +%Y%m%d-%H%M%S)}"
OUT="$ROOT/dist/CodeCut-$STAMP"
mkdir -p "$OUT"
xcodebuild -project "$ROOT/CodeCutMac/CodeCut.xcodeproj" \
  -scheme CodeCut -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$ROOT/CodeCutMac/DerivedData-Package" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
ditto "$ROOT/CodeCutMac/DerivedData-Package/Build/Products/Release/CodeCut.app" "$OUT/CodeCut.app"
codesign --verify --deep --strict --verbose=2 "$OUT/CodeCut.app"
ditto -c -k --sequesterRsrc --keepParent "$OUT/CodeCut.app" "$OUT/CodeCut-macOS-arm64.zip"
git -C "$ROOT" archive --format=zip --prefix=CodeCut-source/ -o "$OUT/CodeCut-source.zip" HEAD
git -C "$ROOT" bundle create "$OUT/CodeCut-history.bundle" --all
git -C "$ROOT" rev-parse HEAD > "$OUT/SOURCE_COMMIT.txt"
cp "$ROOT/CodeCutMac/PACKAGING.md" "$OUT/README.md"
(cd "$OUT" && shasum -a 256 CodeCut-macOS-arm64.zip CodeCut-source.zip CodeCut-history.bundle SOURCE_COMMIT.txt README.md > SHA256SUMS.txt)
printf 'Package output: %s\n' "$OUT"
