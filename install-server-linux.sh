#!/usr/bin/env bash
# ClinicNest server edition on Linux without Docker – install or update (Debian / Ubuntu):
#
#   curl -fsSL https://updates.clinicnest.app/install-server-linux.sh | sudo bash
#
# What it does: installs PostgreSQL from the system's packages (the system keeps it updated) and creates the
# database; downloads the official ClinicNest-Server-linux.zip of the latest release and checks it against
# SHA256SUMS, whose signature is checked with ClinicNest's public key below (the same key the automatic updates are
# checked with); downloads Java (Temurin 25, checked against Adoptium's checksum) because Linux versions ship
# different ones; sets ClinicNest up as the systemd service "clinicnest-server" (starts with the computer, runs as
# its own user) and prints the address and the one-time setup code. Running it again updates ClinicNest and Java;
# the database, its password and the settings are kept. Anything changed or incomplete is refused.
#
# Folders: /opt/clinicnest-server (program), /var/lib/clinicnest-server (data, backups in backups/),
#          /etc/clinicnest-server.env (database password, setup code – private).
# Settings (environment): CLINICNEST_HTTP_PORT (8081), TZ (asked; default the server's), CLINICNEST_YES=1 (no
# questions). Testing: CLINICNEST_DOWNLOAD=<base URL>, CLINICNEST_NO_SYSTEMD=1 (start without systemd),
# CLINICNEST_JRE_TAR=<local Java .tar.gz>.
# On the internet with https: use the Docker install (install-server.sh) – it brings a web server with certificates.
set -euo pipefail

BASE="${CLINICNEST_DOWNLOAD:-https://github.com/clinicnest-app/clinic-nest-updates/releases/latest/download}"
BASE="${BASE%/}"
ZIP=ClinicNest-Server-linux.zip
DIR=/opt/clinicnest-server
DATA=/var/lib/clinicnest-server
ENVF=/etc/clinicnest-server.env
UNIT=/etc/systemd/system/clinicnest-server.service
SVC_USER=clinicnest
YES="${CLINICNEST_YES:-}"

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mNot installed:\033[0m %s\n' "$*" >&2; exit 1; }
ask() {
  local q="$1" d="${2:-}"
  if [ -n "$YES" ] || [ ! -r /dev/tty ]; then REPLY="$d"; return; fi
  printf '%s ' "$q" > /dev/tty
  IFS= read -r REPLY < /dev/tty || REPLY=""
  [ -n "$REPLY" ] || REPLY="$d"
}
random() { LC_ALL=C tr -dc 'A-HJ-NP-Z2-9' < /dev/urandom | head -c "$1" || true; }

[ "$(uname -s)" = Linux ] || fail "this script is for Linux. Windows / Mac: the ClinicNest Server installer on the download page."
[ "$(id -u)" -eq 0 ] || fail "run it as administrator:  curl -fsSL https://updates.clinicnest.app/install-server-linux.sh | sudo bash"
command -v apt-get > /dev/null || fail "this script needs Debian or Ubuntu (apt). Other Linux: use the Docker install (install-server.sh)."
case "$(uname -m)" in
  x86_64|amd64) ARCH=x64 ;;
  aarch64|arm64) ARCH=aarch64 ;;
  *) fail "unsupported processor $(uname -m)." ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------------------------- packages
bold "Installing PostgreSQL and tools from the system's packages …"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq postgresql postgresql-client curl unzip openssl ca-certificates > /dev/null \
  || fail "the packages could not be installed (apt-get)."
if [ -z "${CLINICNEST_NO_SYSTEMD:-}" ]; then
  systemctl enable --now postgresql > /dev/null 2>&1 || true
else
  service postgresql start > /dev/null 2>&1 || true
fi
for _ in $(seq 1 30); do pg_isready -q -h 127.0.0.1 && break; sleep 1; done
pg_isready -q -h 127.0.0.1 || fail "PostgreSQL does not run (systemctl status postgresql)."

# ---------------------------------------------------------------------------------------------- download + check
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
download() { curl -fL --retry 3 --connect-timeout 20 "$@"; }
bold "Downloading ClinicNest Server …"
download -sS -o "$TMP/SHA256SUMS" "$BASE/SHA256SUMS" || fail "could not download from $BASE – check the internet connection."
download -sS -o "$TMP/SHA256SUMS.sig" "$BASE/SHA256SUMS.sig" || fail "the signature file is missing. Try again in a few minutes."
download --progress-bar -o "$TMP/$ZIP" "$BASE/$ZIP" || fail "the download of $ZIP failed. Try again."
openssl dgst -sha256 -verify "$TMP/clinicnest.pub" -signature "$TMP/SHA256SUMS.sig" "$TMP/SHA256SUMS" > /dev/null 2>&1 \
  || fail "the checksum file is not signed by ClinicNest. Nothing was installed – please tell support@clinicnest.app."
