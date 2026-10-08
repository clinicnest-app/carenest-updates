#!/usr/bin/env bash
# ClinicNest server edition – install or update with Docker:
#
#   Linux:  curl -fsSL https://updates.clinicnest.app/install-server.sh | sudo bash
#   Mac:    curl -fsSL https://updates.clinicnest.app/install-server.sh | bash     (with Docker Desktop)
#   (Windows: install-server.ps1)
#
# Sets up ClinicNest + PostgreSQL + Caddy (web server: https or plain http) in /opt/clinicnest (Mac:
# ~/ClinicNest-Server), creates the passwords and a one-time setup code, starts everything and prints the address.
# Run it again to update: the passwords and settings in .env are kept, the newest ClinicNest is started.
#
# Settings (environment, all optional):
#   CLINICNEST_SITE      internet name for https, e.g. clinic.example.com ("none" = clinic network only);
#                        asked when not given and not in .env yet
#   CLINICNEST_DIR       install folder (default /opt/clinicnest; Mac ~/ClinicNest-Server)
#   CLINICNEST_YES=1     no questions (installs Docker if needed, clinic network only unless CLINICNEST_SITE)
#   CLINICNEST_VERSION   image tag to run (default: latest)
#   CLINICNEST_HTTP_PORT port for the clinic network (default 80; 8080 when 80 is taken), CLINICNEST_HTTPS_PORT (443)
#   CLINICNEST_BASE      where docker-compose.yml and Caddyfile are downloaded from (default the ClinicNest site)
set -euo pipefail

BASE="${CLINICNEST_BASE:-https://updates.clinicnest.app}"
BASE="${BASE%/}"
OS="$(uname -s)"
if [ "$OS" = Darwin ]; then DIR="${CLINICNEST_DIR:-$HOME/ClinicNest-Server}"; else DIR="${CLINICNEST_DIR:-/opt/clinicnest}"; fi
YES="${CLINICNEST_YES:-}"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mNot installed:\033[0m %s\n' "$*" >&2; exit 1; }
# questions work also with "curl … | bash" (stdin is the script then): read from the terminal
ask() { # ask "question" default → REPLY
  local q="$1" d="${2:-}"
  if [ -n "$YES" ] || [ ! -r /dev/tty ]; then REPLY="$d"; return; fi
  printf '%s ' "$q" > /dev/tty
  IFS= read -r REPLY < /dev/tty || REPLY=""
  [ -n "$REPLY" ] || REPLY="$d"
}
random() { # random letters/digits, length $1
  LC_ALL=C tr -dc 'A-HJ-NP-Z2-9' < /dev/urandom | head -c "$1" || true
}

# ---------------------------------------------------------------------------------------------- checks
case "$OS" in
  Linux)
    [ "$(id -u)" -eq 0 ] || fail "run it as administrator:  curl -fsSL $BASE/install-server.sh | sudo bash" ;;
  Darwin)
    [ "$(id -u)" -ne 0 ] || fail "on a Mac, run it without sudo:  curl -fsSL $BASE/install-server.sh | bash" ;;
  *) fail "this script is for Linux and Mac. On Windows: irm $BASE/install-server.ps1 | iex" ;;
esac
command -v curl > /dev/null || fail "curl is missing (e.g. sudo apt install curl)."

# ---------------------------------------------------------------------------------------------- Docker
if [ "$OS" = Darwin ]; then
  # Docker Desktop: its command line is in the app; the app must be running
  [ -x /Applications/Docker.app/Contents/Resources/bin/docker ] && export PATH="$PATH:/Applications/Docker.app/Contents/Resources/bin"
  command -v docker > /dev/null || fail "Docker Desktop is not installed. Get it from https://www.docker.com/products/docker-desktop/
  (Mac with Apple chip), open it once and accept its terms, then run this again."
  if ! docker info > /dev/null 2>&1; then
    say "Starting Docker Desktop …"
    open -a Docker || true
    for _ in $(seq 1 60); do docker info > /dev/null 2>&1 && break; sleep 2; done
  fi
  docker info > /dev/null 2>&1 || fail "Docker Desktop is not running. Open it (and accept its terms the first time), then run this again."
