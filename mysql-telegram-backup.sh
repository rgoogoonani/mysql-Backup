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
PART_SIZE="${PART_SIZE:-45m}"           # each part size (keep under 50m)
ARCHIVE_FORMAT="${ARCHIVE_FORMAT:-7z}"  # 7z = WinRAR-style volumes | zip = plain zip
COMPRESS_LEVEL="${COMPRESS_LEVEL:-5}"   # 0..9 for 7z
ZIP_PASSWORD="${ZIP_PASSWORD:-}"        # optional archive password
KEEP_DAYS="${KEEP_DAYS:-3}"             # keep local copies N days (0 = delete now)
TG_API="${TG_API:-https://api.telegram.org}"
# Telegram is blocked in some countries. Give a proxy the server can reach:
#   http://127.0.0.1:8118            http proxy
#   http://user:pass@1.2.3.4:8080    http proxy with auth
#   socks5h://127.0.0.1:10808        socks5 (h = DNS resolved by the proxy)
PROXY="${PROXY:-}"

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
  -s, --part-size SIZE     Part size, e.g. 45m  (default 45m)
  -a, --format 7z|zip      Archive format (default 7z: WinRAR-style volumes)
  -z, --zip-pass PASS      Password protect the archive  (optional)
  -k, --keep-days N        Keep local backups N days (default 3)
  -x, --proxy URL          Proxy for Telegram, http://.. or socks5h://..
  -f, --config FILE        Read variables from a shell config file
  -h, --help               This help

Every option can also be given as an environment variable:
BOT_TOKEN CHAT_ID DATABASES INTERVAL_MIN DB_USER DB_PASS DB_HOST DB_PORT
BACKUP_DIR PART_SIZE ARCHIVE_FORMAT ZIP_PASSWORD KEEP_DAYS PROXY TG_API
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
    -a|--format)     CLI[ARCHIVE_FORMAT]="$2"; shift 2 ;;
    -z|--zip-pass)   CLI[ZIP_PASSWORD]="$2"; shift 2 ;;
    -k|--keep-days)  CLI[KEEP_DAYS]="$2"; shift 2 ;;
    -x|--proxy)      CLI[PROXY]="$2"; shift 2 ;;
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
command -v curl >/dev/null 2>&1 || die "curl not found. install with: apt install curl"

# 7-Zip creates real multi-volume archives (file.7z.001, .002 ...) that WinRAR
# and 7-Zip open with a double click on the first part — no manual rejoining.
SEVENZIP=""
for b in 7zz 7z 7za 7zr; do
  if command -v "$b" >/dev/null 2>&1; then SEVENZIP="$b"; break; fi
done
ARCHIVE_FORMAT="${ARCHIVE_FORMAT,,}"
if [[ "$ARCHIVE_FORMAT" == "7z" && -z "$SEVENZIP" ]]; then
  log "WARNING: 7z not found (apt install 7zip), falling back to zip format"
  ARCHIVE_FORMAT="zip"
fi
if [[ "$ARCHIVE_FORMAT" == "zip" ]]; then
  command -v zip >/dev/null 2>&1 || die "zip not found. install with: apt install zip"
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# part size -> bytes (45m -> 47185920)
PART_BYTES="$(numfmt --from=iec "${PART_SIZE^^}" 2>/dev/null || true)"
[[ -n "$PART_BYTES" ]] || die "invalid --part-size: $PART_SIZE (use e.g. 45m)"
if [[ "$PART_BYTES" -gt 49000000 ]]; then
  log "WARNING: part size $PART_SIZE is close to / above Telegram's 50MB bot limit"
fi

# proxy for every Telegram request
CURL_PROXY=()
if [[ -n "$PROXY" ]]; then
  case "$PROXY" in
    http://*|https://*|socks5://*|socks5h://*|socks4://*|socks4a://*) ;;
    *) die "invalid proxy: $PROXY (must start with http:// or socks5h://)" ;;
  esac
  CURL_PROXY=(--proxy "$PROXY")
  log "using proxy: ${PROXY%%:*}://...${PROXY##*@}"
  curl -sS --max-time 25 "${CURL_PROXY[@]}" -o /dev/null \
       "${TG_API}/bot${BOT_TOKEN}/getMe" \
    && log "telegram reachable through the proxy" \
    || log "WARNING: could not reach Telegram through the proxy yet"
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
    code="$(curl -sS --max-time 900 "${CURL_PROXY[@]}" \
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
  curl -sS --max-time 60 "${CURL_PROXY[@]}" -o /dev/null \
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

