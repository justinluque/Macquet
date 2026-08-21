#!/bin/bash
#
# Builds Macquet.app and, optionally, installs it.
#
#   ./Scripts/build-app.sh                build into ./build
#   ./Scripts/build-app.sh --install      also copy to ~/Applications and register
#   ./Scripts/build-app.sh --release v0.1 zip the app and publish a GitHub release
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="release"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Macquet.app"
INSTALL=false
RELEASE_TAG=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install) INSTALL=true ;;
    --debug) CONFIGURATION="debug" ;;
    --release)
      shift
      RELEASE_TAG="${1:-}"
      [ -n "$RELEASE_TAG" ] || { echo "--release requires a tag, e.g. --release v0.1" >&2; exit 1; }
      ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

echo "==> Building ($CONFIGURATION)"
cd "$ROOT"
swift build -c "$CONFIGURATION" --product Macquet
swift build -c "$CONFIGURATION" --product MacquetQL
swift build -c "$CONFIGURATION" --product MacquetQuickLook

BIN="$ROOT/.build/$CONFIGURATION"
APPEX="$APP/Contents/PlugIns/MacquetQuickLook.appex"

echo "==> Assembling Macquet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/Macquet" "$APP/Contents/MacOS/Macquet"
# The CLI ships inside the bundle so `--install` can symlink it onto PATH.
cp "$BIN/MacquetQL" "$APP/Contents/MacOS/macquetql"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Macquet.icns" "$APP/Contents/Resources/Macquet.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Embedding Quick Look extension"
mkdir -p "$APPEX/Contents/MacOS"
cp "$BIN/MacquetQuickLook" "$APPEX/Contents/MacOS/MacquetQuickLook"
cp "$ROOT/Resources/QuickLook-Info.plist" "$APPEX/Contents/Info.plist"
printf 'XPC!????' > "$APPEX/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
# Nested code is signed first, then the container seals it. `--deep` would
# re-sign the extension on the way past and strip its sandbox entitlements,
# which stops Quick Look loading it at all.
codesign --force --sign - \
  --entitlements "$ROOT/Resources/QuickLook.entitlements" \
  --identifier com.justinluque.Macquet.QuickLook \
  "$APPEX"
codesign --force --sign - --identifier com.justinluque.Macquet "$APP"

codesign --verify --verbose=1 "$APPEX" 2>&1 | sed 's/^/    /'

echo "==> Built $APP"

if [ "$INSTALL" = true ]; then
  DESTINATION="$HOME/Applications"
  mkdir -p "$DESTINATION"
  echo "==> Installing to $DESTINATION"
  rm -rf "$DESTINATION/Macquet.app"
  cp -R "$APP" "$DESTINATION/Macquet.app"

  echo "==> Registering with Launch Services"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DESTINATION/Macquet.app"

  echo "==> Registering the Quick Look extension"
  # Extensions are discovered from the installed bundle, not the build
  # directory, so this has to point at the copy in $DESTINATION.
  pluginkit -a "$DESTINATION/Macquet.app/Contents/PlugIns/MacquetQuickLook.appex" 2>/dev/null || true
  qlmanage -r >/dev/null 2>&1 || true
  qlmanage -r cache >/dev/null 2>&1 || true
  pluginkit -m -p com.apple.quicklook.preview -v 2>/dev/null | grep -i macquet | sed 's/^/    /' || true

  # Put the CLI on PATH if a sensible bin directory exists.
  for candidate in "$HOME/.local/bin" "/usr/local/bin"; do
    if [ -d "$candidate" ] && [ -w "$candidate" ]; then
      ln -sf "$DESTINATION/Macquet.app/Contents/MacOS/macquetql" "$candidate/macquetql"
      echo "==> Linked macquetql into $candidate"
      break
    fi
  done

  echo
  echo "Installed. Double-click any .parquet file, or run:"
  echo "  open -a Macquet <file.parquet>"
fi

if [ -n "$RELEASE_TAG" ]; then
  command -v gh >/dev/null 2>&1 || { echo "gh (GitHub CLI) is required for --release" >&2; exit 1; }

  ZIP="$BUILD_DIR/Macquet-$RELEASE_TAG.zip"
  echo "==> Zipping $APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"

  echo "==> Publishing GitHub release $RELEASE_TAG"
  gh release create "$RELEASE_TAG" "$ZIP" \
    --title "Macquet $RELEASE_TAG" \
    --generate-notes

  echo "==> Released: $(gh release view "$RELEASE_TAG" --json url -q .url)"
fi
