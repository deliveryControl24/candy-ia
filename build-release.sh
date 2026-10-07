#!/usr/bin/env bash
# Compila CANDY IA (universal), arma el .app, firma y crea el DMG.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-1.0}"
mkdir -p build

echo "▸ Compilando (x86_64 + arm64)…"
swiftc -O -target x86_64-apple-macos14.0 macOS/Sources/*.swift -o build/CandyIA-x86_64
swiftc -O -target arm64-apple-macos14.0 macOS/Sources/*.swift -o build/CandyIA-arm64
lipo -create build/CandyIA-x86_64 build/CandyIA-arm64 -output build/CandyIA
echo "  ✔ binario universal"

echo "▸ Selftest…"
./build/CandyIA --selftest | tail -3

echo "▸ Armando CandyIA.app…"
rm -rf build/CandyIA.app
mkdir -p build/CandyIA.app/Contents/MacOS build/CandyIA.app/Contents/Resources
cp build/CandyIA build/CandyIA.app/Contents/MacOS/CandyIA
cp macOS/Info.plist build/CandyIA.app/Contents/Info.plist
cp assets/CandyIA.icns build/CandyIA.app/Contents/Resources/CandyIA.icns
codesign --force --deep --sign - build/CandyIA.app
codesign --verify --deep --strict build/CandyIA.app
echo "  ✔ app firmada"

echo "▸ Creando DMG…"
rm -rf build/dmg build/CandyIA.dmg
mkdir -p build/dmg
cp -R build/CandyIA.app build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "CANDY IA" -srcfolder build/dmg -ov -format UDZO \
  "build/CandyIA-${VERSION}.dmg" >/dev/null
cp "build/CandyIA-${VERSION}.dmg" build/CandyIA.dmg
echo "  ✔ build/CandyIA-${VERSION}.dmg  (+ alias CandyIA.dmg)"
