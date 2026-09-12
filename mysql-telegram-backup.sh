#!/usr/bin/env bash
#
# mysql-telegram-backup.sh
# Dump MySQL/MariaDB databases -> zip (auto-split) -> send to a Telegram chat.
# Tested on Ubuntu 24.04. Requires: mysqldump (mysql-client), zip, curl.
#
# Usage examples at the bottom of this file (--help).

set -Eeuo pipefail

# ---------------------------------------------------------------- defaults ---
BOT_TOKEN="${BOT_TOKEN:-}"
CHAT_ID="${CHAT_ID:-}"
DATABASES="${DATABASES:-}"              # comma separated, or "all"
INTERVAL_MIN="${INTERVAL_MIN:-0}"       # 0 = run once and exit
DB_USER="${DB_USER:-root}"
DB_PASS="${DB_PASS:-}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/mysql-tg}"
PART_SIZE="${PART_SIZE:-45m}"           # each zip part size (keep under 50m)
ZIP_PASSWORD="${ZIP_PASSWORD:-}"        # optional zip password
KEEP_DAYS="${KEEP_DAYS:-3}"             # keep local copies N days (0 = delete now)
TG_API="${TG_API:-https://api.telegram.org}"

# ------------------------------------------------------------------- utils ---
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
mysql-telegram-backup.sh

Options:
  -t, --token TOKEN        Telegram bot token            (required)
  -c, --chat-id ID         Destination chat id           (required)
  -d, --databases LIST     Comma separated db names, or "all"   (required)
  -m, --minutes N          Send every N minutes. 0 = run once   (default 0)

  -u, --db-user USER       MySQL user        (default root)
  -p, --db-pass PASS       MySQL password    (default empty)
  -H, --db-host HOST       MySQL host        (default 127.0.0.1)
  -P, --db-port PORT       MySQL port        (default 3306)

  -o, --out DIR            Backup directory  (default /var/backups/mysql-tg)
  -s, --part-size SIZE     Zip part size, e.g. 45m  (default 45m)
  -z, --zip-pass PASS      Password protect the zip  (optional)
  -k, --keep-days N        Keep local backups N days (default 3)
  -f, --config FILE        Read variables from a shell config file
  -h, --help               This help

Every option can also be given as an environment variable:
BOT_TOKEN CHAT_ID DATABASES INTERVAL_MIN DB_USER DB_PASS DB_HOST DB_PORT
BACKUP_DIR PART_SIZE ZIP_PASSWORD KEEP_DAYS
EOF
}

# --------------------------------------------------------------- arg parse ---
CONFIG_FILE=""
declare -A CLI=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--token)      CLI[BOT_TOKEN]="$2"; shift 2 ;;
    -c|--chat-id)    CLI[CHAT_ID]="$2"; shift 2 ;;
    -d|--databases)  CLI[DATABASES]="$2"; shift 2 ;;
    -m|--minutes)    CLI[INTERVAL_MIN]="$2"; shift 2 ;;
    -u|--db-user)    CLI[DB_USER]="$2"; shift 2 ;;
    -p|--db-pass)    CLI[DB_PASS]="$2"; shift 2 ;;
    -H|--db-host)    CLI[DB_HOST]="$2"; shift 2 ;;
    -P|--db-port)    CLI[DB_PORT]="$2"; shift 2 ;;
    -o|--out)        CLI[BACKUP_DIR]="$2"; shift 2 ;;
    -s|--part-size)  CLI[PART_SIZE]="$2"; shift 2 ;;
    -z|--zip-pass)   CLI[ZIP_PASSWORD]="$2"; shift 2 ;;
    -k|--keep-days)  CLI[KEEP_DAYS]="$2"; shift 2 ;;
    -f|--config)     CONFIG_FILE="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) die "unknown option: $1 (use --help)" ;;
  esac
done

# config file is loaded first, then CLI args are re-applied so they always win
if [[ -n "$CONFIG_FILE" ]]; then
  [[ -r "$CONFIG_FILE" ]] || die "config file not readable: $CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi
for k in "${!CLI[@]}"; do printf -v "$k" '%s' "${CLI[$k]}"; done

# ------------------------------------------------------- interactive prompt ---
if [[ -t 0 ]]; then   # only ask when running in a terminal, never under systemd
  [[ -z "$BOT_TOKEN" ]] && read -rp "Telegram bot token: " BOT_TOKEN
  [[ -z "$CHAT_ID"   ]] && read -rp "Destination chat id: " CHAT_ID
  [[ -z "$DATABASES" ]] && read -rp "Database name(s), comma separated (or 'all'): " DATABASES
  if [[ -z "$CONFIG_FILE" && -z "${CLI[INTERVAL_MIN]:-}" ]]; then
    read -rp "Interval in minutes (0 = run once) [0]: " _iv || true
    INTERVAL_MIN="${_iv:-0}"
  fi
