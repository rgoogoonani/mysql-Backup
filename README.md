<div dir="rtl">

# 🗄 MySQL Telegram Backup

بکاپ خودکار از دیتابیس‌های MySQL / MariaDB، فشرده‌سازی با zip، تقسیم خودکار به پارت‌های زیر ۵۰ مگابایت و ارسال به تلگرام — مخصوص سرورهای اوبونتو.

</div>

<div dir="rtl">

## ✨ امکانات

- بکاپ از یک، چند یا **همه‌ی** دیتابیس‌ها (`all`)
- فشرده‌سازی با **7z** و تقسیم به والیوم‌های چندپارتی، دقیقاً مثل WinRAR — کافی است روی پارت اول دابل‌کلیک کنید، بقیه خودکار خوانده می‌شوند (بدون هیچ دستور CMD)
- پشتیبانی از **رمز روی فایل آرشیو** (حتی رمزگذاری لیست فایل‌ها)
- تقسیم خودکار به پارت‌های ۴۵ مگابایتی وقتی فایل از سقف ربات تلگرام بزرگ‌تر است
- ساخت خودکار کاربر `backup` با **پسورد تصادفی** و کمترین دسترسی لازم
- پشتیبانی از **پروکسی HTTP و SOCKS5** برای سرورهایی که به تلگرام دسترسی مستقیم ندارند (ایران)
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
- بسته‌های `mysql-client` ، `7zip` ، `zip` ، `curl` (اسکریپت نصب خودش نصب می‌کند)
- روی ویندوز برای باز کردن بکاپ: **WinRAR** یا **7-Zip**

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

## 👤 مرحله ۲ — کاربر دیتابیس (خودکار)

لازم نیست کاری بکنید. اسکریپت نصب موقع اجرا می‌پرسد و اگر تأیید کنید:

- یک کاربر به نام `backup` می‌سازد
- برایش یک **پسورد تصادفی ۲۸ کاراکتری** تولید می‌کند
- فقط دسترسی‌های لازم برای بکاپ را به آن می‌دهد (نه دسترسی نوشتن یا حذف)
- پسورد را در `/etc/mysql-tg-backup.conf` با پرمیشن `600` ذخیره می‌کند — لازم نیست حفظش کنید

برای ساخت کاربر یک‌بار به دسترسی ادمین نیاز است: اگر روی سرور با `root` لاگین باشید معمولاً از طریق سوکت لوکال خودکار وصل می‌شود، وگرنه یک بار پسورد root دیتابیس را می‌پرسد و **جایی ذخیره نمی‌کند**.

دستوری که پشت صحنه اجرا می‌شود:

</div>

```sql
CREATE USER IF NOT EXISTS 'backup'@'localhost' IDENTIFIED BY '<پسورد تصادفی>';
GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER, RELOAD, PROCESS,
      REPLICATION CLIENT ON *.* TO 'backup'@'localhost';
FLUSH PRIVILEGES;
```

<div dir="rtl">

> کاربر برای هر دو هاست `localhost` (اتصال سوکتی) و `127.0.0.1` (اتصال TCP) ساخته می‌شود.

</div>

<div dir="rtl">

## 🌐 مرحله ۳ — پروکسی (برای سرور ایران)

`api.telegram.org` از داخل ایران در دسترس نیست، پس سرور باید از یک پروکسی رد شود. اسکریپت نصب در همان ابتدا می‌پرسد:

```
  1) بدون پروکسی
  2) HTTP
  3) SOCKS5
```

بعد آدرس، پورت و در صورت نیاز یوزرنیم و پسورد را می‌گیرد، و **بلافاصله تست می‌کند** که از طریق آن پروکسی به تلگرام می‌رسد یا نه.

گزینه‌های رایج:

| حالت | چه بدهید |
|---|---|
| Xray/V2Ray لوکال روی همان سرور | SOCKS5 با `127.0.0.1` و پورت inbound شما (معمولاً `10808`) |
| سرور خارج خودتان | SOCKS5 یا HTTP با آی‌پی و پورت آن سرور + یوزر/پسورد |
| Squid / Privoxy لوکال | HTTP با `127.0.0.1` و پورت `8118` یا `3128` |
| سرور خارج از ایران | «بدون پروکسی» |

مقدار نهایی در کانفیگ به این شکل ذخیره می‌شود:

</div>

```bash
PROXY="socks5h://127.0.0.1:10808"
# یا
PROXY="http://user:pass@1.2.3.4:8080"
```

<div dir="rtl">

> در حالت SOCKS5 از `socks5h` استفاده می‌شود، یعنی رزولوشن DNS هم سمت پروکسی انجام می‌شود. این مهم است، چون در ایران خود DNS دامنه تلگرام هم دستکاری می‌شود.

بعد از نصب برای تغییر پروکسی:

</div>

```bash
sudo nano /etc/mysql-tg-backup.conf     # خط PROXY را عوض کنید
sudo systemctl restart mysql-tg-backup
```

<div dir="rtl">

**راه جایگزین — ریورس‌پروکسی:** اگر روی یک سرور خارج، ریورس‌پروکسی روی API تلگرام دارید، به‌جای PROXY می‌توانید آدرسش را بدهید:

</div>

```bash
TG_API="https://tg.example.com"
```

<div dir="rtl">

</div>

<div dir="rtl">

## 🚀 مرحله ۴ — نصب

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
| ساخت کاربر backup | پیشنهاد: بله — پسورد تصادفی می‌سازد |
| نام دیتابیس‌ها | مثلاً `wordpress,shop` یا `all` |
| فاصله زمانی | به دقیقه، مثلاً `60` |
| فرمت آرشیو | `7z` (پیشنهادی) یا `zip` |
| حجم هر پارت | پیش‌فرض `45m` |
| نگهداری بکاپ محلی | چند روز روی سرور بماند |
| پسورد آرشیو | خالی بگذارید اگر رمز نمی‌خواهید |