fi
if ! command -v docker > /dev/null; then
  say "Docker is not installed."
  echo "It can be installed now with Docker's official script (get.docker.com)."
  ask "Install Docker now? [Y/n]" "y"
  case "$REPLY" in [nN]*) fail "Docker is needed. Install it (https://docs.docker.com/engine/install/) and run this again." ;; esac
  curl -fsSL https://get.docker.com | sh || fail "Docker could not be installed."
  systemctl enable --now docker > /dev/null 2>&1 || true
fi
docker info > /dev/null 2>&1 || fail "Docker is installed but not running (sudo systemctl start docker)."
if ! docker compose version > /dev/null 2>&1; then
  if command -v apt-get > /dev/null; then
    say "Installing Docker Compose …"
    apt-get update -qq && apt-get install -y -qq docker-compose-plugin > /dev/null || true
  fi
  docker compose version > /dev/null 2>&1 || fail "Docker Compose is missing (package docker-compose-plugin)."
fi

# ---------------------------------------------------------------------------------------------- files
mkdir -p "$DIR"
cd "$DIR"
say "ClinicNest folder: $DIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for f in docker-compose.yml Caddyfile; do
  curl -fsSL "$BASE/docker/$f" -o "$tmp/$f" || fail "could not download $BASE/docker/$f – check the internet connection."
  grep -q . "$tmp/$f" || fail "$f is empty – try again later."
done
mv "$tmp/docker-compose.yml" "$tmp/Caddyfile" "$DIR/"

# ---------------------------------------------------------------------------------------------- settings (.env)
NEW=""
if [ ! -f .env ]; then
  NEW=1
  umask 077
  TZ_GUESS="$(timedatectl show -p Timezone --value 2> /dev/null || cat /etc/timezone 2> /dev/null || true)"
  [ -n "$TZ_GUESS" ] && [ "$TZ_GUESS" != UTC ] && [ "$TZ_GUESS" != Etc/UTC ] || TZ_GUESS="Asia/Kolkata"

  SITE="${CLINICNEST_SITE:-}"
  if [ -z "$SITE" ]; then
    say "How will ClinicNest be opened?"
    echo "  - Only in the clinic (same network as this server): just press Enter."
    echo "  - From the internet too: enter the server's name, e.g. clinic.example.com. The name must already point"
    echo "    to this server and ports 80 and 443 must be open; a free https certificate is then set up."
    ask "Internet name (or Enter for clinic network only):" "none"
    SITE="$REPLY"
  fi
  SITE="$(printf '%s' "$SITE" | tr -d '[:space:]' | sed -e 's#^https\?://##' -e 's#/.*$##')"
  if [ -z "$SITE" ] || [ "$SITE" = none ]; then SITE=":80"; SECURE=false; else SECURE=true; fi

  HTTP_PORT="${CLINICNEST_HTTP_PORT:-80}"
  if [ "$SITE" = ":80" ] && [ "$HTTP_PORT" = 80 ] && command -v ss > /dev/null && ss -ltnH 2> /dev/null | awk '{print $4}' | grep -qE '[:.]80$'; then
    HTTP_PORT=8080
    echo "Port 80 is used by another program on this server: ClinicNest uses port $HTTP_PORT."
  fi
  ask "Time zone of the clinic [$TZ_GUESS]:" "$TZ_GUESS"
  CLINIC_TZ="$REPLY"

  cat > .env <<EOF