fi

[[ -n "$BOT_TOKEN" ]] || die "bot token is empty"
[[ -n "$CHAT_ID"   ]] || die "chat id is empty"
[[ -n "$DATABASES" ]] || die "database list is empty"
[[ "$INTERVAL_MIN" =~ ^[0-9]+$ ]] || die "minutes must be a number"

# ----------------------------------------------------------- dependencies ----
DUMP_BIN=""
for b in mysqldump mariadb-dump; do
  if command -v "$b" >/dev/null 2>&1; then DUMP_BIN="$b"; break; fi
done
[[ -n "$DUMP_BIN" ]] || die "mysqldump not found. install with: apt install mysql-client"
command -v zip  >/dev/null 2>&1 || die "zip not found. install with: apt install zip"
command -v curl >/dev/null 2>&1 || die "curl not found. install with: apt install curl"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# part size -> bytes (45m -> 47185920)
PART_BYTES="$(numfmt --from=iec "${PART_SIZE^^}" 2>/dev/null || true)"
[[ -n "$PART_BYTES" ]] || die "invalid --part-size: $PART_SIZE (use e.g. 45m)"
if [[ "$PART_BYTES" -gt 49000000 ]]; then
  log "WARNING: part size $PART_SIZE is close to / above Telegram's 50MB bot limit"
fi

# credentials go into a 0600 temp file so they never show up in `ps`
MYCNF="$(mktemp)"
chmod 600 "$MYCNF"
cat >"$MYCNF" <<EOF
[client]
user=${DB_USER}
password=${DB_PASS}
host=${DB_HOST}
port=${DB_PORT}
EOF
trap 'rm -f "$MYCNF"' EXIT

# build dump options depending on what this server's dumper supports
DUMP_OPTS=(--single-transaction --quick --routines --triggers --events
           --default-character-set=utf8mb4)
DUMP_HELP="$("$DUMP_BIN" --help 2>/dev/null || true)"
if grep -q -- '--no-tablespaces' <<<"$DUMP_HELP"; then
  DUMP_OPTS+=(--no-tablespaces)
fi
if grep -q -- '--set-gtid-purged' <<<"$DUMP_HELP"; then
  DUMP_OPTS+=(--set-gtid-purged=OFF)
fi

# ------------------------------------------------------------------ telegram --
tg_send_file() {
  local file="$1" caption="$2" code body
  local attempt
  for attempt in 1 2 3; do
    body="$(mktemp)"
    code="$(curl -sS --max-time 600 \
              -o "$body" -w '%{http_code}' \
              -F "chat_id=${CHAT_ID}" \
              -F "caption=${caption}" \
              -F "document=@${file}" \
              "${TG_API}/bot${BOT_TOKEN}/sendDocument" || echo 000)"
    if [[ "$code" == "200" ]]; then
      rm -f "$body"; return 0
    fi
    log "telegram upload failed (http $code, try $attempt/3): $(head -c 300 "$body" 2>/dev/null)"
    rm -f "$body"
    sleep 15
  done
  return 1
}

tg_send_text() {
  curl -sS --max-time 60 -o /dev/null \
    -F "chat_id=${CHAT_ID}" -F "text=$1" \
    "${TG_API}/bot${BOT_TOKEN}/sendMessage" >/dev/null 2>&1 || true
}

# -------------------------------------------------------------- db handling --
list_all_databases() {
  local sql_bin
  sql_bin="$(command -v mysql || command -v mariadb)" || die "mysql client not found"
  "$sql_bin" --defaults-extra-file="$MYCNF" -N -B -e \
    "SHOW DATABASES;" \
    | grep -Ev '^(information_schema|performance_schema|mysql|sys)$'
}

