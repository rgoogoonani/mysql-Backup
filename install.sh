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

GREEN=$'\e[32m'; RED=$'\e[31m'; YEL=$'\e[33m'; BLU=$'\e[34m'; NC=$'\e[0m'
ok()   { echo "${GREEN}[ OK ]${NC} $*"; }
info() { echo "${BLU}[ .. ]${NC} $*"; }
warn() { echo "${YEL}[WARN]${NC} $*"; }
die()  { echo "${RED}[FAIL]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "این اسکریپت باید با root اجرا شود:  sudo bash install.sh"

# ------------------------------------------------------------------ actions --
ACTION="install"
case "${1:-}" in
  --uninstall|-u) ACTION="uninstall" ;;
  --update)       ACTION="update" ;;
  --help|-h)      sed -n '2,10p' "$0"; exit 0 ;;
  "")             ;;
  *)              die "گزینه ناشناخته: $1" ;;
esac

fetch_script() {
  local here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${here}/${SCRIPT_NAME}" ]]; then
    info "استفاده از فایل محلی ${SCRIPT_NAME}"
    install -m 750 "${here}/${SCRIPT_NAME}" "$BIN_PATH"
  else
    local branch
    for branch in main master; do
      info "دانلود اسکریپت از شاخه ${branch} ..."
      if curl -fsSL --max-time 60 "${REPO_RAW}/${branch}/${SCRIPT_NAME}" -o /tmp/${SCRIPT_NAME}.dl; then
        install -m 750 /tmp/${SCRIPT_NAME}.dl "$BIN_PATH"
        rm -f /tmp/${SCRIPT_NAME}.dl
        break
      fi
    done
  fi
  [[ -x "$BIN_PATH" ]] || die "دانلود اسکریپت ناموفق بود. اینترنت سرور یا آدرس ریپازیتوری را بررسی کنید."
  bash -n "$BIN_PATH" || die "فایل دانلودشده معتبر نیست"
  ok "اسکریپت در ${BIN_PATH} نصب شد"
}

# ---------------------------------------------------------------- uninstall --
if [[ "$ACTION" == "uninstall" ]]; then
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_PATH"; systemctl daemon-reload 2>/dev/null || true
  rm -f "$BIN_PATH"
  ok "سرویس و اسکریپت حذف شدند"
  if [[ -f "$CONF_PATH" ]]; then
    read -rp "فایل کانفیگ ${CONF_PATH} هم حذف شود؟ [y/N]: " a
    [[ "${a,,}" == "y" ]] && rm -f "$CONF_PATH" && ok "کانفیگ حذف شد"
  fi
  if [[ -d "$DEFAULT_BACKUP_DIR" ]]; then
    read -rp "پوشه بکاپ‌های محلی ${DEFAULT_BACKUP_DIR} هم حذف شود؟ [y/N]: " a
    [[ "${a,,}" == "y" ]] && rm -rf "$DEFAULT_BACKUP_DIR" && ok "پوشه بکاپ حذف شد"
  fi
  exit 0
fi

# ------------------------------------------------------------------- update --
if [[ "$ACTION" == "update" ]]; then
  fetch_script
  systemctl restart "$SERVICE_NAME" 2>/dev/null && ok "سرویس ری‌استارت شد" || true
  exit 0
fi

# ------------------------------------------------------------------ install --
echo
echo "==================================================="
echo "   نصب MySQL Telegram Backup"
echo "==================================================="
echo

# 1) dependencies
info "بررسی و نصب پیش‌نیازها ..."
MISSING=()
command -v curl >/dev/null || MISSING+=(curl)
command -v zip  >/dev/null || MISSING+=(zip)
command -v split >/dev/null || MISSING+=(coreutils)
command -v flock >/dev/null || MISSING+=(util-linux)
if ! command -v mysqldump >/dev/null && ! command -v mariadb-dump >/dev/null; then
  if command -v mariadb >/dev/null; then MISSING+=(mariadb-client); else MISSING+=(mysql-client); fi