expected="$(awk -v f="$ZIP" '{ name = $2; sub(/^\*/, "", name) } name == f { print $1 }' "$TMP/SHA256SUMS")"
actual="$(sha256sum "$TMP/$ZIP" | awk '{ print $1 }')"
[ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "the download is damaged or was changed on the way. Nothing was installed."
echo "Signature and checksum OK."

bold "Downloading Java (Temurin 25) …"
if [ -n "${CLINICNEST_JRE_TAR:-}" ]; then
  cp "$CLINICNEST_JRE_TAR" "$TMP/jre.tar.gz"   # testing: a local Java archive
else
  # Adoptium's API names the newest build, its address and its checksum
  download -sS -o "$TMP/jre.json" \
    "https://api.adoptium.net/v3/assets/latest/25/hotspot?architecture=$ARCH&image_type=jre&os=linux&vendor=eclipse" \
    || fail "Java could not be found (api.adoptium.net)."
  JRE_LINK="$(grep -o '"link": *"[^"]*\.tar\.gz"' "$TMP/jre.json" | head -n 1 | sed 's/.*"\(http[^"]*\)"/\1/')"
  JRE_SUM="$(grep -o '"checksum": *"[0-9a-f]\{64\}"' "$TMP/jre.json" | head -n 1 | grep -o '[0-9a-f]\{64\}')"
  [ -n "$JRE_LINK" ] && [ -n "$JRE_SUM" ] || fail "Java could not be found (api.adoptium.net)."
  download --progress-bar -o "$TMP/jre.tar.gz" "$JRE_LINK" || fail "Java could not be downloaded."
  [ "$JRE_SUM" = "$(sha256sum "$TMP/jre.tar.gz" | awk '{print $1}')" ] \
    || fail "the Java download is damaged. Nothing was installed – try again."
fi

# ---------------------------------------------------------------------------------------------- user, database, settings
id -u "$SVC_USER" > /dev/null 2>&1 || useradd --system --home-dir "$DATA" --shell /usr/sbin/nologin "$SVC_USER"
mkdir -p "$DATA/backups"
chown -R "$SVC_USER:$SVC_USER" "$DATA"
chmod 750 "$DATA"

NEW=""
if [ ! -f "$ENVF" ]; then
  NEW=1
  TZ_GUESS="$(timedatectl show -p Timezone --value 2> /dev/null || cat /etc/timezone 2> /dev/null || true)"
  [ -n "$TZ_GUESS" ] && [ "$TZ_GUESS" != UTC ] && [ "$TZ_GUESS" != Etc/UTC ] || TZ_GUESS="Asia/Kolkata"
  ask "Time zone of the clinic [$TZ_GUESS]:" "${TZ:-$TZ_GUESS}"
  ( umask 077 && touch "$ENVF" )
  cat > "$ENVF" <<EOF
# ClinicNest Server settings – created by install-server-linux.sh on $(date +%F). Keep this file private.
# After a change: systemctl restart clinicnest-server
CLINICNEST_DB_URL=jdbc:postgresql://127.0.0.1:5432/clinicnest
CLINICNEST_DB_USER=clinicnest
CLINICNEST_DB_PASSWORD=$(random 32)
# needed once, for the first-run setup in the browser
CLINICNEST_SETUP_CODE=$(random 4)-$(random 4)-$(random 4)-$(random 4)
CLINICNEST_HTTP_PORT=${CLINICNEST_HTTP_PORT:-8081}
TZ=$REPLY
EOF
  chmod 600 "$ENVF"
fi
get() { sed -n "s/^$1=//p" "$ENVF" | tail -n 1; }
PASSWORD="$(get CLINICNEST_DB_PASSWORD)"
PORT="$(get CLINICNEST_HTTP_PORT)"; PORT="${PORT:-8081}"

# the database and its owner (the password from the settings file – also set again, in case it was changed there)
cd /tmp
if ! su postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname = 'clinicnest'\"" | grep -q 1; then
  su postgres -c "psql -q -c \"CREATE ROLE clinicnest LOGIN\""
fi
su postgres -c "psql -q" <<SQL
ALTER ROLE clinicnest PASSWORD '$PASSWORD';
SQL
if ! su postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname = 'clinicnest'\"" | grep -q 1; then
  su postgres -c "psql -q -c \"CREATE DATABASE clinicnest OWNER clinicnest\""
fi

# ---------------------------------------------------------------------------------------------- program
bold "Installing …"
if [ -z "${CLINICNEST_NO_SYSTEMD:-}" ] && systemctl is-active --quiet clinicnest-server; then
  systemctl stop clinicnest-server   # its closing backup runs now
fi
mkdir -p "$DIR"
rm -rf "$DIR/app.new" "$DIR/runtime.new"
mkdir -p "$DIR/app.new" "$DIR/runtime.new"
unzip -q "$TMP/$ZIP" -d "$DIR/app.new"
tar -xzf "$TMP/jre.tar.gz" -C "$DIR/runtime.new" --strip-components=1
[ -f "$DIR/app.new/quarkus-run.jar" ] || fail "the zip does not contain ClinicNest."
rm -rf "$DIR/app" "$DIR/runtime"
mv "$DIR/app.new" "$DIR/app"
mv "$DIR/runtime.new" "$DIR/runtime"
chown -R root:root "$DIR"
chmod -R u=rwX,go=rX "$DIR"   # readable and runnable by the service user, changeable by root only

