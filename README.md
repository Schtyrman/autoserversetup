# 🛡️ super-vpn-init — базовая настройка VPS под VPN

Bash-скрипт для автоматической первичной настройки сервера **Debian / Ubuntu** под VPN: создаёт admin-пользователя, переносит SSH на случайный порт, ставит Fail2ban + UFW, включает автообновления с перезагрузкой и базовый hardening ядра.

> Идеальная пара к [autoXRAY](https://github.com/xVRVx/autoXRAY): сначала `super-vpn-init` (база и безопасность), затем `autoXRAY2.sh` (VLESS XHTTP/RAW, Hysteria2, Web Proxy TG).

---

## ✨ Что делает скрипт

- Определяет ОС (только Debian/Ubuntu), обновляет систему (`apt update + upgrade`)
- Создаёт admin-пользователя с `sudo` (имя и пароль — с клавиатуры или через env)
- Меняет пароль `root`, отключает вход `root` по SSH (`PermitRootLogin no`)
- Переводит SSH на случайный порт **10001–65535** (или заданный), корректно обрабатывает `ssh.socket` на Ubuntu 24.04+
- Устанавливает и настраивает **rsyslog + Fail2ban** (`jail.local` под ТЗ, плюс джайл `recidive`)
- Настраивает **UFW**: только нужные порты (SSH, 80, 443, 8442/8443/10443, 51820 AmneziaWG/WireGuard, 8888 MTProto)
- Применяет **sysctl hardening** + BBR/TCP-буферы (как в autoXRAY) + `limits nofile`
- Включает **автообновления еженедельно** (воскресенье 05:00) с перезагрузкой при необходимости в 05:00
- Дополнительно: **chrony/NTP**, **auditd**, **sudo timeout**, **aging паролей**, **needrestart auto-restart**, SSH-баннер, `ufw logging`
- Запрашивает **статичный IP** и **DNS-домен**, проверяет A-запись (как в autoXRAY)
- Все конфиги бэкапятся (`.bak.<дата>`) перед перезаписью, скрипт идемпотентен (можно запускать повторно)

---

## 📋 Требования

| Параметр | Значение |
| :--- | :--- |
| **ОС** | Чистый **Debian 12/13** или **Ubuntu 22.04/24.04** |
| **Доступ** | VPS с root-доступом, статический IP |
| **Домен** | Необязательно, но для VPN нужен: A-запись → IP сервера |
| **Порты** | Свободны 80, 443 (для будущих VPN-сервисов) |
| **Время** | ~5–10 минут (обновление + установка пакетов) |

---

## 🚀 Быстрый старт

### Вариант 1 — локально (рекомендуется для первого запуска)

```bash
sudo bash super-vpn-init-fixed.sh
```

Скрипт спросит по очереди: IP → домен → имя пользователя → пароли → часовой пояс. SSH-порт сгенерируется случайно.

### Вариант 2 — одной командой как autoXRAY

После загрузки скрипта в этот репозиторий (ветка `main`):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/super-vpn-init-fixed.sh)" -- вашДОМЕН.com
```

Необязательно: 2-й аргумент — имя пользователя, 3-й — порт SSH:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/super-vpn-init-fixed.sh)" -- вашДОМЕН.com myadmin 23456
```

Пароли передавайте **только через env** (аргументы видны в `ps aux`):

```bash
export USER_PASS='пароль_мин8' ROOT_PASS='пароль_root_мин8'
bash -c "$(curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/super-vpn-init-fixed.sh)" -- вашДОМЕН.com
```

> ⚠️ **Безопасность `curl | bash`:** проверяйте скрипт перед запуском (`curl -fsSL ... | head -n 50`), используйте `-fsSL`, по возможности пините коммит-хэш вместо `main`. Не запускайте вслепую чужие one-liner под root.

---

## ⚙️ Параметры

### Аргументы (позиционные, как в autoXRAY)

| Арг | Назначение | Пример |
| :--- | :--- | :--- |
| `$1` | Домен **или** IP | `vpn.example.com` |
| `$2` | Имя admin-пользователя | `myadmin` |
| `$3` | Порт SSH (10001–65535) | `23456` |

### Env-переменные (приоритет выше аргументов)

| Переменная | Назначение |
| :--- | :--- |
| `SERVER_IP` | Статический IP сервера |
| `SERVER_DOMAIN` | DNS-домен (FQDN) |
| `NEW_USER` | Имя admin-пользователя |
| `USER_PASS` | Пароль admin-пользователя (мин. 8, без `:`) |
| `ROOT_PASS` | Новый пароль root (мин. 8, без `:`) |
| `SSH_PORT` | Порт SSH (10001–65535) |
| `TZ_NAME` | Часовой пояс, напр. `Europe/Moscow` |

Пример полностью неинтерактивного запуска:

```bash
export SERVER_IP=1.2.3.4 SERVER_DOMAIN=vpn.example.com NEW_USER=myadmin \
       USER_PASS='...' ROOT_PASS='...' SSH_PORT=23456 TZ_NAME=Europe/Moscow
sudo bash super-vpn-init-fixed.sh
```

---

## 🔧 Что именно настраивается

### SSH (`/etc/ssh/sshd_config.d/99-hardening.conf`)

```
Port <случайный 10001-65535>
PermitRootLogin no
AllowUsers <новый пользователь>
PasswordAuthentication yes
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 60
X11Forwarding no
Banner /etc/issue.net
```

