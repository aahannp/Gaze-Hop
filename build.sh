#!/bin/bash
# Build, bundle and sign GlanceSwitch.app.   ./build.sh [install]
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=GlanceSwitch
BUNDLE_ID=com.aahan.glanceswitch
CERT_NAME="GlanceSwitch Dev"
APP="build/$APP_NAME.app"

find_identity() {
  # SIGN_IDENTITY env var overrides (e.g. an Apple Development cert name or hash).
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then echo "$SIGN_IDENTITY"; return; fi
  if security find-identity -p codesigning 2>/dev/null | grep -q "\"$CERT_NAME\""; then echo "$CERT_NAME"; fi
}

create_cert() {
  local tmp; tmp=$(mktemp -d)
  cat > "$tmp/cert.cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cfg" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" \
    -passout pass:glance 2>/dev/null
  security import "$tmp/id.p12" -k ~/Library/Keychains/login.keychain-db -P glance \
    -T /usr/bin/codesign >/dev/null
  # Trust it for code signing (macOS asks for your password / Touch ID once).
  security add-trusted-cert -r trustRoot -p codeSign \
    -k ~/Library/Keychains/login.keychain-db "$tmp/cert.pem" || true
  rm -rf "$tmp"
}

echo "==> swift build -c release"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

# ~/Desktop is iCloud-synced: Finder info / resource forks get attached to files there and make codesign
# fail ("detritus"). Assemble and sign in a non-synced staging dir, then copy the signed bundle out.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/glanceswitch-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
SAPP="$STAGE/$APP_NAME.app"
COPY=(ditto --norsrc --noextattr)

echo "==> assembling $SAPP"
mkdir -p "$SAPP/Contents/MacOS" "$SAPP/Contents/Resources/Models"
"${COPY[@]}" "$BIN" "$SAPP/Contents/MacOS/$APP_NAME"
"${COPY[@]}" Resources/Info.plist "$SAPP/Contents/Info.plist"

# MediaPipe mesh tracker models (MeshModelPaths.locate looks in Contents/Resources/Models).
for m in Sources/GlanceKit/Tracking/Models/*.onnx; do
  "${COPY[@]}" "$m" "$SAPP/Contents/Resources/Models/$(basename "$m")"
done

# onnxruntime is linked statically; make sure nothing points back into the build tree or a loose dylib.
if otool -L "$SAPP/Contents/MacOS/$APP_NAME" | tail -n +2 | awk '{print $1}' \
     | grep -Ev '^(/usr/lib/|/System/Library/)'; then
  echo "error: binary links against a non-system library (listed above); embed + sign it in Contents/Frameworks" >&2
  exit 1
fi

# Generated icon (eye glyph on a gradient squircle) — best effort.
if [[ -f Resources/make_icon.swift ]]; then
  ICONSET=$(mktemp -d)/AppIcon.iconset
  if swift Resources/make_icon.swift "$ICONSET" >/dev/null 2>&1 && iconutil -c icns "$ICONSET" -o "$SAPP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    :
  else
    echo "warning: icon generation failed; continuing without icon"
  fi
fi

xattr -cr "$SAPP" 2>/dev/null || true
IDENTITY="$(find_identity || true)"
if [[ -z "$IDENTITY" ]]; then
  echo
  echo "No stable signing identity \"$CERT_NAME\" found."
  echo "Ad-hoc signing changes the code hash on every rebuild, and macOS then DROPS your"
  echo "Accessibility / Input Monitoring grants each time. A local self-signed cert avoids that."
  if [[ -t 0 ]]; then
    read -r -p "Create a local \"$CERT_NAME\" code-signing certificate in your login keychain now? [y/N] " ans
    if [[ "$ans" =~ ^[Yy] ]]; then create_cert; IDENTITY="$(find_identity || true)"; fi
  fi
fi

if [[ -n "$IDENTITY" ]]; then
  echo "==> codesign with \"$IDENTITY\""
  codesign --force --deep --identifier "$BUNDLE_ID" \
    --entitlements Resources/GlanceSwitch.entitlements --sign "$IDENTITY" "$SAPP" \
    || { echo "warning: signing with \"$IDENTITY\" failed; falling back to ad-hoc"; IDENTITY=""; }
fi
if [[ -z "$IDENTITY" ]]; then
  echo "warning: signing ad-hoc — permissions will need re-granting after every rebuild"
  codesign --force --deep --identifier "$BUNDLE_ID" --entitlements Resources/GlanceSwitch.entitlements --sign - "$SAPP"
fi
codesign --verify --deep --strict "$SAPP"

rm -rf "$APP"; mkdir -p build
"${COPY[@]}" "$SAPP" "$APP"
echo "==> built $APP (signed in $STAGE)"

if [[ "${1:-}" == "install" ]]; then
  mkdir -p ~/Applications
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf ~/Applications/$APP_NAME.app
  "${COPY[@]}" "$SAPP" ~/Applications/$APP_NAME.app
  echo "==> installed to ~/Applications/$APP_NAME.app"
  open ~/Applications/$APP_NAME.app
fi

if [[ "${1:-}" == "dmg" ]]; then
  # Drag-to-install disk image: the signed app + an /Applications shortcut. Built in the staging dir (not iCloud).
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SAPP/Contents/Info.plist" 2>/dev/null || echo 1.0)"
  DMG_SRC="$STAGE/dmg"; DMG_OUT="$STAGE/$APP_NAME-$VERSION.dmg"
  mkdir -p "$DMG_SRC"
  "${COPY[@]}" "$SAPP" "$DMG_SRC/$APP_NAME.app"
  ln -s /Applications "$DMG_SRC/Applications"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$DMG_SRC" -fs APFS -format UDZO -ov "$DMG_OUT"
  if [[ -n "$IDENTITY" ]]; then codesign --force --sign "$IDENTITY" "$DMG_OUT"; fi
  hdiutil verify -quiet "$DMG_OUT"
  "${COPY[@]}" "$DMG_OUT" "build/$APP_NAME-$VERSION.dmg"
  echo "==> dmg build/$APP_NAME-$VERSION.dmg"
fi
