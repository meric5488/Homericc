#!/bin/zsh
# Builds Homericc. INSTALL=1 ./build.sh also copies it to /Applications and reopens it.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="-"
if security find-identity -v -p codesigning | grep -q "Homericc Local Signing"; then
  IDENTITY="Homericc Local Signing"
fi

xcodegen generate -q
xcodebuild -project Homericc.xcodeproj -scheme Homericc -configuration "${CONFIGURATION:-Debug}" \
  -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY="$IDENTITY" build -quiet
APP="build/DerivedData/Build/Products/${CONFIGURATION:-Debug}/Homericc.app"
echo "Compilé : $APP (signature : $IDENTITY)"

if [[ "${INSTALL:-0}" == 1 ]]; then
  osascript -e 'tell application "Homericc" to quit' 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Homericc.app
  cp -R "$APP" /Applications/
  open /Applications/Homericc.app
  echo "Installé dans /Applications."
fi
