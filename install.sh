#!/usr/bin/env bash
#
# install.sh — installer for mysql-telegram-backup
# repo: https://github.com/rgoogoonani/mysql-Baclup
#
#   sudo bash install.sh              install / reconfigure
#   sudo bash install.sh --uninstall  remove everything
#   sudo bash install.sh --update     only replace the script with the latest one

set -Eeuo pipefail

REPO_RAW="https://raw.githubusercontent.com/rgoogoonani/mysql-Baclup"
SCRIPT_NAME="mysql-telegram-backup.sh"
BIN_PATH="/usr/local/bin/${SCRIPT_NAME}"
CONF_PATH="/etc/mysql-tg-backup.conf"
SERVICE_NAME="mysql-tg-backup"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
DEFAULT_BACKUP_DIR="/var/backups/mysql-tg"

PROXY="${PROXY:-}"
CURL_PROXY=()

GREEN=$'\e[32m'; RED=$'\e[31m'; YEL=$'\e[33m'; BLU=$'\e[34m'; NC=$'\e[0m'
ok()   { echo "${GREEN}[ OK ]${NC} $*"; }
info() { echo "${BLU}[ .. ]${NC} $*"; }
warn() { echo "${YEL}[WARN]${NC} $*"; }
die()  { echo "${RED}[FAIL]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "this installer must run as root:  sudo bash install.sh"

# ------------------------------------------------------------------ actions --
ACTION="install"
case "${1:-}" in
  --uninstall|-u) ACTION="uninstall" ;;
  --update)       ACTION="update" ;;
  --help|-h)      sed -n '2,10p' "$0"; exit 0 ;;
  "")             ;;
  *)              die "unknown option: $1" ;;
esac

fetch_script() {
  local here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${here}/${SCRIPT_NAME}" ]]; then
    info "using local ${SCRIPT_NAME}"
    install -m 750 "${here}/${SCRIPT_NAME}" "$BIN_PATH"
  else
    local branch
    for branch in main master; do
      info "downloading the script from branch ${branch} ..."
      if curl -fsSL --max-time 60 "${CURL_PROXY[@]}" "${REPO_RAW}/${branch}/${SCRIPT_NAME}" -o /tmp/${SCRIPT_NAME}.dl; then
        install -m 750 /tmp/${SCRIPT_NAME}.dl "$BIN_PATH"
        rm -f /tmp/${SCRIPT_NAME}.dl
        break
      fi
    done
  fi
  [[ -x "$BIN_PATH" ]] || die "could not get the script. check the server's connection or the repo URL."
  bash -n "$BIN_PATH" || die "the downloaded file is not a valid script"
  ok "script installed at ${BIN_PATH}"
}

# ---------------------------------------------------------------- uninstall --
if [[ "$ACTION" == "uninstall" ]]; then
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_PATH"; systemctl daemon-reload 2>/dev/null || true
  rm -f "$BIN_PATH"
  ok "service and script removed"
  if [[ -f "$CONF_PATH" ]]; then
    # shellcheck disable=SC1090
    ( source "$CONF_PATH" >/dev/null 2>&1; echo "${DB_USER:-}" ) >/tmp/.duser
    DUSER="$(cat /tmp/.duser)"; rm -f /tmp/.duser
    if [[ -n "$DUSER" && "$DUSER" != "root" ]]; then
      read -rp "also drop the MySQL user '${DUSER}'? [y/N]: " a
      if [[ "${a,,}" == "y" ]]; then
        SQLBIN="$(command -v mysql || command -v mariadb || true)"
        if [[ -n "$SQLBIN" ]] && "$SQLBIN" --protocol=socket -e \
             "DROP USER IF EXISTS '${DUSER}'@'localhost'; DROP USER IF EXISTS '${DUSER}'@'127.0.0.1';" 2>/dev/null; then
          ok "user ${DUSER} dropped"
        else
          warn "could not drop the user, run it manually: DROP USER '${DUSER}'@'localhost';"
        fi
      fi
    fi
    read -rp "also delete the config ${CONF_PATH}? [y/N]: " a
    [[ "${a,,}" == "y" ]] && rm -f "$CONF_PATH" && ok "config deleted"
  fi
  if [[ -d "$DEFAULT_BACKUP_DIR" ]]; then
    read -rp "also delete local backups in ${DEFAULT_BACKUP_DIR}? [y/N]: " a
    [[ "${a,,}" == "y" ]] && rm -rf "$DEFAULT_BACKUP_DIR" && ok "backup directory deleted"
  fi
  exit 0
fi

