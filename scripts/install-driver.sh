#!/bin/bash
# Installe le driver dans /Library/Audio/Plug-Ins/HAL et redémarre coreaudiod.
# ⚠️ Coupe brièvement tout l'audio du système (redémarrage du serveur audio).
set -euo pipefail
cd "$(dirname "$0")/.."

DRIVER="build/OutputsSyncDriver.driver"
DEST="/Library/Audio/Plug-Ins/HAL"

if [ ! -d "$DRIVER" ]; then
    echo "Driver absent. Lance d'abord : ./scripts/build-driver.sh"
    exit 1
fi

echo "▸ Installation dans $DEST (sudo requis)…"
sudo rm -rf "$DEST/OutputsSyncDriver.driver"
sudo cp -R "$DRIVER" "$DEST/"
sudo chown -R root:wheel "$DEST/OutputsSyncDriver.driver"

echo "▸ Redémarrage de coreaudiod (l'audio se coupe 2-3 s)…"
sudo killall coreaudiod || true

echo "✅ Installé. Vérifie l'apparition de « OutputsSync Nightly » :"
echo "   system_profiler SPAudioDataType | grep -A1 'OutputsSync'"
echo
echo "Règle « OutputsSync Nightly » comme sortie système, puis lance l'app."
echo "Pour désinstaller :  ./scripts/uninstall-driver.sh"