# ClinicNest server settings – created by install-server.sh on $(date +%F). Keep this file private.
# After a change: docker compose up -d
CLINICNEST_DB_PASSWORD=$(random 32)
# needed once, for the first-run setup in the browser
CLINICNEST_SETUP_CODE=$(random 4)-$(random 4)-$(random 4)-$(random 4)
# ":80" = clinic network, plain http; a name = https from the internet
CLINICNEST_SITE=$SITE
CLINICNEST_SECURE_COOKIE=$SECURE
CLINICNEST_HTTP_PORT=$HTTP_PORT
CLINICNEST_HTTPS_PORT=${CLINICNEST_HTTPS_PORT:-443}
TZ=$CLINIC_TZ
CLINICNEST_VERSION=${CLINICNEST_VERSION:-latest}
# this folder (named on the screens, e.g. where to copy a backup from ClinicNest for Windows / Mac)
CLINICNEST_DIR=$DIR
EOF
  chmod 600 .env
else
  say "Updating (settings in $DIR/.env are kept)."
  grep -q '^CLINICNEST_DIR=' .env || printf 'CLINICNEST_DIR=%s\n' "$DIR" >> .env
  if [ -n "${CLINICNEST_VERSION:-}" ]; then
    sed -i.bak "s/^CLINICNEST_VERSION=.*/CLINICNEST_VERSION=$CLINICNEST_VERSION/" .env && rm -f .env.bak
  fi
fi
get() { sed -n "s/^$1=//p" .env | tail -n 1; }

mkdir -p data backups
# ClinicNest runs as user 10001 in its container (Linux; Docker Desktop shares folders without owners)
[ "$OS" = Linux ] && { chown 10001:10001 data backups 2> /dev/null || true; }

# ---------------------------------------------------------------------------------------------- start
say "Downloading ClinicNest …"
if ! docker compose pull --quiet --ignore-pull-failures; then
  echo "Could not download the newest version – starting the version already on this server (if there is one)."
fi
say "Starting …"
docker compose up -d --remove-orphans || fail "could not start (docker compose logs shows why)."

PORT="$(get CLINICNEST_HTTP_PORT)"; PORT="${PORT:-80}"
code=000
for _ in $(seq 1 90); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" || true)"
  case "$code" in 000|502|503) sleep 2 ;; *) break ;; esac
done
case "$code" in 000|502|503)
  fail "ClinicNest did not answer. See: cd $DIR && docker compose logs app" ;;
esac

# ---------------------------------------------------------------------------------------------- done
SITE="$(get CLINICNEST_SITE)"
say "ClinicNest is running."
if [ "$SITE" != ":80" ]; then
  echo "Open:  https://$SITE"
else
  suffix=""; [ "$PORT" = 80 ] || suffix=":$PORT"
  # the server's network addresses – not Docker's own networks
  if command -v ip > /dev/null; then
    ips="$(ip -4 -o addr show scope global | grep -vE ' (docker[0-9]*|br-[0-9a-f]+|veth[^ ]*) ' | awk '{split($4, a, "/"); print a[1]}')"
  else
    ips="$(ipconfig getifaddr en0 2> /dev/null || true)"
  fi
  for ip in $ips; do
    echo "Open on a computer in the clinic:  http://$ip$suffix"
  done
  [ -n "$ips" ] || echo "Open on a computer in the clinic:  http://<this server's address>$suffix"
fi
if [ -n "$NEW" ]; then
  echo
  echo "Setup code (asked once, at the first-run setup):  $(get CLINICNEST_SETUP_CODE)"
fi
cat <<EOF

Backups: ClinicNest makes them itself, into $DIR/backups – copy that folder to another place regularly
(set a backup password in Settings → Backup so the copies are encrypted).
Update later: run this command again.   Log: cd $DIR && docker compose logs -f app
EOF
if [ "$OS" = Darwin ]; then
  cat <<EOF
Mac: ClinicNest runs while Docker Desktop runs. Docker Desktop → Settings → General → "Start Docker Desktop when
you sign in" keeps it running after a restart; keep the Mac from sleeping (System Settings → Energy).
EOF
fi
