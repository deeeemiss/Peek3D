#!/bin/bash
# Compila Peek3D da sorgente e lo apre. Pensato per chi clona il repo:
# non serve nessun certificato Apple né un account sviluppatore.
#
# La build è firmata ad-hoc e senza hardened runtime. Con l'hardened runtime
# attivo, macOS rifiuta di caricare GLTFKit2 in un'app firmata ad-hoc
# ("different Team IDs"); l'hardened runtime serve solo alla notarizzazione,
# che questa build non fa (per quella c'è scripts/release.sh).
#
# Uso: scripts/run.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Serve Xcode (non bastano i Command Line Tools): installalo dall'App Store," >&2
  echo "poi esegui: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

# PATH di sistema: un `unzip` di terze parti (es. MacPorts per Intel) fa
# fallire la risoluzione dei pacchetti Swift con "Bad CPU type".
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

echo "==> Compilo Peek3D (Release)…"
xcodebuild -project Peek3D.xcodeproj -scheme Peek3D -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=NO \
  -quiet build

APP="build/Build/Products/Release/Peek3D.app"
echo "==> Fatto: $APP"
open "$APP"