# ------------------------------------------------------------------- update --
if [[ "$ACTION" == "update" ]]; then
  if [[ -f "$CONF_PATH" ]]; then
    # shellcheck disable=SC1090
    PROXY="$(source "$CONF_PATH" >/dev/null 2>&1; echo "${PROXY:-}")"
    [[ -n "$PROXY" ]] && CURL_PROXY=(--proxy "$PROXY") && info "using the proxy from the config"
  fi
  fetch_script
  systemctl restart "$SERVICE_NAME" 2>/dev/null && ok "service restarted" || true
  exit 0
fi

# ------------------------------------------------------------------ install --
echo
echo "==================================================="
echo "   MySQL Telegram Backup — installer"
echo "==================================================="
echo

# ---------------------------------------------------------------- 0) proxy ---
# Telegram (and sometimes GitHub) is blocked in Iran, so everything this
# installer downloads or sends can go through a proxy.
ask_proxy() {
  echo "--- Proxy ---"
  echo "If this server cannot reach api.telegram.org directly, set a proxy"
  echo "here (for example a local Xray/V2Ray client running on this server)."
  echo "  1) No proxy"
  echo "  2) HTTP"
  echo "  3) SOCKS5"
  read -rp "Choice [1]: " pchoice; pchoice="${pchoice:-1}"
  case "$pchoice" in
    2) PSCHEME="http" ;;
    3) PSCHEME="socks5h" ;;   # h = let the proxy resolve DNS
    *) PROXY=""; CURL_PROXY=(); return 0 ;;
  esac
  local dh="127.0.0.1" dp
  [[ "$PSCHEME" == "http" ]] && dp=8118 || dp=10808
  read -rp "  Proxy host/IP [${dh}]: " PHOST; PHOST="${PHOST:-$dh}"
  read -rp "  Port [${dp}]: " PPORT; PPORT="${PPORT:-$dp}"
  read -rp "  Username (leave empty if none): " PUSER
  if [[ -n "$PUSER" ]]; then
    read -rsp "  Password: " PPASS; echo
    PROXY="${PSCHEME}://${PUSER}:${PPASS}@${PHOST}:${PPORT}"
  else
    PROXY="${PSCHEME}://${PHOST}:${PPORT}"
  fi
  CURL_PROXY=(--proxy "$PROXY")
  info "testing the proxy ..."
  if curl -sS --max-time 20 "${CURL_PROXY[@]}" -o /dev/null https://api.telegram.org; then
    ok "proxy works, api.telegram.org is reachable"
  else
    warn "Telegram was not reachable through this proxy. You can continue and"
    warn "fix the PROXY value in ${CONF_PATH} later."
    read -rp "Continue anyway? [Y/n]: " a
    [[ "${a,,}" == "n" ]] && exit 1
  fi
  echo
}

ask_proxy

# 1) dependencies
info "checking dependencies ..."
export DEBIAN_FRONTEND=noninteractive
MISSING=()
command -v curl >/dev/null || MISSING+=(curl)
command -v zip  >/dev/null || MISSING+=(zip)
command -v split >/dev/null || MISSING+=(coreutils)
command -v flock >/dev/null || MISSING+=(util-linux)
if ! command -v mysqldump >/dev/null && ! command -v mariadb-dump >/dev/null; then
  if command -v mariadb >/dev/null; then MISSING+=(mariadb-client); else MISSING+=(mysql-client); fi
