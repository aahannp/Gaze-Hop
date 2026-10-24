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

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Generated icon (eye glyph on a gradient squircle) — best effort.
if [[ -f Resources/make_icon.swift ]]; then
  ICONSET=$(mktemp -d)/AppIcon.iconset
  if swift Resources/make_icon.swift "$ICONSET" >/dev/null 2>&1 && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    :
  else
    echo "warning: icon generation failed; continuing without icon"
  fi
fi

xattr -cr "$APP" 2>/dev/null || true
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
    --entitlements Resources/GlanceSwitch.entitlements --sign "$IDENTITY" "$APP" \
    || { echo "warning: signing with \"$IDENTITY\" failed; falling back to ad-hoc"; IDENTITY=""; }
fi
if [[ -z "$IDENTITY" ]]; then
  echo "warning: signing ad-hoc — permissions will need re-granting after every rebuild"
  codesign --force --deep --identifier "$BUNDLE_ID" --entitlements Resources/GlanceSwitch.entitlements --sign - "$APP"
fi
codesign --verify --deep "$APP" && echo "==> built $APP"

if [[ "${1:-}" == "install" ]]; then
  mkdir -p ~/Applications
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf ~/Applications/$APP_NAME.app
  cp -R "$APP" ~/Applications/
  echo "==> installed to ~/Applications/$APP_NAME.app"
  open ~/Applications/$APP_NAME.app
fi
