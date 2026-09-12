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
    local branch ts
    ts="$(date +%s)"   # cache buster: raw.githubusercontent and http proxies cache responses
    for branch in main master; do
      info "downloading the script from branch ${branch} ..."
      if curl -fsSL --max-time 60 "${CURL_PROXY[@]}" \
              -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
              "${REPO_RAW}/${branch}/${SCRIPT_NAME}?nocache=${ts}" -o /tmp/${SCRIPT_NAME}.dl; then
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
    printf '\nPROXY=%q\n' "$PROXY" >>"$CONF_PATH"
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
  ADMIN_CNF=""
  ADMIN_ARGS=()

  # Try, in order, every way of reaching the server as an admin without asking
  # the user anything. On Ubuntu, root normally authenticates through the unix
  # socket (auth_socket / unix_socket), so no password exists at all.
  find_admin_access() {
    local candidates=(
      "--protocol=socket"
      ""
      "--defaults-file=/etc/mysql/debian.cnf"
    )
    local c
    for c in "${candidates[@]}"; do
      [[ "$c" == "--defaults-file=/etc/mysql/debian.cnf" && ! -r /etc/mysql/debian.cnf ]] && continue
      if [[ -z "$c" ]]; then ADMIN_ARGS=(); else ADMIN_ARGS=("$c"); fi
      if "$SQLBIN" "${ADMIN_ARGS[@]}" -e "SELECT 1" >/dev/null 2>&1; then
        info "admin access via ${c:-default local connection}"
        return 0
      fi
    done
    # nothing worked (remote server, or root has a password) -> ask once
    echo "Admin credentials are needed once to create the backup user."
    echo "They are used now and never stored."
    read -rp "  Admin user [root]: " ADM_USER; ADM_USER="${ADM_USER:-root}"
    read -rsp "  Admin password: " ADM_PASS; echo
    ADMIN_CNF="$(mktemp)"; chmod 600 "$ADMIN_CNF"
    printf '[client]\nuser=%s\npassword=%s\nhost=%s\nport=%s\n' \
      "$ADM_USER" "$ADM_PASS" "$DB_HOST" "$DB_PORT" >"$ADMIN_CNF"
    ADMIN_ARGS=(--defaults-extra-file="$ADMIN_CNF")
    "$SQLBIN" "${ADMIN_ARGS[@]}" -e "SELECT 1" >/dev/null 2>&1
  }

  # Verify a user/password actually works over the connection the backup
  # script will use, so a broken login is caught now and not at 3am.
  db_login_works() {
    local u="$1" p="$2" cnf rc=0
    cnf="$(mktemp)"; chmod 600 "$cnf"
    printf '[client]\nuser=%s\npassword=%s\nhost=%s\nport=%s\n' \
      "$u" "$p" "$DB_HOST" "$DB_PORT" >"$cnf"
    "$SQLBIN" --defaults-extra-file="$cnf" -e "SELECT 1" >/dev/null 2>&1 || rc=1
    rm -f "$cnf"
    return $rc
  }

  create_backup_user() {
    local BK_USER="backup" GEN_PASS SQL h hosts GRANTS
    # 28 chars, letters+digits only so no SQL/shell quoting surprises
    GEN_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 28)"
    # 'localhost' matches socket connections, '127.0.0.1' matches TCP;
    # a remote server needs a wildcard host instead
    case "$DB_HOST" in
      localhost|127.0.0.1|::1) hosts=(localhost 127.0.0.1) ;;
      *) hosts=('%'); warn "remote database: the user will be created as '${BK_USER}'@'%'" ;;
    esac
    GRANTS="SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER, RELOAD, PROCESS, REPLICATION CLIENT"
    SQL=""
    for h in "${hosts[@]}"; do
      SQL+="CREATE USER IF NOT EXISTS '${BK_USER}'@'${h}' IDENTIFIED BY '${GEN_PASS}';"
      SQL+="ALTER USER '${BK_USER}'@'${h}' IDENTIFIED BY '${GEN_PASS}';"
      SQL+="GRANT ${GRANTS} ON *.* TO '${BK_USER}'@'${h}';"
    done
    SQL+="FLUSH PRIVILEGES;"

    if ! "$SQLBIN" "${ADMIN_ARGS[@]}" -e "$SQL" 2>/tmp/.mkuser.err; then
      warn "could not create the user: $(tail -c 300 /tmp/.mkuser.err)"
      rm -f /tmp/.mkuser.err
      return 1
    fi
    rm -f /tmp/.mkuser.err

    if ! db_login_works "$BK_USER" "$GEN_PASS"; then
      warn "user '${BK_USER}' was created but cannot log in on ${DB_HOST}:${DB_PORT}"
      return 1
    fi
    DB_USER="$BK_USER"; DB_PASS="$GEN_PASS"; BACKUP_USER_CREATED=1
    ok "user '${BK_USER}' created and verified (random 28-char password)"
    echo "     the password is stored in ${CONF_PATH}, you do not need it"
    return 0
  }

  if [[ -n "$SQLBIN" ]]; then
    info "creating a dedicated backup user ..."
    if find_admin_access; then
      create_backup_user || true
    else
      warn "could not connect with those admin credentials"
    fi
    [[ -n "$ADMIN_CNF" ]] && rm -f "$ADMIN_CNF"
  else
    warn "no mysql client found, skipping user creation"
  fi

  # only fall back to manual credentials if the automatic path failed
  while [[ "$BACKUP_USER_CREATED" -eq 0 ]]; do
    echo
    warn "enter database credentials manually:"
    read -rp "MySQL user [root]: " DB_USER; DB_USER="${DB_USER:-root}"
    read -rsp "MySQL password: " DB_PASS; echo
    if [[ -z "$SQLBIN" ]] || db_login_works "$DB_USER" "$DB_PASS"; then
      break
    fi
    warn "login failed for '${DB_USER}'@${DB_HOST}"
    if [[ "$DB_USER" == "root" ]]; then
      warn "on Ubuntu, root usually authenticates through the unix socket and has"
      warn "no password, so a password login always fails (MySQL error 1698)."
    fi
    read -rp "Try again? [Y/n]: " a
    [[ "${a,,}" == "n" ]] && break
  done

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
  # Values are written with printf %q, so passwords containing $ ` " ' or a
  # backslash are stored literally instead of being expanded when the config
  # is sourced.
  {
    echo "# mysql-telegram-backup config - generated $(date '+%Y-%m-%d %H:%M:%S')"
    printf 'BOT_TOKEN=%q\n' "$BOT_TOKEN"
    printf 'CHAT_ID=%q\n'   "$CHAT_ID"
    echo "# proxy for reaching Telegram: http://host:port or socks5h://host:port"
    printf 'PROXY=%q\n'     "$PROXY"
    printf 'DATABASES=%q\n' "$DATABASES"
    printf 'INTERVAL_MIN=%q\n' "$INTERVAL_MIN"
    echo
    printf 'DB_USER=%q\n' "$DB_USER"
    printf 'DB_PASS=%q\n' "$DB_PASS"
    printf 'DB_HOST=%q\n' "$DB_HOST"
    printf 'DB_PORT=%q\n' "$DB_PORT"
    echo
    printf 'BACKUP_DIR=%q\n'     "$DEFAULT_BACKUP_DIR"
    printf 'ARCHIVE_FORMAT=%q\n' "$ARCHIVE_FORMAT"
    printf 'PART_SIZE=%q\n'      "$PART_SIZE"
    echo 'COMPRESS_LEVEL=5'
    printf 'ZIP_PASSWORD=%q\n'   "$ZIP_PASSWORD"
    printf 'KEEP_DAYS=%q\n'      "$KEEP_DAYS"
  } >"$CONF_PATH"
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
