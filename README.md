# gaming-dns

DNS با کمترین پینگ برای سرورهای گیمینگ Xray (PasarGuard، Marzban، 3x-ui) روی **Debian و Ubuntu**.

اسکریپت [SmartDNS](https://github.com/pymumu/smartdns) را DNS خود سرور می‌کند. هر دامنه هم‌زمان از گوگل (`8.8.8.8`، `8.8.4.4`) و Gcore (`95.85.95.85`، `2.56.220.2`) پرسیده می‌شود، همه IPهایی که برمی‌گردند **از دید همین سرور** پینگ می‌شوند و فقط سریع‌ترین IP به Xray داده می‌شود. کوئری‌های DNS کاربرها هم که از داخل تانل به سرور می‌رسند همین جواب را می‌گیرند. در نتیجه بازی، لانچر و CDN همیشه به نزدیک‌ترین IP به سرور وصل می‌شوند.

## امکانات

- **سریع‌ترین IP از دید سرور**: پینگ ICMP، و اگر جواب نداد handshake روی TCP 443/80. جواب همه اپ‌استریم‌ها با هم مقایسه می‌شود. مثلاً برای Riot، گوگل CloudFront (حدود ۹ms) و Gcore کلودفلر (۱.۶ms) برمی‌گرداند و کلودفلر انتخاب می‌شود
- **ریدایرکت DNS کاربرها**: کوئری‌هایی که Xray یا کلاینت‌ها روی UDP 53 به هر سروری (1.1.1.1، 8.8.8.8 و...) می‌فرستند، جوابشان را از SmartDNS می‌گیرند. تشخیص از روی هدر DNS است، پس **تانل‌های VPN که روی پورت ۵۳ کار می‌کنند دست‌نخورده می‌مانند**
- **کش سریع**: جواب کش‌شده زیر ۱ میلی‌ثانیه (p99 حدود ۲.۶ms زیر بار واقعی)، prefetch دامنه‌های پرکاربرد، و اندازه‌گیری دوباره سریع‌ترین IP حداقل هر ۱۰ دقیقه. TTL جواب به کلاینت حداکثر ۳۰ ثانیه است تا تغییر مسیرها زود اعمال شود
- **اپ‌استریم روی TCP پایدار**: گوگل و Gcore زیر بار جواب UDP را truncate می‌کنند و SmartDNS آن را به جواب خالی تبدیل می‌کند. اتصال TCP دائمی این مشکل را ندارد و تأخیر اضافه هم ندارد
- **حذف ipv4hint از رکوردهای HTTPS**: گوشی‌ها و مرورگرهای جدید رکورد HTTPS (type 65) را هم می‌پرسند. IPهای داخل آن اندازه‌گیری نشده‌اند، پس حذف می‌شوند (ALPN و HTTP/3 می‌ماند) تا کلاینت به همان IP انتخاب‌شده وصل شود
- **EDNS Client Subnet** با رنج /24 خود سرور، تا CDNها جواب نزدیک به سرور بدهند
- **IPv6 بی‌خطر**: رکورد A همیشه برمی‌گردد و AAAA فقط وقتی IPv6 سریع‌تر باشد. کلاینت بدون IPv6 هیچ‌وقت بی‌جواب نمی‌ماند
- **بار کمتر روی conntrack**: کوئری‌های DNS لوکال (Xray به SmartDNS، چند صد در ثانیه) از conntrack رد نمی‌شوند
- **واچ‌داگ با fail-open**: هر ۳۰ ثانیه سلامت چک می‌شود. اگر SmartDNS جواب ندهد ری‌استارت می‌شود، و اگر باز هم جواب ندهد یا مدام جواب خالی بدهد، سرور خودکار به DNS قبلی‌اش برمی‌گردد و هر ۵ دقیقه دوباره امتحان می‌کند
- **امن**: SmartDNS فقط روی loopback گوش می‌دهد و از بیرون DNS باز (open resolver) نیست
- **دانلود تأییدشده**: SmartDNS از ریلیز رسمی گیت‌هاب دانلود و sha256 آن چک می‌شود
- **مستقل از پنل**: با هر پنلی که Xray را روی خود سرور یا در داکر با `network_mode: host` اجرا می‌کند کار می‌کند
- **حذف کامل**: `uninstall` همه‌چیز را پاک می‌کند و DNS سرور را به حالت قبل برمی‌گرداند

## پیش‌نیازها

- Debian 11+ یا Ubuntu 20.04+ با systemd و دسترسی root
- معماری x86_64، arm64، armv7 یا x86
- iptables با جدول nat (همه VPSهای KVM؛ روی OpenVZ/LXC ممکن است ریدایرکت کار نکند)
- پکیج‌های `dnsutils`، `iptables`، `curl`، `iputils-ping`، `iproute2`، `conntrack` و `jq` در صورت نبودن خودکار نصب می‌شوند

## نصب

روی سرور خارج (همان سروری که Xray رویش است) با کاربر root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xmohammad1/Gaming-DNS/main/gaming-dns.sh) install
```

با کاربر غیر root:

```bash
curl -fsSL https://raw.githubusercontent.com/xmohammad1/Gaming-DNS/main/gaming-dns.sh | sudo bash -s -- install
```

اسکریپت خودش را در `/usr/local/bin/gaming-dns` نصب می‌کند و از آن به بعد کافی است `gaming-dns` بزنید. آخر نصب خلاصه وضعیت چاپ می‌شود. نتیجه را با `gaming-dns test` ببینید.

موقع جابه‌جایی از systemd-resolved به SmartDNS، DNS سرور حدود ۱ تا ۲ ثانیه قطع می‌شود. اگر SmartDNS بالا نیاید، تنظیمات قبلی خودکار برمی‌گردد.

گزینه‌ها را می‌شود به آخر همان دستور اضافه کرد، مثلاً فقط IPv4:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xmohammad1/Gaming-DNS/main/gaming-dns.sh) install --ipv6 off
```

