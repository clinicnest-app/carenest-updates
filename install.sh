#!/bin/bash
# ClinicNest – install or update on a Mac with one command (Terminal):
#
#   curl -fsSL https://updates.clinicnest.app/install.sh | bash
#   curl -fsSL https://updates.clinicnest.app/install.sh | bash -s server     ClinicNest Server (PostgreSQL built in)
#
# What it does: downloads the official ClinicNest.dmg of the latest release, checks it against SHA256SUMS, whose
# signature is checked with ClinicNest's public key below (the same key the automatic updates are checked with),
# copies ClinicNest.app to Applications and starts it. Anything changed or incomplete is refused and nothing is
# installed. No administrator password is needed when /Applications is writable (else ~/Applications is used).
# The clinic's data is not touched (it lives in ~/Library/Application Support/Clinic; the server edition's in
# …/Clinic Server). "server" (or CLINICNEST_EDITION=server) installs ClinicNest Server.app from ClinicNest-Server.dmg;
# it sits beside ClinicNest.
#
# Downloaded from downloads.clinicnest.app; when that cannot be reached, from the GitHub Release (some networks
# block the one or the other). Wherever it comes from, the same signature check decides.
#
# Testing: CLINICNEST_DOWNLOAD="<base URL> [<second base URL>]"  CLINICNEST_APPS_DIR=<folder>  CLINICNEST_NO_START=1
set -euo pipefail

# where the installers are: our own address first, the GitHub Release second
SOURCES="${CLINICNEST_DOWNLOAD:-https://downloads.clinicnest.app/latest https://github.com/clinicnest-app/clinic-nest-updates/releases/latest/download}"
# APP: the app's name; FILE: its disk image's name
case "${1:-${CLINICNEST_EDITION:-}}" in
  server) APP="ClinicNest Server"; FILE="ClinicNest-Server" ;;
  "") APP="ClinicNest"; FILE="ClinicNest" ;;
  *) printf 'Unknown option "%s" – use nothing (ClinicNest) or "server" (ClinicNest Server).\n' "$1" >&2; exit 1 ;;
esac

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

# the server edition as a background service runs from the app: it cannot be replaced under it
if [ "$FILE" = ClinicNest-Server ] && [ -f /Library/LaunchDaemons/app.clinic.clinicnest.server.plist ] && [ -z "${CLINICNEST_APPS_DIR:-}" ]; then
  fail "ClinicNest Server runs as a background service and updates itself. To reinstall it, first open it and click
\"Stop starting with the computer…\", then run this command again."
fi

bold "Downloading $APP …"
download() { curl -fL --retry 3 --connect-timeout 20 "$@"; }
# all three files from the same place, so they belong together
fetch() {
  download -sS -o "$TMP/SHA256SUMS" "$1/SHA256SUMS" 2> /dev/null \
    && download -sS -o "$TMP/SHA256SUMS.sig" "$1/SHA256SUMS.sig" 2> /dev/null \
    && download --progress-bar -o "$TMP/$FILE.dmg" "$1/$FILE.dmg"
}
FROM=""
for source in $SOURCES; do
  if fetch "${source%/}"; then FROM="${source%/}"; break; fi
  echo "Not available from ${source%/} – trying another address …"
done
[ -n "$FROM" ] || fail "could not download $APP – check the internet connection (tried: $SOURCES)."

bold "Checking the download …"
# /usr/bin/openssl (LibreSSL) is on every Mac
/usr/bin/openssl dgst -sha256 -verify "$TMP/clinicnest.pub" -signature "$TMP/SHA256SUMS.sig" "$TMP/SHA256SUMS" >/dev/null 2>&1 \
  || fail "the checksum file is not signed by ClinicNest. Nothing was installed – please tell support@clinicnest.app."
expected="$(awk -v f="$FILE.dmg" '{ name = $2; sub(/^\*/, "", name) } name == f { print $1 }' "$TMP/SHA256SUMS")"
actual="$(shasum -a 256 "$TMP/$FILE.dmg" | awk '{ print $1 }')"
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
    echo "Closing the running $APP …"
    osascript -e "quit app \"$APP\"" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do pgrep -f "$APP.app/Contents" >/dev/null 2>&1 || break; sleep 1; done
  fi
fi
mkdir -p "$DEST"
mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$TMP/$FILE.dmg" || fail "the disk image could not be opened."
[ -d "$MOUNT/$APP.app" ] || fail "$APP.app is missing in the disk image."
rm -rf "$DEST/$APP.app.new"
ditto "$MOUNT/$APP.app" "$DEST/$APP.app.new"
rm -rf "$DEST/$APP.app"
mv "$DEST/$APP.app.new" "$DEST/$APP.app"
hdiutil detach -quiet "$MOUNT" || true
echo "Installed: $DEST/$APP.app"

if [ -z "${CLINICNEST_NO_START:-}" ]; then
  bold "Starting $APP …"
  open "$DEST/$APP.app"
fi

if [ "$FILE" = ClinicNest-Server ]; then
  cat <<'NEXT'

Done. ClinicNest Server opens in the browser in a moment (first start: about 30 seconds; http://localhost:8081).
 • If the Mac asks "Allow ClinicNest Server to find devices on your local network?", click Allow –
   otherwise phones and other computers in the clinic cannot open it.
 • "Start with the computer…" in its window runs it in the background: it then starts with the Mac, also when
   nobody is signed in (asks for an administrator password once).
 • It updates itself; its data is in ~/Library/Application Support/Clinic Server, backups in
   ~/ClinicNest Server/backups. Remove it later with the Uninstall button in its window.
NEXT
  exit 0
fi
cat <<'NEXT'

Done. ClinicNest opens in the browser in a moment (first start: about 30 seconds).
 • If the Mac asks "Allow ClinicNest to find devices on your local network?", click Allow –
   otherwise phones and other computers in the clinic cannot open ClinicNest.
 • ClinicNest updates itself; run this command again only to repair an installation.
 • Remove it later with the Uninstall button in ClinicNest's status window.
NEXT
