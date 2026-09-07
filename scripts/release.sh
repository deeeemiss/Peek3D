#!/bin/bash
# Costruisce, firma, notarizza e impacchetta Peek3D per la distribuzione
# fuori dal Mac App Store (download diretto e cask Homebrew).
#
# Prerequisito una tantum, da fare a mano perché richiede una credenziale:
#   xcrun notarytool store-credentials peek3d \
#       --apple-id <apple-id> --team-id 3E4CBEZXCG --password <app-specific-password>
# La password specifica per app si crea su appleid.apple.com ▸ Accesso e
# sicurezza ▸ Password per le app. NON è la password dell'Apple ID.
#
# Uso: scripts/release.sh [--skip-notarize]
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY="Developer ID Application: Sebastiano Demichelis (3E4CBEZXCG)"
PROFILE="peek3d"
BUILD_DIR="build-dist"
APP="$BUILD_DIR/Peek3D.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Peek3D/Info.plist 2>/dev/null || echo "1.0")
DMG="$BUILD_DIR/Peek3D-$VERSION.dmg"

echo "==> Build di archivio (Release, firmata Developer ID)"
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
xcodebuild -project Peek3D.xcodeproj -scheme Peek3D -configuration Release \
  -derivedDataPath build-release \
  -archivePath "$BUILD_DIR/Peek3D.xcarchive" \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=3E4CBEZXCG \
  archive

cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>3E4CBEZXCG</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST

echo "==> Export dell'app firmata"
xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/Peek3D.xcarchive" \
  -exportPath "$BUILD_DIR" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist"

echo "==> Controlli sulla firma"
codesign --verify --deep --strict --verbose=2 "$APP"
# get-task-allow in una build distribuita fa fallire la notarizzazione.
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  echo "ERRORE: get-task-allow presente nella build di distribuzione" >&2
  exit 1
fi
codesign -d --verbose=2 "$APP" 2>&1 | grep -E "TeamIdentifier|flags"

if [[ "${1:-}" != "--skip-notarize" ]]; then
  # Notarizzare e stapleare l'APP prima di impacchettarla. Stapleare solo il
  # DMG lascia scoperto il caso concreto: l'utente trascina Peek3D in
  # Applications, espelle il DMG e apre l'app da offline — senza ticket
  # incorporato Gatekeeper deve interrogare Apple, e senza rete blocca.
  echo "==> Notarizzazione dell'app"
  ditto -c -k --keepParent "$APP" "$BUILD_DIR/Peek3D-app.zip"
  xcrun notarytool submit "$BUILD_DIR/Peek3D-app.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$BUILD_DIR/Peek3D-app.zip"
fi

echo "==> Creazione DMG"
STAGE="$BUILD_DIR/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Peek3D" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ "${1:-}" == "--skip-notarize" ]]; then
  echo "==> Notarizzazione saltata su richiesta"
else
  echo "==> Notarizzazione (può richiedere qualche minuto)"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  echo "==> Stapling"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  # Il verdetto che conta: è ciò che Gatekeeper dirà sul Mac di un cliente.
  spctl -a -vvv -t install "$DMG" 2>&1 | tail -3
fi

echo
echo "DMG:    $DMG"
echo "SHA256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
