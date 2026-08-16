#!/bin/bash
#
# Builds Macquet.app and, optionally, installs it.
#
#   ./Scripts/build-app.sh            build into ./build
#   ./Scripts/build-app.sh --install  also copy to ~/Applications and register
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="release"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Macquet.app"
INSTALL=false

for argument in "$@"; do
  case "$argument" in
    --install) INSTALL=true ;;
    --debug) CONFIGURATION="debug" ;;
    *) echo "unknown option: $argument" >&2; exit 1 ;;
  esac
done

echo "==> Building ($CONFIGURATION)"
cd "$ROOT"
swift build -c "$CONFIGURATION" --product Macquet
swift build -c "$CONFIGURATION" --product MacquetQL

BIN="$ROOT/.build/$CONFIGURATION"

echo "==> Assembling Macquet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/Macquet" "$APP/Contents/MacOS/Macquet"
# The CLI ships inside the bundle so `--install` can symlink it onto PATH.
cp "$BIN/MacquetQL" "$APP/Contents/MacOS/macquetql"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Macquet.icns" "$APP/Contents/Resources/Macquet.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
# Ad-hoc signing is enough for a locally built app and keeps Launch Services
# from treating the bundle as damaged.
codesign --force --deep --sign - "$APP" 2>/dev/null

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
