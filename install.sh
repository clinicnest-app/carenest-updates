#!/bin/bash
# ClinicNest – install or update on a Mac with one command (Terminal):
#
#   curl -fsSL https://updates.clinicnest.app/install.sh | bash
#
# What it does: downloads the official ClinicNest.dmg of the latest release, checks it against SHA256SUMS, whose
# signature is checked with ClinicNest's public key below (the same key the automatic updates are checked with),
# copies ClinicNest.app to Applications and starts it. Anything changed or incomplete is refused and nothing is
# installed. No administrator password is needed when /Applications is writable (else ~/Applications is used).
# The clinic's data is not touched (it lives in ~/Library/Application Support/Clinic).
#
# Testing: CLINICNEST_DOWNLOAD=<base URL>  CLINICNEST_APPS_DIR=<folder>  CLINICNEST_NO_START=1
set -euo pipefail

BASE="${CLINICNEST_DOWNLOAD:-https://github.com/clinicnest-app/clinic-nest-updates/releases/latest/download}"
APP="ClinicNest"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mNot installed:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "this is the Mac installer. On Windows, use the PowerShell command from https://updates.clinicnest.app"
[ "$(uname -m)" = "arm64" ] || fail "ClinicNest for Mac needs Apple silicon (M1 or later). Intel Macs are not supported yet."

TMP="$(mktemp -d)"
MOUNT="$TMP/mount"
cleanup() {
  hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# ClinicNest's public key (launcher/src/main/resources/update-signing.pub)
cat > "$TMP/clinicnest.pub" <<'KEY'
-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEA4iawPd43ggtkWOtePzyY
hmxQQS/FI8kJo9odZOBqz0e/ZouURsXXJLwy4vciULx5sVHk0w2dm9NyZ+v00kVS
BtvzJzYT38EPvMHDRqiDX7LPEm61ZwDC+gk5gjkorOLJcta36HrKvUtVbFVjf8Fq
pJaFU0KecQxUxA9SgwgRlCOxTwiM/w5ODd8/vR57ckX7E6UsrM7IttBmNM7dxozQ
tdNISk1L3OCjjwsLPa4xhWYPXunNB04/dDRQxr/5rTa0CVRzXl0pMSXlc5nUyHcm
WRL6kQxT9g4MTXiZ4/sqjLxGBRFGxdx7MZCoPmwRet+51xPt0Cv5GBdb31oA0TDm
ymlyq9DP+qO64Azo4aZ8aPam7bBLHK2e5ZUZTYX59pye3ZtDcDMohWheLEADfzd6
mlZBqtaUb9CgNpXc3yIgPWTnQzL6On+l/YJpvpysKprecsW8ipfoXW6duhafgho4
LdDPZ6Qg8FWENrxXp2YxwKTtx3KVowXkggni3oyi37x1AgMBAAE=
-----END PUBLIC KEY-----
KEY

bold "Downloading ClinicNest …"
download() { curl -fL --retry 3 --connect-timeout 20 "$@"; }
download -sS -o "$TMP/SHA256SUMS" "$BASE/SHA256SUMS" || fail "could not download from $BASE – check the internet connection."
download -sS -o "$TMP/SHA256SUMS.sig" "$BASE/SHA256SUMS.sig" || fail "the signature file is missing. Try again in a few minutes."
download --progress-bar -o "$TMP/$APP.dmg" "$BASE/$APP.dmg" || fail "the download of $APP.dmg failed. Try again."

bold "Checking the download …"
# /usr/bin/openssl (LibreSSL) is on every Mac
/usr/bin/openssl dgst -sha256 -verify "$TMP/clinicnest.pub" -signature "$TMP/SHA256SUMS.sig" "$TMP/SHA256SUMS" >/dev/null 2>&1 \
  || fail "the checksum file is not signed by ClinicNest. Nothing was installed – please tell support@clinicnest.app."
expected="$(awk -v f="$APP.dmg" '{ name = $2; sub(/^\*/, "", name) } name == f { print $1 }' "$TMP/SHA256SUMS")"
actual="$(shasum -a 256 "$TMP/$APP.dmg" | awk '{ print $1 }')"
[ -n "$expected" ] && [ "$expected" = "$actual" ] \
  || fail "the download is damaged or was changed on the way. Nothing was installed – try again."
echo "Signature and checksum OK."

bold "Installing …"
DEST="${CLINICNEST_APPS_DIR:-}"
if [ -z "$DEST" ]; then
  DEST="/Applications"
  [ -w "$DEST" ] || DEST="$HOME/Applications"
  # an update: close the running copy first (its data is kept)
  if pgrep -f "$APP.app/Contents" >/dev/null 2>&1; then
    echo "Closing the running ClinicNest …"
    osascript -e "quit app \"$APP\"" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do pgrep -f "$APP.app/Contents" >/dev/null 2>&1 || break; sleep 1; done
  fi
fi
mkdir -p "$DEST"
mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$TMP/$APP.dmg" || fail "the disk image could not be opened."
[ -d "$MOUNT/$APP.app" ] || fail "$APP.app is missing in the disk image."
rm -rf "$DEST/$APP.app.new"
ditto "$MOUNT/$APP.app" "$DEST/$APP.app.new"
rm -rf "$DEST/$APP.app"
mv "$DEST/$APP.app.new" "$DEST/$APP.app"
hdiutil detach -quiet "$MOUNT" || true
echo "Installed: $DEST/$APP.app"

if [ -z "${CLINICNEST_NO_START:-}" ]; then
  bold "Starting ClinicNest …"
  open "$DEST/$APP.app"
fi

cat <<'NEXT'

Done. ClinicNest opens in the browser in a moment (first start: about 30 seconds).
 • If the Mac asks "Allow ClinicNest to find devices on your local network?", click Allow –
   otherwise phones and other computers in the clinic cannot open ClinicNest.
 • ClinicNest updates itself; run this command again only to repair an installation.
 • Remove it later with the Uninstall button in ClinicNest's status window.
NEXT
