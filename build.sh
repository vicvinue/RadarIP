#!/bin/zsh
# Compila RadarIP.app.
#   ./build.sh            compila para este Mac (build/RadarIP.app)
#   ./build.sh install    compila, instala en ~/Applications y abre la app
#   ./build.sh dmg        compila universal (Apple Silicon + Intel) y crea build/RadarIP-<versión>.dmg
#   ./build.sh test       ejecuta las pruebas
#   ./build.sh update-oui descarga la base de fabricantes (OUI) de Wireshark
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-}"
OUI_URL=https://www.wireshark.org/download/automated/data/manuf

if [[ "$MODE" == "update-oui" || ! -f Resources/manuf ]]; then
  curl -fsSL -o Resources/manuf.new "$OUI_URL"
  mv Resources/manuf.new Resources/manuf
  echo "Base de fabricantes: $(grep -vc '^#' Resources/manuf) prefijos"
  [[ "$MODE" == "update-oui" ]] && exit 0
fi
if [[ "$MODE" == "test" ]]; then
  mkdir -p build
  swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" -framework SystemConfiguration \
    $(ls Sources/*.swift | grep -v App.swift) Tests/main.swift -o build/RadarIPTests
  exec build/RadarIPTests
fi

APP=build/RadarIP.app
ARCHS=("$(uname -m)")
[[ "$MODE" == "dmg" ]] && ARCHS=(arm64 x86_64)
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BINS=()
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" \
    -framework SystemConfiguration -framework AppKit -framework SwiftUI \
    Sources/*.swift -o "build/RadarIP-$arch"
  BINS+=("build/RadarIP-$arch")
done
lipo -create $BINS -output "$APP/Contents/MacOS/RadarIP"
rm -f $BINS
if [[ ! -f Resources/AppIcon.icns || Resources/AppIcon.svg -nt Resources/AppIcon.icns ]] && command -v rsvg-convert >/dev/null; then
  Resources/make-icon.sh
fi
cp Resources/AppIcon.icns Resources/github-mark.pdf Resources/manuf "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
# Firma local (ad-hoc) con requisito por identificador: el permiso de «Red local» se conserva al actualizar.
codesign --force --sign - -r='designated => identifier "cl.vicvinue.radarip"' "$APP"

if [[ "$MODE" == "install" ]]; then
  pkill -x RadarIP 2>/dev/null && while pgrep -x RadarIP >/dev/null; do sleep 0.2; done || true
  rm -rf ~/Applications/RadarIP.app
  mkdir -p ~/Applications
  cp -R "$APP" ~/Applications/RadarIP.app
  open ~/Applications/RadarIP.app
  echo "Instalado en ~/Applications/RadarIP.app"
elif [[ "$MODE" == "dmg" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
  STAGE=build/dmg
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Aplicaciones"
  DMG="build/RadarIP-$VERSION.dmg"
  hdiutil create -volname "RadarIP $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "Creado $DMG ($(du -h "$DMG" | cut -f1))"
fi