fi
if [[ ${#MISSING[@]} -gt 0 ]]; then
  apt-get update -qq
  apt-get install -y -qq "${MISSING[@]}" || die "could not install dependencies: ${MISSING[*]}"
fi

# 7-Zip: needed for WinRAR-style multi volume archives
HAVE_7Z=""
for b in 7zz 7z 7za 7zr; do command -v "$b" >/dev/null && { HAVE_7Z="$b"; break; }; done
if [[ -z "$HAVE_7Z" ]]; then
  info "installing 7zip for multi-volume archives ..."
  apt-get update -qq
  apt-get install -y -qq 7zip 2>/dev/null || apt-get install -y -qq p7zip-full 2>/dev/null || true
  for b in 7zz 7z 7za 7zr; do command -v "$b" >/dev/null && { HAVE_7Z="$b"; break; }; done
fi
if [[ -n "$HAVE_7Z" ]]; then
  ok "dependencies ready (7z binary: ${HAVE_7Z})"
else
  warn "7zip not installed; falling back to zip format (multi-part zip needs manual rejoining)"
fi

# 2) the script itself
fetch_script

# 3) configuration
if [[ -f "$CONF_PATH" ]]; then
  echo
  read -rp "A config already exists. Overwrite it? [y/N]: " a
  [[ "${a,,}" == "y" ]] || { info "keeping the existing config"; SKIP_CONF=1; }
  if [[ -n "${SKIP_CONF:-}" && -n "$PROXY" ]] && ! grep -q '^PROXY=' "$CONF_PATH"; then
    printf '\nPROXY="%s"\n' "$PROXY" >>"$CONF_PATH"
    ok "PROXY line added to the existing config"
  fi
fi

if [[ -z "${SKIP_CONF:-}" ]]; then
  echo
  echo "--- Telegram ---"
  while [[ -z "${BOT_TOKEN:-}" ]]; do read -rp "Bot token: " BOT_TOKEN; done
  while [[ -z "${CHAT_ID:-}"   ]]; do read -rp "Destination chat id (a number, channels start with -100): " CHAT_ID; done

  echo
  echo "--- Database ---"
  read -rp "Host [127.0.0.1]: " DB_HOST; DB_HOST="${DB_HOST:-127.0.0.1}"
  read -rp "Port [3306]: " DB_PORT; DB_PORT="${DB_PORT:-3306}"

  SQLBIN="$(command -v mysql || command -v mariadb || true)"
  BACKUP_USER_CREATED=0

  echo
  echo "Create a dedicated backup user with a random password?"
  echo "(recommended, so the root password does not end up in the config file)"
  read -rp "[Y/n]: " a
  if [[ "${a,,}" != "n" && -n "$SQLBIN" ]]; then
    # --- find a way to talk to the server as an admin ---
    ADMIN_CNF=""
    if "$SQLBIN" --protocol=socket -e "SELECT 1" >/dev/null 2>&1; then
      info "connected as admin over the local socket"
      ADMIN_ARGS=(--protocol=socket)
    else
      echo "Admin credentials are needed once to create the user (they are not stored):"
      read -rp "  Admin user [root]: " ADM_USER; ADM_USER="${ADM_USER:-root}"
      read -rsp "  Admin password: " ADM_PASS; echo
      ADMIN_CNF="$(mktemp)"; chmod 600 "$ADMIN_CNF"
      printf '[client]\nuser=%s\npassword=%s\nhost=%s\nport=%s\n' \
        "$ADM_USER" "$ADM_PASS" "$DB_HOST" "$DB_PORT" >"$ADMIN_CNF"
      ADMIN_ARGS=(--defaults-extra-file="$ADMIN_CNF")
    fi

    if "$SQLBIN" "${ADMIN_ARGS[@]}" -e "SELECT 1" >/dev/null 2>&1; then
      # 28 chars, letters+digits only so no SQL/shell quoting surprises
      GEN_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 28)"
      read -rp "User name [backup]: " BK_USER; BK_USER="${BK_USER:-backup}"
      GRANTS="SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER, RELOAD, PROCESS, REPLICATION CLIENT"
      # both hosts: 'localhost' matches socket connections, '127.0.0.1' matches TCP
      SQL=""
      for h in localhost 127.0.0.1; do
        SQL+="CREATE USER IF NOT EXISTS '${BK_USER}'@'${h}' IDENTIFIED BY '${GEN_PASS}';"
        SQL+="ALTER USER '${BK_USER}'@'${h}' IDENTIFIED BY '${GEN_PASS}';"
        SQL+="GRANT ${GRANTS} ON *.* TO '${BK_USER}'@'${h}';"
      done
      SQL+="FLUSH PRIVILEGES;"
      if "$SQLBIN" "${ADMIN_ARGS[@]}" -e "$SQL" 2>/tmp/.mkuser.err; then
        DB_USER="$BK_USER"; DB_PASS="$GEN_PASS"; BACKUP_USER_CREATED=1
        ok "user '${BK_USER}' created with a random password"
        echo "     password: ${YEL}${GEN_PASS}${NC}"
        echo "     (saved in ${CONF_PATH}, no need to memorise it)"
      else
        warn "could not create the user: $(tail -c 300 /tmp/.mkuser.err)"
      fi
      rm -f /tmp/.mkuser.err
    else
      warn "could not connect with those admin credentials"
    fi
    [[ -n "$ADMIN_CNF" ]] && rm -f "$ADMIN_CNF"
  fi

  if [[ "$BACKUP_USER_CREATED" -eq 0 ]]; then
    echo
    warn "no backup user was created, enter the credentials manually:"
    read -rp "MySQL user [root]: " DB_USER; DB_USER="${DB_USER:-root}"
    read -rsp "MySQL password: " DB_PASS; echo
  fi

  while [[ -z "${DATABASES:-}" ]]; do
    read -rp "Database names, comma separated (or 'all'): " DATABASES
  done

  echo
  echo "--- Backup ---"
  read -rp "Interval in minutes [60]: " INTERVAL_MIN; INTERVAL_MIN="${INTERVAL_MIN:-60}"
  if [[ -n "$HAVE_7Z" ]]; then
    read -rp "Archive format, 7z (one-click multi-volume) or zip [7z]: " ARCHIVE_FORMAT
    ARCHIVE_FORMAT="${ARCHIVE_FORMAT:-7z}"
  else
    ARCHIVE_FORMAT="zip"
  fi
  read -rp "Part size [45m]: " PART_SIZE; PART_SIZE="${PART_SIZE:-45m}"
  read -rp "Keep local backups for how many days? [3]: " KEEP_DAYS; KEEP_DAYS="${KEEP_DAYS:-3}"
  read -rsp "Archive password (empty = no password): " ZIP_PASSWORD; echo

  umask 077
  cat >"$CONF_PATH" <<EOF
# mysql-telegram-backup config — generated $(date '+%Y-%m-%d %H:%M:%S')
BOT_TOKEN="${BOT_TOKEN}"
CHAT_ID="${CHAT_ID}"
# proxy for reaching Telegram: http://host:port or socks5h://host:port
PROXY="${PROXY}"
DATABASES="${DATABASES}"
INTERVAL_MIN=${INTERVAL_MIN}

DB_USER="${DB_USER}"
DB_PASS="${DB_PASS}"
DB_HOST="${DB_HOST}"
DB_PORT=${DB_PORT}

BACKUP_DIR="${DEFAULT_BACKUP_DIR}"
ARCHIVE_FORMAT="${ARCHIVE_FORMAT}"
PART_SIZE="${PART_SIZE}"
COMPRESS_LEVEL=5
ZIP_PASSWORD="${ZIP_PASSWORD}"
KEEP_DAYS=${KEEP_DAYS}
EOF
  chmod 600 "$CONF_PATH"
  ok "config saved to ${CONF_PATH} (readable by root only)"

  # connection test
  info "testing the database connection ..."
  TMPCNF="$(mktemp)"; chmod 600 "$TMPCNF"
  printf '[client]\nuser=%s\npassword=%s\nhost=%s\nport=%s\n' \
    "$DB_USER" "$DB_PASS" "$DB_HOST" "$DB_PORT" >"$TMPCNF"
  SQLBIN="$(command -v mysql || command -v mariadb || true)"
  if [[ -n "$SQLBIN" ]] && "$SQLBIN" --defaults-extra-file="$TMPCNF" -e "SELECT 1;" >/dev/null 2>&1; then
    ok "database connection works"
  else
    warn "database connection failed. fix the user/password in ${CONF_PATH}."
  fi
  rm -f "$TMPCNF"

  # telegram test
  info "sending a test message to Telegram ..."
  if curl -sS --max-time 30 "${CURL_PROXY[@]}" -o /dev/null -f \
       -F "chat_id=${CHAT_ID}" \
       -F "text=✅ MySQL Telegram Backup installed on $(hostname)" \
       "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"; then
    ok "test message sent"
  else
    warn "test message failed. check the token/chat id, and make sure you pressed Start in the bot."
  fi
fi

# 4) systemd service
info "creating the systemd service ..."
cat >"$SERVICE_PATH" <<EOF
[Unit]
Description=MySQL backup to Telegram
After=network-online.target mysql.service mariadb.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} -f ${CONF_PATH}
Restart=always
RestartSec=30
Nice=10
IOSchedulingClass=idle
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
systemctl restart "$SERVICE_NAME"
sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
  ok "service ${SERVICE_NAME} is active"
else
  warn "the service did not start. logs: journalctl -u ${SERVICE_NAME} -n 50"
fi

# 5) logrotate-ish: nothing to do, journald handles logs

cat <<EOF

===================================================
${GREEN}Installation complete${NC}

  config:      ${CONF_PATH}
  script:      ${BIN_PATH}
  backups:     ${DEFAULT_BACKUP_DIR}

Useful commands:
  systemctl status ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f
  systemctl restart ${SERVICE_NAME}

Run one backup right now (no loop):
  ${BIN_PATH} -f ${CONF_PATH} -m 0

Change settings:
  nano ${CONF_PATH} && systemctl restart ${SERVICE_NAME}
===================================================
EOF