- Отключается `ssh.socket` (Ubuntu 24.04+), включается `ssh.service` — иначе порт из конфига игнорируется.
- Эффективный порт проверяется через `sshd -T`.

### Fail2ban (`/etc/fail2ban/jail.local`)

```ini
[DEFAULT]
bantime = 10m
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = <случайный SSH-порт>
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 1h
findtime = 10m
```

Плюс джайл `[recidive]` (бан на неделю для повторных нарушителей).

### UFW — открытые порты

| Порт | Протокол | Назначение |
| :--- | :--- | :--- |
| SSH (случайный) | tcp (`limit`) | Вход, rate-limit против перебора |
| 80 | tcp | HTTP / ACME |
| 443 | tcp | HTTPS / VLESS XHTTP+RAW |
| 443 | udp | Hysteria2 / QUIC |
| 8442, 8443, 10443 | tcp+udp | Резерв / веб-портал |
| 51820 | udp | WireGuard / AmneziaWG |
| 51821 | udp | AmneziaWG (альт.) |
| 8888 | tcp | MTProto proxy |

Всё остальное — `deny incoming`. `ufw allow OpenSSH` (порт 22) **не открывается** — иначе конфликт со случайным портом.

### Автообновления

- `Update-Package-Lists "7"` — списки раз в неделю
- Таймер `apt-daily-upgrade.timer` → **воскресенье 05:00** (по серверному времени)
- `Automatic-Reboot "true"`, `Automatic-Reboot-Time "05:00"` — ребут только если обновление требует (ядро)
- `Remove-Unused-Dependencies/Kernel-Packages "true"` — чистка старых ядер

> ⚠️ Еженедельные обновления задерживают security-патчи до 7 дней. Для продакшена безопаснее ежедневно:
> ```bash
> sed -i 's/Update-Package-Lists "7"/Update-Package-Lists "1"/' /etc/apt/apt.conf.d/20auto-upgrades
> ```

### Дополнительно по безопасности

- **chrony** (NTP) + `timedatectl set-ntp`
- **auditd** + правила на `passwd/shadow/sshd_config/sudoers`
- **sudo timeout 5 мин** (`/etc/sudoers.d/99-admin-timeout`)
- **Aging паролей:** смена раз в 90 дней (`chage -M 90`)
- **needrestart** auto-restart после обновления ядра
- **sysctl:** `rp_filter=2` (loose — strict ломает VPN), `kptr_restrict=2`, `randomize_va_space=2`, BBR (если доступен), TCP-буферы 16 МБ
- **limits:** `nofile 1048576` (для Xray)

---

## ✅ Проверка после установки

```bash
# SSH: эффективный порт и запрет root
sshd -T | grep -iE '^(port|permitrootlogin|allowusers)'

# Файрвол
ufw status verbose

# Fail2ban
fail2ban-client status sshd

# Автообновления
systemctl status apt-daily-upgrade.timer unattended-upgrades
systemctl list-timers apt-daily-upgrade.timer

# BBR
sysctl net.ipv4.tcp_congestion_control
```

Подключение (скрипт выведет точную команду в финале):

```bash
ssh -p <SSH-порт> <пользователь>@<домен-или-IP>
```

> 🔴 **Не закрывайте текущую SSH-сессию**, пока не проверите вход под новым пользователем в **новом** окне терминала.

---

## 🔗 Следующие шаги (VPN)

После базы — поставьте VPN одной командой (пример — autoXRAY для VLESS):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/xVRVx/autoXRAY/main/autoXRAY2.sh)" -- вашДОМЕН.com
```

- **AmneziaWG / WireGuard:** порт `51820/udp` уже открыт в UFW.
- **MTProto:** порт `8888/tcp` уже открыт (web MTProto — через `443`).
- **VLESS / Hysteria2:** порты `443/tcp+udp` уже открыты.

---

## 🛠️ Troubleshooting

| Симптом | Что проверить |
| :--- | :--- |
| `sshd -T` показывает порт 22 вместо случайного | `ssh.socket` не отключился: `systemctl status ssh.socket ssh.service`, проверьте `Include` в `sshd_config` |
| Не пускает по новому порту | `ss -ltnp \| grep <порт>`, `ufw status`, `journalctl -u ssh -n 50`. Не закрывайте старую сессию! |
| Fail2ban не банит | `fail2ban-client status sshd`, `tail /var/log/auth.log`, `journalctl -u fail2ban -n 50` |
| UFW заблокировал доступ | Подключитесь через консоль провайдера (VNC/Serial), выполните `ufw disable` или `ufw allow <порт>/tcp` |
| Автообновления не работают | `systemctl status unattended-upgrades`, `unattended-upgrade --dry-run --debug` |

---

## 📝 Changelog

- **v2.0-fixed** — исправлены: порядок `ufw reset/allow`, обработка `ssh.socket`, чтение через `/dev/tty` для `curl | bash`, bootstrap `curl` до определения IP, исключение зарезервированных портов, еженедельные обновления + ребут 05:00, `rp_filter=2`, `backend=auto` в Fail2ban, валидация IP/домена/паролей, бэкапы всех конфигов, `trap ERR`, доп. безопасность (chrony, auditd, sudo timeout, aging, needrestart).

## 📄 Лицензия

MIT — используйте и модифицируйте свободно. Скрипт запускается под root и меняет системные конфиги: тестируйте сначала на тестовом VPS.