fi
if [[ ${#MISSING[@]} -gt 0 ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq "${MISSING[@]}" || die "نصب پیش‌نیازها ناموفق بود: ${MISSING[*]}"
fi
ok "پیش‌نیازها آماده است"

# 2) the script itself
fetch_script

# 3) configuration
if [[ -f "$CONF_PATH" ]]; then
  echo
  read -rp "فایل کانفیگ از قبل وجود دارد. بازنویسی شود؟ [y/N]: " a
  [[ "${a,,}" == "y" ]] || { info "کانفیگ قبلی حفظ شد"; SKIP_CONF=1; }
fi

if [[ -z "${SKIP_CONF:-}" ]]; then
  echo
  echo "--- تنظیمات تلگرام ---"
  while [[ -z "${BOT_TOKEN:-}" ]]; do read -rp "توکن ربات تلگرام: " BOT_TOKEN; done
  while [[ -z "${CHAT_ID:-}"   ]]; do read -rp "چت آی‌دی مقصد (عدد، برای کانال با - شروع می‌شود): " CHAT_ID; done

  echo
  echo "--- تنظیمات دیتابیس ---"
  read -rp "کاربر MySQL [root]: " DB_USER; DB_USER="${DB_USER:-root}"
  read -rsp "پسورد MySQL: " DB_PASS; echo
  read -rp "هاست [127.0.0.1]: " DB_HOST; DB_HOST="${DB_HOST:-127.0.0.1}"
  read -rp "پورت [3306]: " DB_PORT; DB_PORT="${DB_PORT:-3306}"
  while [[ -z "${DATABASES:-}" ]]; do
    read -rp "نام دیتابیس‌ها با کاما جدا شود (یا all برای همه): " DATABASES
  done

  echo
  echo "--- تنظیمات بکاپ ---"
  read -rp "فاصله زمانی ارسال به دقیقه [60]: " INTERVAL_MIN; INTERVAL_MIN="${INTERVAL_MIN:-60}"
  read -rp "حجم هر پارت [45m]: " PART_SIZE; PART_SIZE="${PART_SIZE:-45m}"
  read -rp "نگهداری بکاپ محلی چند روز؟ [3]: " KEEP_DAYS; KEEP_DAYS="${KEEP_DAYS:-3}"
  read -rsp "پسورد فایل zip (خالی = بدون رمز): " ZIP_PASSWORD; echo

  umask 077
  cat >"$CONF_PATH" <<EOF
# mysql-telegram-backup config — generated $(date '+%Y-%m-%d %H:%M:%S')
BOT_TOKEN="${BOT_TOKEN}"
CHAT_ID="${CHAT_ID}"
DATABASES="${DATABASES}"
INTERVAL_MIN=${INTERVAL_MIN}

DB_USER="${DB_USER}"
DB_PASS="${DB_PASS}"
DB_HOST="${DB_HOST}"
DB_PORT=${DB_PORT}

BACKUP_DIR="${DEFAULT_BACKUP_DIR}"
PART_SIZE="${PART_SIZE}"
ZIP_PASSWORD="${ZIP_PASSWORD}"
KEEP_DAYS=${KEEP_DAYS}
EOF
  chmod 600 "$CONF_PATH"
  ok "کانفیگ در ${CONF_PATH} ذخیره شد (فقط root می‌تواند بخواند)"

  # connection test
  info "تست اتصال به دیتابیس ..."
  TMPCNF="$(mktemp)"; chmod 600 "$TMPCNF"
  printf '[client]\nuser=%s\npassword=%s\nhost=%s\nport=%s\n' \
    "$DB_USER" "$DB_PASS" "$DB_HOST" "$DB_PORT" >"$TMPCNF"
  SQLBIN="$(command -v mysql || command -v mariadb || true)"
  if [[ -n "$SQLBIN" ]] && "$SQLBIN" --defaults-extra-file="$TMPCNF" -e "SELECT 1;" >/dev/null 2>&1; then
    ok "اتصال به دیتابیس برقرار است"
  else
    warn "اتصال به دیتابیس برقرار نشد. کاربر/پسورد را در ${CONF_PATH} اصلاح کنید."
  fi
  rm -f "$TMPCNF"

  # telegram test
  info "ارسال پیام تست به تلگرام ..."
  if curl -sS --max-time 30 -o /dev/null -f \
       -F "chat_id=${CHAT_ID}" \
       -F "text=✅ MySQL Telegram Backup روی $(hostname) نصب شد." \
       "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"; then
    ok "پیام تست ارسال شد"
  else
    warn "ارسال پیام تست ناموفق بود. توکن/چت‌آیدی را بررسی کنید (و اینکه ربات را start کرده باشید)."
  fi
fi

# 4) systemd service
info "ساخت سرویس systemd ..."
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
  ok "سرویس ${SERVICE_NAME} فعال است"
else
  warn "سرویس بالا نیامد. لاگ: journalctl -u ${SERVICE_NAME} -n 50"
fi

# 5) logrotate-ish: nothing to do, journald handles logs

cat <<EOF

===================================================
${GREEN}نصب کامل شد${NC}

  کانفیگ:        ${CONF_PATH}
  اسکریپت:       ${BIN_PATH}
  پوشه بکاپ:     ${DEFAULT_BACKUP_DIR}

دستورهای پرکاربرد:
  systemctl status ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f
  systemctl restart ${SERVICE_NAME}

گرفتن یک بکاپ فوری (بدون حلقه):
  ${BIN_PATH} -f ${CONF_PATH} -m 0

تغییر تنظیمات:
  nano ${CONF_PATH} && systemctl restart ${SERVICE_NAME}
===================================================
EOF