اگر سرور به GitHub دسترسی ندارد، فایل `gaming-dns.sh` را دستی روی سرور کپی کنید، فایل `smartdns.*.x86_64-debian-all.deb` را از [ریلیزهای SmartDNS](https://github.com/pymumu/smartdns/releases) بگیرید و اجرا کنید:

```bash
bash gaming-dns.sh install --deb smartdns.1.2026.08.05-0921.x86_64-debian-all.deb
```

### آپدیت

همان دستور نصب را دوباره اجرا کنید. تنظیمات قبلی (`/etc/gaming-dns/gaming-dns.conf`) حفظ می‌شود. برای آپدیت خود SmartDNS:

```bash
gaming-dns update
```

## تست

```bash
gaming-dns test valorant.secure.dyn.riotcdn.net cdn.discordapp.com
```

```
valorant.secure.dyn.riotcdn.net  (2 unique IPs from upstreams)
  172.64.153.253       1.6 ms  icmp     <- returned to Xray
  104.18.34.3          2.5 ms  icmp
  OK: the fastest IP is the one Xray receives

cdn.discordapp.com  (5 unique IPs from upstreams)
  162.159.133.233      1.4 ms  icmp
  162.159.135.233      1.5 ms  icmp     <- returned to Xray
  162.159.130.233      1.9 ms  icmp
  162.159.134.233      2.5 ms  icmp
  162.159.129.233      2.7 ms  icmp
  OK: the fastest IP is the one Xray receives
```

همه IPهایی که اپ‌استریم‌ها برمی‌گردانند با کمترین پینگ از چند تلاش اندازه‌گیری می‌شوند و IPی که به Xray داده شده علامت می‌خورد. اختلاف کمتر از حدود ۱ میلی‌ثانیه بین IPهای یک CDN نویز اندازه‌گیری است. بدون دامنه، چند دامنه گیمینگ پیش‌فرض تست می‌شوند.

## تنظیمات Xray (اختیاری)

با ریدایرکت (پیش‌فرض) لازم نیست چیزی در پنل عوض شود. این دو تنظیم پیشنهاد می‌شوند و `gaming-dns xray` هم همین‌ها را چاپ می‌کند.

**DNS خود Xray** در کانفیگ هسته (PasarGuard / Marzban: Settings ← Core):

```json
"dns": {
  "servers": ["localhost"],
  "queryStrategy": "UseIPv4",
  "disableCache": true
}
```

`localhost` یعنی DNS خود سرور، یعنی SmartDNS. روی نودهایی که gaming-dns ندارند هم با DNS خودشان کار می‌کند. با `disableCache` هر بار از SmartDNS پرسیده می‌شود و همیشه سریع‌ترین IP فعلی برمی‌گردد. در این بخش از DoH و DoT (`https://`، `tls://`) استفاده نکنید، چون DNS رمزشده ریدایرکت نمی‌شود.

**Sniffing** در اینباندها: کاربرانی که روی گوشی Private DNS یا DoH دارند، دامنه را خودشان resolve می‌کنند و فقط IP به Xray می‌فرستند. با sniffing، Xray دامنه واقعی را از SNI، Host یا QUIC می‌خواند و از SmartDNS می‌پرسد:

```json
"sniffing": {
  "enabled": true,
  "destOverride": ["http", "tls", "quic"],
  "routeOnly": false
}
```

ترافیک UDP خود بازی دامنه ندارد و sniffing رویش اثری ندارد.

## دستورات

| دستور | کار |
|---|---|
| `gaming-dns status` | وضعیت SmartDNS، ریدایرکت، conntrack، واچ‌داگ و رویدادهای اخیر |
| `gaming-dns test [domain...]` | همه IPهای دامنه، پینگ هرکدام و IPی که Xray می‌گیرد |
| `gaming-dns apply [options]` | اعمال دوباره تنظیمات، یا تغییر آن‌ها با گزینه‌ها |
| `gaming-dns redirect on\|off` | روشن یا خاموش کردن ریدایرکت DNS کاربرها |
| `gaming-dns xray` | تنظیمات پیشنهادی Xray |
| `gaming-dns update` | آپدیت SmartDNS به آخرین نسخه |
| `gaming-dns uninstall [--purge\|--keep-smartdns]` | حذف کامل و برگشت DNS به حالت قبل |
| `gaming-dns help` | راهنمای کامل |

## گزینه‌ها

برای `install` و `apply`. تنظیمات در `/etc/gaming-dns/gaming-dns.conf` ذخیره می‌شود و دفعه بعد لازم نیست تکرار شود.

| گزینه | پیش‌فرض | توضیح |
|---|---|---|
| `--upstreams LIST` | `8.8.8.8,8.8.4.4,95.85.95.85,2.56.220.2` | DNSهای اپ‌استریم، جدا با کاما |
| `--mode MODE` | `fastest-ip` | `fastest-ip`: صبر برای همه تست‌ها و برگرداندن سریع‌ترین IP. `first-ping`: اولین IPی که جواب داد (اولین کوئری کمی سریع‌تر، انتخاب کمی ضعیف‌تر) |
| `--speed-check STR` | `ping,tcp:443,tcp:80` | روش اندازه‌گیری، به ترتیب اولویت |
| `--max-ips N` | `1` | تعداد IP در هر جواب (۱ تا ۱۶). با بیش از یک IP، بعضی کلاینت‌ها ترتیب را عوض می‌کنند و ممکن است IP کندتر را بردارند |
| `--ipv6 MODE` | `auto` | `auto`، `on`، یا `off` (فقط IPv4) |
| `--ecs VALUE` | `auto` | EDNS Client Subnet: `auto` (رنج /24 سرور)، `off` یا `<ip>/<prefix>` |
| `--reply-ttl SEC` | `30` | حداکثر TTL جواب به کلاینت |
| `--cache-size N` | `65536` | تعداد رکوردهای کش |
| `--no-redirect` / `--redirect` | روشن | ریدایرکت DNS کاربرها |
| `--deb FILE` | — | نصب SmartDNS از فایل deb محلی |

## نحوه کار

```
client ──tunnel──> Xray ──DNS query on UDP 53, any server──┐ (iptables redirect)
                    │                                      v
                    └──── resolve domain (localhost) ──> SmartDNS on 127.0.0.1
                                                           │ persistent TCP
                                       ┌───────────────────┴───────────────────┐
                                 Google 8.8.8.8 / 8.8.4.4          Gcore 95.85.95.85 / 2.56.220.2
                                                           │
                              ping every IP from this server -> fastest IP -> cache -> answer
```

- SmartDNS روی `127.0.0.1`، `127.0.0.53` و `::1` گوش می‌دهد. `127.0.0.53` آدرس قبلی systemd-resolved است که کانتینرهای داکر (مثل نود PasarGuard) در `resolv.conf` خودشان کپی کرده‌اند، پس بدون ری‌استارت کانتینر کار می‌کند
- stub لیسنر systemd-resolved خاموش می‌شود و `/etc/resolv.conf` به `127.0.0.1` اشاره می‌کند
- ریدایرکت در chain `GAMING_DNS` جدول nat است و فقط پکت‌های UDP 53 را می‌گیرد که هدرشان DNS query است (ماژول u32). TCP دست نمی‌خورد، چون اولین پکتش محتوایی برای تشخیص ندارد. کوئری‌های خود SmartDNS با mark از ریدایرکت رد می‌شوند
- بای‌پس conntrack برای DNS لوکال در chain `GAMING_DNS_RAW` جدول raw است
- قوانین iptables با سرویس `gaming-dns-firewall` بعد از هر بوت دوباره اعمال می‌شوند و واچ‌داگ اگر پاک شده باشند (مثلاً با reload فایروال) برشان می‌گرداند

## فایل‌ها

| مسیر | محتوا |
|---|---|
| `/usr/local/bin/gaming-dns` | خود اسکریپت |
| `/etc/gaming-dns/gaming-dns.conf` | تنظیمات |
| `/etc/smartdns/smartdns.conf` | کانفیگ SmartDNS که از روی تنظیمات ساخته می‌شود (دستی ویرایش نکنید) |
| `/etc/systemd/resolved.conf.d/90-gaming-dns.conf` | خاموش کردن stub لیسنر systemd-resolved |
| `/etc/systemd/system/smartdns.service.d/90-gaming-dns.conf` | بالا آمدن SmartDNS قبل از داکر |
| `/etc/systemd/system/gaming-dns-firewall.service` | اعمال قوانین iptables بعد از بوت |
| `/etc/systemd/system/gaming-dns-watchdog.timer` | واچ‌داگ هر ۳۰ ثانیه |
| `/var/lib/gaming-dns/backup/` | بکاپ تنظیمات DNS قبلی، برای uninstall و fail-open |
| `/var/log/smartdns/smartdns.log` | لاگ SmartDNS |

رویدادهای واچ‌داگ در journal ثبت می‌شوند: `journalctl -t gaming-dns`

## پخش پردازش پکت‌ها بین هسته‌ها (rps-tune، اختیاری)

روی خیلی از VPSها کارت شبکه (virtio_net) فقط یک صف دریافت دارد و همه پکت‌های ورودی روی یک هسته پردازش می‌شوند. زیر بار همان هسته گلوگاه می‌شود و پینگ و jitter بالا می‌رود. `rps-tune` با RPS/RFS این کار را بین همه هسته‌ها پخش می‌کند و هر اتصال را به هسته‌ای می‌فرستد که ترد Xray همان اتصال رویش است.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xmohammad1/Gaming-DNS/main/rps-tune.sh) install
```

نمونه روی یک سرور ۴ هسته‌ای با ۳۴ هزار پکت در ثانیه: بار پردازش پکت روی هسته شلوغ از ۳۸.۶٪ به ۲۲.۸٪ رسید و بقیه هسته‌ها از حدود ۱.۵٪ به ۱۵٪، بدون افزایش مصرف کل CPU.

| دستور | کار |
|---|---|
| `rps-tune status` | تنظیمات و بار پردازش پکت هر هسته |
| `rps-tune remove` | برگشت به پیش‌فرض کرنل |

تنظیمات با سرویس `rps-tune` بعد از هر بوت دوباره اعمال می‌شود. اگر کارت شبکه به تعداد هسته‌ها صف سخت‌افزاری داشته باشد، rps-tune کاری نمی‌کند. تعداد صف‌ها را با `ethtool -l <interface>` ببینید.

## حذف

```bash
gaming-dns uninstall
```

همه سرویس‌ها و قوانین iptables حذف می‌شوند، `/etc/resolv.conf` و systemd-resolved به حالت قبل برمی‌گردند و پکیج SmartDNS، اگر خود اسکریپت نصبش کرده باشد، پاک می‌شود. با `--keep-smartdns` پکیج می‌ماند.
