#!/bin/bash
# Construit OutputsSync Nightly.app (bundle menu-bar signé ad-hoc).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="OutputsSync Nightly.app"
BIN="OutputsSyncNightly"
CONTENTS="$APP/Contents"

echo "▸ Compilation release…"
swift build -c release

echo "▸ Assemblage du bundle…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp ".build/release/$BIN" "$CONTENTS/MacOS/$BIN"
cp assets/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"

# Embarque le driver dans l'app pour l'installation guidée au 1ᵉʳ lancement.
if [ -d build/OutputsSyncDriver.driver ]; then
    cp -R build/OutputsSyncDriver.driver "$CONTENTS/Resources/OutputsSyncDriver.driver"
fi

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>OutputsSync</string>
    <key>CFBundleDisplayName</key>       <string>OutputsSync</string>
    <key>CFBundleIdentifier</key>        <string>com.outputssync.nightly.app</string>
    <key>CFBundleExecutable</key>        <string>OutputsSyncNightly</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleVersion</key>           <string>1.1.0</string>
    <key>CFBundleShortVersionString</key><string>1.1.0</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>15.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>OutputsSync lit l'audio des apps via le périphérique loopback « OutputsSync Nightly » pour le redistribuer vers plusieurs sorties. Aucun micro réel n'est utilisé.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>OutputsSync utilise le réseau local pour partager le son entre plusieurs ordinateurs d'une même « room » et les garder synchronisés.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_outputssync._tcp</string>
    </array>
</dict>
</plist>
PLIST

echo "▸ Signature ad-hoc…"
codesign --force --sign - --timestamp=none "$APP"

echo "✅ \"$APP\" prêt."
echo "   Lancer :  open \"$APP\""