۴. اتصال به دیتابیس و ارسال پیام تست به تلگرام را چک می‌کند
۵. سرویس `systemd` را می‌سازد و اجرا می‌کند

</div>

<div dir="rtl">

## ⚙️ مرحله ۵ — استفاده

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
| `-a` | `--format` | فرمت آرشیو: `7z` یا `zip` | `7z` |
| `-z` | `--zip-pass` | رمز فایل آرشیو | خالی |
| `-k` | `--keep-days` | نگهداری بکاپ محلی (روز) | `3` |
| `-x` | `--proxy` | پروکسی تلگرام (`http://` یا `socks5h://`) | خالی |
| `-f` | `--config` | مسیر فایل کانفیگ | — |
| `-h` | `--help` | راهنما | — |

> پارامترهای خط فرمان همیشه بر مقادیر فایل کانفیگ اولویت دارند.

</div>

<div dir="rtl">

## 📦 بازیابی بکاپ

### وقتی فایل یک‌تکه است

فایل `dbname_تاریخ.7z` را دانلود کنید و در ویندوز با WinRAR یا 7-Zip باز کنید (Extract Here). بعد فایل `.sql` داخلش را برگردانید:

</div>

```bash
7z x mydb_2026-09-12_10-00-00.7z          # لینوکس
mysql -u root -p < mydb_2026-09-12_10-00-00.sql
```

<div dir="rtl">

> چون بکاپ با `--databases` گرفته می‌شود، دستور `CREATE DATABASE` داخل فایل هست و همان `mysql -u root -p < backup.sql` کافی است.

### وقتی بکاپ چند پارت است (فرمت 7z — پیش‌فرض)

بکاپ‌های چندپارتی به این شکل می‌آیند:

</div>

```
mydb_2026-09-12_10-00-00.7z.001
mydb_2026-09-12_10-00-00.7z.002
mydb_2026-09-12_10-00-00.7z.003
```

<div dir="rtl">

**ویندوز — بدون هیچ دستوری:**

۱. **همه‌ی** پارت‌ها را در **یک پوشه** دانلود کنید
۲. روی پارت اول یعنی `...7z.001` راست‌کلیک کنید
۳. WinRAR ‏← `Extract Here` (یا 7-Zip ‏← `Extract Here`)

همین. بقیه‌ی پارت‌ها خودکار خوانده می‌شوند و فایل `.sql` کامل بیرون می‌آید. اگر پارتی کم باشد، خود WinRAR اسمش را به شما می‌گوید.

> ⚠️ فقط پارت اول را باز کنید، نه بقیه را. اسم فایل‌ها را هم عوض نکنید.

**لینوکس:**

</div>

```bash
7z x mydb_2026-09-12_10-00-00.7z.001
mysql -u root -p < mydb_2026-09-12_10-00-00.sql
```

<div dir="rtl">

### اگر فرمت zip را انتخاب کرده باشید

در حالت zip، پارت‌ها فایل خام هستند و باید اول به هم چسبانده شوند:

</div>

```bash
# لینوکس / مک
cat mydb_2026-09-12_10-00-00.zip.*.part > mydb.zip && unzip mydb.zip
```

```cmd
:: ویندوز
copy /b mydb_...zip.001.part+mydb_...zip.002.part mydb.zip
```

<div dir="rtl">

به همین دلیل فرمت `7z` پیش‌فرض است.

</div>

<div dir="rtl">

## 🔧 عیب‌یابی

<details>
<summary><b>پیام تست تلگرام ارسال نمی‌شود</b></summary>

- مطمئن شوید به ربات `/start` داده‌اید
- توکن را با این دستور تست کنید: `curl https://api.telegram.org/bot<TOKEN>/getMe`
- اگر سرور ایران است: خط `PROXY` را در `/etc/mysql-tg-backup.conf` ست کنید و سرویس را ری‌استارت کنید. تست دستی از روی سرور:

```bash
source /etc/mysql-tg-backup.conf
curl --proxy "$PROXY" "https://api.telegram.org/bot$BOT_TOKEN/getMe"
```
اگر این دستور جواب `"ok":true` نداد، مشکل از پروکسی یا توکن است نه از اسکریپت.
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
<summary><b>فایل‌ها به‌جای 7z با پسوند zip می‌آیند</b></summary>

یعنی 7zip روی سرور نصب نشده و اسکریپت به zip برگشته:

```bash
sudo apt install -y 7zip || sudo apt install -y p7zip-full
sudo sed -i 's/^ARCHIVE_FORMAT=.*/ARCHIVE_FORMAT="7z"/' /etc/mysql-tg-backup.conf
sudo systemctl restart mysql-tg-backup
```
</details>

<details>
<summary><b>پسورد کاربر backup را گم کرده‌ام</b></summary>

پسورد داخل کانفیگ است: `sudo grep DB_PASS /etc/mysql-tg-backup.conf`
برای عوض کردنش، `sudo bash install.sh` را دوباره اجرا کنید و بازنویسی کانفیگ را تأیید کنید.
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
- **بکاپ دیتابیس رمزنگاری‌نشده در تلگرام ذخیره می‌شود.** اگر داده حساس دارید حتماً `ZIP_PASSWORD` را ست کنید (در فرمت 7z با `-mhe=on` حتی نام فایل‌ها هم رمز می‌شود).
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
