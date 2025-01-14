#!/bin/sh

set -u

# Modified version of script found at:
# https://forum.qt.io/topic/96652/how-to-notarize-qt-application-on-macos/18

# Add Qt binaries to path
PATH="/usr/local/opt/qt@5/bin/:${PATH}"

security unlock-keychain -p "${RUNNER_USER_PW}" login.keychain

( cd build || exit
  # macdeployqt does not copy symlinks over.
  # this specifically addresses icu4c issues but nothing else.
  # We might not even need this any longer... 
  # ICU_LIB="$(brew --prefix icu4c)/lib"
  # export ICU_LIB
  # mkdir -p nheko.app/Contents/Frameworks
  # find "${ICU_LIB}" -type l -name "*.dylib" -exec cp -a -n {} nheko.app/Contents/Frameworks/ \; || true

  macdeployqt nheko.app -dmg -always-overwrite -qmldir=../resources/qml/ -sign-for-notarization="${APPLE_DEV_IDENTITY}"

  user=$(id -nu)
  chown "${user}" nheko.dmg
)

NOTARIZE_SUBMIT_LOG=$(mktemp -t notarize-submit)
NOTARIZE_STATUS_LOG=$(mktemp -t notarize-status)

finish() {
  rm "$NOTARIZE_SUBMIT_LOG" "$NOTARIZE_STATUS_LOG"
}
trap finish EXIT

dmgbuild -s .ci/macos/settings.json "Nheko" nheko.dmg
codesign -s "${APPLE_DEV_IDENTITY}" nheko.dmg
user=$(id -nu)
chown "${user}" nheko.dmg

echo "--> Start Notarization process"
xcrun altool -t osx -f nheko.dmg --primary-bundle-id "io.github.nheko-reborn.nheko" --notarize-app -u "${APPLE_DEV_USER}" -p "${APPLE_DEV_PASS}" > "$NOTARIZE_SUBMIT_LOG" 2>&1
requestUUID="$(awk -F ' = ' '/RequestUUID/ {print $2}' "$NOTARIZE_SUBMIT_LOG")"

while sleep 60 && date; do
  echo "--> Checking notarization status for ${requestUUID}"

  xcrun altool --notarization-info "${requestUUID}" -u "${APPLE_DEV_USER}" -p "${APPLE_DEV_PASS}" > "$NOTARIZE_STATUS_LOG" 2>&1

  isSuccess=$(grep "success" "$NOTARIZE_STATUS_LOG")
  isFailure=$(grep "invalid" "$NOTARIZE_STATUS_LOG")

  if [ -n "${isSuccess}" ]; then
      echo "Notarization done!"
      xcrun stapler staple -v nheko.dmg
      echo "Stapler done!"
      break
  fi
  if [ -n "${isFailure}" ]; then
      echo "Notarization failed"
      cat "$NOTARIZE_STATUS_LOG" 1>&2
      return 1
  fi
  echo "Notarization not finished yet, sleep 1m then check again..."
done

VERSION=${CI_COMMIT_SHORT_SHA}

if [ -n "$VERSION" ]; then
    mv nheko.dmg "nheko-${VERSION}.dmg"
    mkdir artifacts
    cp "nheko-${VERSION}.dmg" artifacts/
fi