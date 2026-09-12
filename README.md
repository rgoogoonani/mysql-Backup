<div dir="rtl">

# 🗄 MySQL Telegram Backup

بکاپ خودکار از دیتابیس‌های MySQL / MariaDB، فشرده‌سازی با zip، تقسیم خودکار به پارت‌های زیر ۵۰ مگابایت و ارسال به تلگرام — مخصوص سرورهای اوبونتو.

</div>

<div dir="rtl">

## ✨ امکانات

- بکاپ از یک، چند یا **همه‌ی** دیتابیس‌ها (`all`)
- فشرده‌سازی با zip و پشتیبانی از **رمز روی فایل zip**
- تقسیم خودکار به پارت‌های ۴۵ مگابایتی وقتی فایل از سقف ربات تلگرام بزرگ‌تر است
- ارسال دوره‌ای بر اساس **دقیقه** (مثلاً هر ۳۰ دقیقه یک بار)
- اجرا به‌صورت سرویس `systemd` با ری‌استارت خودکار و بالا آمدن بعد از ریبوت
- پسورد دیتابیس داخل فایل موقت با پرمیشن `600` قرار می‌گیرد و در خروجی `ps` دیده **نمی‌شود**
- `--single-transaction` برای بکاپ بدون قفل کردن جدول‌های InnoDB
- پاک‌سازی خودکار بکاپ‌های قدیمی روی سرور
- قفل اجرا (`flock`) تا دو بکاپ هم‌زمان روی هم نیفتند
- تشخیص خودکار `mysqldump` یا `mariadb-dump` و آپشن‌های پشتیبانی‌شده

</div>

<div dir="rtl">

## 📋 پیش‌نیازها

- اوبونتو ۲۲.۰۴ / ۲۴.۰۴ یا دبیان (سایر توزیع‌های مبتنی بر apt هم کار می‌کند)
- دسترسی `root` یا `sudo`
- MySQL 5.7+ یا MariaDB 10+
- بسته‌های `mysql-client` ، `zip` ، `curl` (اسکریپت نصب خودش نصب می‌کند)

</div>

<div dir="rtl">

## 🤖 مرحله ۱ — ساخت ربات تلگرام و گرفتن چت آی‌دی

**ساخت ربات:**

