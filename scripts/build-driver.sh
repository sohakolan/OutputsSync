#!/bin/bash
# Compile le driver OutputsSyncDriver.driver (bundle AudioServerPlugIn, signé ad-hoc).
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Driver/OutputsSyncDriver/OutputsSyncDriver.c"
PLIST="Driver/OutputsSyncDriver/Info.plist"
OUT="build/OutputsSyncDriver.driver"
CONTENTS="$OUT/Contents"

echo "▸ Compilation du driver…"
rm -rf "$OUT"
mkdir -p "$CONTENTS/MacOS"
cp "$PLIST" "$CONTENTS/Info.plist"

clang -bundle \
    -arch arm64 \
    -mmacosx-version-min=12.0 \
    -O2 -Wall -Wno-deprecated-declarations \
    -framework CoreFoundation -framework CoreAudio \
    -o "$CONTENTS/MacOS/OutputsSyncDriver" \
    "$SRC"

echo "▸ Signature ad-hoc…"
codesign --force --sign - --timestamp=none "$OUT"

echo "✅ $OUT prêt."
