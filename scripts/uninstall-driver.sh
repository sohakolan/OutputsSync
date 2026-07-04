#!/bin/bash
# Retire le driver OutputsSync Nightly et redémarre coreaudiod.
# ⚠️ Coupe brièvement tout l'audio du système (redémarrage du serveur audio).
set -euo pipefail

DEST="/Library/Audio/Plug-Ins/HAL/OutputsSyncDriver.driver"

if [ ! -d "$DEST" ]; then
    echo "Driver non installé (rien à retirer) : $DEST"
    exit 0
fi

echo "▸ Suppression de $DEST (sudo requis)…"
sudo rm -rf "$DEST"

echo "▸ Redémarrage de coreaudiod (l'audio se coupe 2-3 s)…"
sudo killall coreaudiod || true

echo "✅ Driver retiré."
echo "   Vérifie qu'il a disparu :"
echo "   system_profiler SPAudioDataType | grep -c OutputsSync   # doit afficher 0"