۱. در تلگرام به [@BotFather](https://t.me/BotFather) پیام بدهید
۲. دستور `/newbot` را بزنید و یک نام و یوزرنیم انتخاب کنید
۳. توکنی مثل `123456789:AAH...xyz` به شما داده می‌شود — این همان **BOT_TOKEN** است

**گرفتن چت آی‌دی:**

- **پیوی خودتان:** به ربات `/start` بدهید، بعد در مرورگر باز کنید:
  `https://api.telegram.org/bot<TOKEN>/getUpdates`
  عدد داخل `"chat":{"id":...}` همان چت آی‌دی شماست.
- **کانال یا گروه:** ربات را عضو و **ادمین** کنید، یک پیام بفرستید و دوباره `getUpdates` را چک کنید. آی‌دی کانال با `-100` شروع می‌شود.
- روش ساده‌تر: به [@userinfobot](https://t.me/userinfobot) پیام بدهید.

> ⚠️ حتماً قبل از نصب، به ربات خودتان `/start` بدهید؛ وگرنه تلگرام اجازه ارسال پیام به شما را نمی‌دهد.

</div>

<div dir="rtl">

## 👤 مرحله ۲ — ساخت کاربر دیتابیس (اختیاری ولی توصیه‌شده)

به‌جای استفاده از `root`، یک کاربر فقط برای بکاپ بسازید:

</div>

```sql
CREATE USER 'backup'@'localhost' IDENTIFIED BY 'یک_پسورد_قوی';
GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER, RELOAD, PROCESS ON *.* TO 'backup'@'localhost';
FLUSH PRIVILEGES;
```

<div dir="rtl">

## 🚀 مرحله ۳ — نصب

### روش اول: نصب با یک دستور

</div>

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/rgoogoonani/mysql-Baclup/main/install.sh)
```

<div dir="rtl">

### روش دوم: کلون کردن ریپازیتوری

</div>

```bash
git clone https://github.com/rgoogoonani/mysql-Baclup.git
cd mysql-Baclup
sudo bash install.sh
```

<div dir="rtl">

اسکریپت نصب این کارها را انجام می‌دهد:

۱. پیش‌نیازها را نصب می‌کند
۲. اسکریپت اصلی را در `/usr/local/bin/mysql-telegram-backup.sh` می‌گذارد
۳. سؤال‌های زیر را می‌پرسد و کانفیگ را در `/etc/mysql-tg-backup.conf` ذخیره می‌کند:

| سؤال | توضیح |
|---|---|
| توکن ربات | همان چیزی که BotFather داد |
| چت آی‌دی | مقصد ارسال بکاپ |
| کاربر / پسورد MySQL | پیش‌فرض `root` |
| نام دیتابیس‌ها | مثلاً `wordpress,shop` یا `all` |
| فاصله زمانی | به دقیقه، مثلاً `60` |
| حجم هر پارت | پیش‌فرض `45m` |
| نگهداری بکاپ محلی | چند روز روی سرور بماند |
| پسورد zip | خالی بگذارید اگر رمز نمی‌خواهید |

۴. اتصال به دیتابیس و ارسال پیام تست به تلگرام را چک می‌کند
۵. سرویس `systemd` را می‌سازد و اجرا می‌کند

</div>

<div dir="rtl">

## ⚙️ مرحله ۴ — استفاده

### وضعیت سرویس و لاگ‌ها

</div>

```bash
systemctl status mysql-tg-backup      # وضعیت سرویس
journalctl -u mysql-tg-backup -f      # دیدن لاگ لحظه‌ای
systemctl restart mysql-tg-backup     # ری‌استارت بعد از تغییر کانفیگ
systemctl stop mysql-tg-backup        # توقف موقت
```

<div dir="rtl">

### گرفتن بکاپ فوری (بدون حلقه)

</div>

```bash
sudo /usr/local/bin/mysql-telegram-backup.sh -f /etc/mysql-tg-backup.conf -m 0
```

<div dir="rtl">

### تغییر تنظیمات

</div>

```bash
sudo nano /etc/mysql-tg-backup.conf
sudo systemctl restart mysql-tg-backup
```

<div dir="rtl">

### اجرای دستی با پارامتر (بدون فایل کانفیگ)

</div>

```bash
# یک بار اجرا
sudo mysql-telegram-backup.sh -t 123:ABC -c 987654321 -d "mydb" -u root -p 'pass' -m 0

# حلقه هر ۳۰ دقیقه، چند دیتابیس
sudo mysql-telegram-backup.sh -t 123:ABC -c 987654321 -d "db1,db2" -u root -p 'pass' -m 30

# همه دیتابیس‌ها با zip رمزدار
sudo mysql-telegram-backup.sh -t 123:ABC -c 987654321 -d all -p 'pass' -z 'zippass' -m 120
```

<div dir="rtl">

### همه‌ی پارامترها

| پارامتر کوتاه | پارامتر بلند | توضیح | پیش‌فرض |
|---|---|---|---|
| `-t` | `--token` | توکن ربات تلگرام | — |
| `-c` | `--chat-id` | چت آی‌دی مقصد | — |
| `-d` | `--databases` | دیتابیس‌ها با کاما، یا `all` | — |
| `-m` | `--minutes` | فاصله ارسال به دقیقه (`0` = یک بار) | `0` |
| `-u` | `--db-user` | کاربر MySQL | `root` |
| `-p` | `--db-pass` | پسورد MySQL | خالی |
| `-H` | `--db-host` | هاست دیتابیس | `127.0.0.1` |
| `-P` | `--db-port` | پورت دیتابیس | `3306` |
| `-o` | `--out` | پوشه بکاپ | `/var/backups/mysql-tg` |
| `-s` | `--part-size` | حجم هر پارت | `45m` |
| `-z` | `--zip-pass` | رمز فایل zip | خالی |
| `-k` | `--keep-days` | نگهداری بکاپ محلی (روز) | `3` |
| `-f` | `--config` | مسیر فایل کانفیگ | — |
| `-h` | `--help` | راهنما | — |

> پارامترهای خط فرمان همیشه بر مقادیر فایل کانفیگ اولویت دارند.

</div>

<div dir="rtl">

## 📦 بازیابی بکاپ

### وقتی فایل یک‌تکه است

فایل `dbname_تاریخ.zip` را از تلگرام دانلود کنید:

</div>

```bash
unzip mydb_2026-09-12_10-00-00.zip
mysql -u root -p mydb < mydb_2026-09-12_10-00-00.sql
```

<div dir="rtl">

> چون بکاپ با `--databases` گرفته می‌شود، دستور `CREATE DATABASE` داخل فایل هست و می‌توانید بنویسید:
> `mysql -u root -p < backup.sql`

### وقتی بکاپ چند پارت است

همه‌ی پارت‌ها (`.zip.001.part` ، `.zip.002.part` و …) را در **یک پوشه** دانلود کنید:

**لینوکس / مک:**

</div>

```bash
cat mydb_2026-09-12_10-00-00.zip.*.part > mydb.zip
unzip mydb.zip
mysql -u root -p < mydb_2026-09-12_10-00-00.sql
```

<div dir="rtl">

**ویندوز (CMD):**

</div>

```cmd
copy /b mydb_...zip.001.part+mydb_...zip.002.part+mydb_...zip.003.part mydb.zip
```

<div dir="rtl">

**ویندوز (PowerShell):**

</div>

```powershell
cmd /c copy /b ((Get-ChildItem *.part | Sort-Object Name).Name -join '+') mydb.zip
```

<div dir="rtl">

## 🔧 عیب‌یابی

<details>
<summary><b>پیام تست تلگرام ارسال نمی‌شود</b></summary>

- مطمئن شوید به ربات `/start` داده‌اید
- توکن را با این دستور تست کنید: `curl https://api.telegram.org/bot<TOKEN>/getMe`
- اگر سرور ایران است و به API تلگرام دسترسی ندارد، باید پروکسی ست کنید. مقدار `TG_API` را در کانفیگ به آدرس ریورس‌پروکسی خودتان تغییر دهید، یا برای curl پروکسی سیستمی تعریف کنید:

```
# در /etc/systemd/system/mysql-tg-backup.service زیر [Service]
Environment=ALL_PROXY=socks5h://127.0.0.1:1080
```
سپس: `systemctl daemon-reload && systemctl restart mysql-tg-backup`
</details>

<details>
<summary><b>خطای Access denied هنگام بکاپ</b></summary>

کاربر دسترسی کافی ندارد. گرنت‌های بخش «ساخت کاربر دیتابیس» را اجرا کنید، یا موقتاً از `root` استفاده کنید.
</details>

<details>
<summary><b>خطای Access denied for PROCESS privilege</b></summary>

اسکریپت خودش `--no-tablespaces` را اضافه می‌کند اگر پشتیبانی شود. اگر باز هم خطا داد، گرنت `PROCESS` را بدهید.
</details>

<details>
<summary><b>تلگرام فایل را رد می‌کند (Request Entity Too Large)</b></summary>

مقدار `PART_SIZE` را کمتر کنید، مثلاً `40m`، و سرویس را ری‌استارت کنید.
</details>

<details>
<summary><b>سرویس بالا نمی‌آید</b></summary>

```bash
journalctl -u mysql-tg-backup -n 50 --no-pager
```
</details>

</div>

<div dir="rtl">

## 🗑 حذف کامل

</div>

```bash
sudo bash install.sh --uninstall
```

<div dir="rtl">

## 🔄 آپدیت

</div>

```bash
sudo bash install.sh --update
```

<div dir="rtl">

## ⚠️ نکات امنیتی

- فایل `/etc/mysql-tg-backup.conf` شامل پسورد دیتابیس و توکن رباتتان است؛ پرمیشن آن `600` است، آن را تغییر ندهید.
- **بکاپ دیتابیس رمزنگاری‌نشده در تلگرام ذخیره می‌شود.** اگر داده حساس دارید حتماً `ZIP_PASSWORD` را ست کنید.
- بکاپ را در یک کانال **خصوصی** بفرستید، نه گروه عمومی.
- توکن ربات را داخل ریپازیتوری یا اسکرین‌شات منتشر نکنید. اگر لو رفت، در BotFather با `/revoke` باطلش کنید.

</div>

<div dir="rtl">

## 📁 ساختار ریپازیتوری

</div>

```
mysql-Baclup/
├── mysql-telegram-backup.sh   # اسکریپت اصلی بکاپ
├── install.sh                 # نصب‌کننده
└── README.md
```

<div dir="rtl">

## 📄 لایسنس

MIT

</div>