# no proxy in front: X-Forwarded-* would come from anybody on the network – not believed
JAVA_OPTS="-Dquarkus.http.port=$PORT -Dclinic.data-dir=$DATA -Dclinic.backup.dir=$DATA/backups \
-Dclinic.devices.trust-localhost=false -Dquarkus.http.proxy.proxy-address-forwarding=false \
-Dquarkus.http.proxy.allow-x-forwarded=false -Dquarkus.http.proxy.enable-forwarded-host=false"
if [ -z "${CLINICNEST_NO_SYSTEMD:-}" ]; then
  cat > "$UNIT" <<EOF
[Unit]
Description=ClinicNest Server
After=network-online.target postgresql.service
Wants=network-online.target postgresql.service

[Service]
User=$SVC_USER
EnvironmentFile=$ENVF
WorkingDirectory=$DATA
ExecStart=$DIR/runtime/bin/java $JAVA_OPTS -jar $DIR/app/quarkus-run.jar
Restart=on-failure
RestartSec=10
# time for the backup ClinicNest makes when it stops
TimeoutStopSec=150
NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=$DATA

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable clinicnest-server > /dev/null 2>&1
  systemctl restart clinicnest-server
else
  # testing without systemd: run it in the background as the service user (runuser keeps the settings)
  ( set -a; . "$ENVF"; set +a; cd "$DATA"
    nohup runuser -u "$SVC_USER" -- "$DIR/runtime/bin/java" $JAVA_OPTS -jar "$DIR/app/quarkus-run.jar" > "$DATA/server.log" 2>&1 & )
fi

code=000
for _ in $(seq 1 90); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" || true)"
  [ "$code" != 000 ] && break
  sleep 2
done
[ "$code" != 000 ] || fail "ClinicNest did not start. See: journalctl -u clinicnest-server"

# ---------------------------------------------------------------------------------------------- done
bold "ClinicNest Server is running."
for ip in $(ip -4 -o addr show scope global 2> /dev/null | grep -vE ' (docker[0-9]*|br-[0-9a-f]+|veth[^ ]*) ' | awk '{split($4, a, "/"); print a[1]}'); do
  echo "Open on a computer in the clinic:  http://$ip:$PORT"
done
if command -v ufw > /dev/null && ufw status 2> /dev/null | grep -q "Status: active"; then
  ufw allow "$PORT/tcp" > /dev/null && echo "Firewall (ufw): port $PORT opened."
fi
if [ -n "$NEW" ]; then
  echo
  echo "Setup code (asked once, at the first-run setup):  $(get CLINICNEST_SETUP_CODE)"
fi
first_ip="$(ip -4 -o addr show scope global 2> /dev/null | grep -vE ' (docker[0-9]*|br-[0-9a-f]+|veth[^ ]*) ' | awk '{split($4, a, "/"); print a[1]}' | head -n 1)"
[ -n "$first_ip" ] || first_ip="<address of this server>"
# what is where, how to update / stop / uninstall: README.txt (written on every run), shown now
cat > "$DIR/README.txt" <<EOF
ClinicNest Server (Linux service) – $(date +%F)
Open: http://$first_ip:$PORT

WHAT IS WHERE
  $DIR/                    the program (app/), its Java (runtime/), this file
  $DATA/              ClinicNest's own files
  $DATA/backups/      ClinicNest's backups – copy them to another place regularly
                                       (Settings → Backup: set a backup password, so the copies are encrypted)
  $ENVF           database password, setup code, port, time zone – private
  $UNIT   the service "clinicnest-server"
  PostgreSQL (the system's package)    database "clinicnest", owner "clinicnest"

EVERYDAY
  Update to the newest ClinicNest:  curl -fsSL https://updates.clinicnest.app/install-server-linux.sh | sudo bash
  See what it is doing:             sudo journalctl -u clinicnest-server -f
  Stop / start / restart:           sudo systemctl stop|start|restart clinicnest-server
  It starts with the computer by itself.

UNINSTALL
  1. Stop and remove the service (the data is kept – a new install continues with it):
       sudo systemctl disable --now clinicnest-server && sudo rm $UNIT && sudo systemctl daemon-reload
  2. Remove the program:
       sudo rm -rf $DIR
  3. Also delete the database – cannot be undone; copy $DATA/backups somewhere first if you want the data:
       sudo -u postgres psql -c "DROP DATABASE clinicnest" -c "DROP ROLE clinicnest"
  4. Delete the data, backups and settings, and the service's user:
       sudo rm -rf $DATA $ENVF && sudo userdel clinicnest
  PostgreSQL itself stays installed (sudo apt remove postgresql, if nothing else uses it).

Help: support@clinicnest.app · https://updates.clinicnest.app/#server
EOF
chmod 644 "$DIR/README.txt"
echo
echo "------------------------------------------------------------------------------------------------------------"
cat "$DIR/README.txt"
echo "------------------------------------------------------------------------------------------------------------"
echo "This is also in $DIR/README.txt"