# Builds the archive and fills ARCHIVE_PARTS with the files to upload, in order.
# 7z mode  -> base.7z            (single)   or base.7z.001, base.7z.002 ... (volumes)
# zip mode -> base.zip           (single)   or base.zip.001.part ...        (raw split)
ARCHIVE_PARTS=()
create_archive() {
  local sqlfile="$1" base="$2"
  ARCHIVE_PARTS=()

  if [[ "$ARCHIVE_FORMAT" == "7z" ]]; then
    local args=(a -t7z "-mx=${COMPRESS_LEVEL}" "-v${PART_SIZE}" -y)
    if [[ -n "$ZIP_PASSWORD" ]]; then
      args+=("-p${ZIP_PASSWORD}" -mhe=on)   # -mhe also encrypts the file list
    fi
    local rc=0
    ( cd "$BACKUP_DIR" && "$SEVENZIP" "${args[@]}" "${base}.7z" "$(basename "$sqlfile")" \
        >/dev/null 2>"${sqlfile}.7z.err" ) || rc=$?
    if [[ $rc -gt 1 ]]; then          # 0 = ok, 1 = warning, >1 = real error
      log "7z failed (rc=$rc): $(tail -c 300 "${sqlfile}.7z.err" 2>/dev/null)"
      rm -f "${sqlfile}.7z.err"
      return 1
    fi
    rm -f "${sqlfile}.7z.err" "$sqlfile"

    mapfile -t ARCHIVE_PARTS < <(find "$BACKUP_DIR" -maxdepth 1 \
      -name "${base}.7z.[0-9][0-9][0-9]" | sort)
    # a single volume gets renamed to plain .7z so it opens with one click
    if [[ ${#ARCHIVE_PARTS[@]} -eq 1 ]]; then
      mv -f "${ARCHIVE_PARTS[0]}" "${BACKUP_DIR}/${base}.7z"
      ARCHIVE_PARTS=("${BACKUP_DIR}/${base}.7z")
    fi

  else
    local zipargs=(-q -j)
    [[ -n "$ZIP_PASSWORD" ]] && zipargs+=(-P "$ZIP_PASSWORD")
    ( cd "$BACKUP_DIR" && zip "${zipargs[@]}" "${base}.zip" "$(basename "$sqlfile")" ) || return 1
    rm -f "$sqlfile"
    local zipfile="${BACKUP_DIR}/${base}.zip"
    if [[ "$(stat -c%s "$zipfile")" -gt "$PART_BYTES" ]]; then
      split -b "$PART_BYTES" -d -a 3 --numeric-suffixes=1 \
            --additional-suffix=.part "$zipfile" "${zipfile}."
      rm -f "$zipfile"
      mapfile -t ARCHIVE_PARTS < <(find "$BACKUP_DIR" -maxdepth 1 \
        -name "${base}.zip.*.part" | sort)
    else
      ARCHIVE_PARTS=("$zipfile")
    fi
  fi

  local total=0 f
  for f in "${ARCHIVE_PARTS[@]}"; do total=$(( total + $(stat -c%s "$f") )); done
  log "archive: ${#ARCHIVE_PARTS[@]} file(s), $(numfmt --to=iec "$total") total"
  return 0
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

  # compress (fills the global ARCHIVE_PARTS array)
  create_archive "$sqlfile" "$base" || { log "compression failed for $db"; return 1; }
  parts=("${ARCHIVE_PARTS[@]}")

  n="${#parts[@]}"
  [[ "$n" -gt 0 ]] || { log "archiving produced nothing for $db"; return 1; }

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
    if [[ "$ARCHIVE_FORMAT" == "7z" ]]; then
      tg_send_text "ℹ️ ${db} (${ts}) — ${n} parts.
Download every part into the same folder, then right-click ${base}.7z.001 and choose Extract Here (WinRAR or 7-Zip). The other parts are picked up automatically.
Linux: 7z x ${base}.7z.001"
    else
      tg_send_text "ℹ️ ${db} (${ts}) — ${n} parts.
Download all parts into one folder, then:
cat ${base}.zip.*.part > ${base}.zip && unzip ${base}.zip"
    fi
  fi

  log "database $db done ($n file(s))"
  return 0
}

prune_old() {
  local pat=(-name '*.zip' -o -name '*.part' -o -name '*.7z' -o -name '*.7z.[0-9][0-9][0-9]')
  if [[ "$KEEP_DAYS" == "0" ]]; then
    find "$BACKUP_DIR" -maxdepth 1 -type f \( "${pat[@]}" \) -delete
  else
    find "$BACKUP_DIR" -maxdepth 1 -type f \( "${pat[@]}" \) -mtime +"$KEEP_DAYS" -delete
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