backup_one_db() {
  local db="$1"
  local ts base sqlfile parts n i sizeb
  ts="$(date '+%Y-%m-%d_%H-%M-%S')"
  base="${db}_${ts}"
  sqlfile="${BACKUP_DIR}/${base}.sql"

  log "dumping database: $db"
  if ! "$DUMP_BIN" --defaults-extra-file="$MYCNF" "${DUMP_OPTS[@]}" \
        --databases "$db" >"$sqlfile" 2>"${sqlfile}.err"; then
    log "dump failed for $db: $(tail -c 400 "${sqlfile}.err")"
    tg_send_text "❌ Backup failed for database: ${db}"
    rm -f "$sqlfile" "${sqlfile}.err"
    return 1
  fi
  rm -f "${sqlfile}.err"

  sizeb=$(stat -c%s "$sqlfile")
  [[ "$sizeb" -gt 0 ]] || { log "empty dump for $db"; rm -f "$sqlfile"; return 1; }
  log "dump size: $(numfmt --to=iec "$sizeb")"

  # compress
  local zipargs=(-q -j)
  [[ -n "$ZIP_PASSWORD" ]] && zipargs+=(-P "$ZIP_PASSWORD")
  ( cd "$BACKUP_DIR" && zip "${zipargs[@]}" "${base}.zip" "$(basename "$sqlfile")" )
  rm -f "$sqlfile"

  local zipfile="${BACKUP_DIR}/${base}.zip"
  local zipsize
  zipsize=$(stat -c%s "$zipfile")
  log "zip size: $(numfmt --to=iec "$zipsize")"

  # split only when the archive is bigger than one Telegram part
  if [[ "$zipsize" -gt "$PART_BYTES" ]]; then
    split -b "$PART_BYTES" -d -a 3 --numeric-suffixes=1 \
          --additional-suffix=.part "$zipfile" "${zipfile}."
    rm -f "$zipfile"
    mapfile -t parts < <(find "$BACKUP_DIR" -maxdepth 1 -name "${base}.zip.*.part" | sort)
  else
    parts=("$zipfile")
  fi

  n="${#parts[@]}"
  [[ "$n" -gt 0 ]] || { log "zip produced nothing for $db"; return 1; }

  i=0
  for p in "${parts[@]}"; do
    i=$((i+1))
    local psize cap
    psize=$(stat -c%s "$p")
    if [[ "$psize" -gt 52000000 ]]; then
      log "WARNING: $(basename "$p") is larger than 50MB, Telegram will reject it. Lower --part-size."
    fi
    if [[ "$n" -gt 1 ]]; then
      cap="🗄 ${db} | ${ts} | part ${i}/${n} | $(numfmt --to=iec "$psize")"
    else
      cap="🗄 ${db} | ${ts} | $(numfmt --to=iec "$psize")"
    fi
    log "sending $(basename "$p") ($i/$n)"
    if ! tg_send_file "$p" "$cap"; then
      log "could not send $(basename "$p")"
      tg_send_text "❌ Failed to upload part ${i}/${n} of ${db} (${ts})"
      return 1
    fi
    sleep 2
  done

  if [[ "$n" -gt 1 ]]; then
    tg_send_text "ℹ️ ${db} (${ts}) was sent in ${n} parts.
Download all parts into one folder, then:

Linux/macOS:
cat ${base}.zip.*.part > ${base}.zip && unzip ${base}.zip

Windows (cmd):
copy /b ${base}.zip.001.part+${base}.zip.002.part ... ${base}.zip"
  fi

  log "database $db done ($n file(s))"
  return 0
}

prune_old() {
  if [[ "$KEEP_DAYS" == "0" ]]; then
    find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.zip' -o -name '*.part' \) -delete
  else
    find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.zip' -o -name '*.part' \) \
      -mtime +"$KEEP_DAYS" -delete
  fi
}

run_cycle() {
  local dbs=() ok=0 fail=0
  if [[ "${DATABASES,,}" == "all" ]]; then
    mapfile -t dbs < <(list_all_databases)
  else
    IFS=',' read -r -a dbs <<<"$DATABASES"
  fi

  for db in "${dbs[@]}"; do
    db="$(echo "$db" | xargs)"      # trim spaces
    [[ -n "$db" ]] || continue
    if backup_one_db "$db"; then ok=$((ok+1)); else fail=$((fail+1)); fi
  done

  prune_old
  log "cycle finished: ${ok} ok, ${fail} failed"
}

# -------------------------------------------------------------------- main ---
# a lock so two cycles never overlap on long backups
LOCKFILE="/var/lock/mysql-telegram-backup.lock"
exec 9>"$LOCKFILE" || LOCKFILE=""
if [[ -n "$LOCKFILE" ]] && ! flock -n 9; then
  die "another instance is already running"
fi

if [[ "$INTERVAL_MIN" -eq 0 ]]; then
  run_cycle
else
  log "starting loop: every ${INTERVAL_MIN} minute(s)"
  while true; do
    run_cycle || log "cycle returned an error, continuing"
    sleep $(( INTERVAL_MIN * 60 ))
  done
fi
