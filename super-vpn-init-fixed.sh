#!/usr/bin/env bash
# =============================================================================
# super-vpn-init.sh — базовая настройка VPS (Debian/Ubuntu) под VPN
# Версия: 2.0-fixed (исправленная)
#
# Что делает:
#   - определяет ОС, обновляет систему, ставит базовые пакеты
#   - создаёт admin-пользователя с sudo (имя/пароль — с клавиатуры или env)
#   - меняет пароль root, отключает вход root по SSH
#   - переводит SSH на случайный порт 10001-65535 (или заданный)
#   - ставит rsyslog + fail2ban (jail.local под ваш ТЗ)
#   - настраивает UFW: только нужные порты (SSH, 80, 443, 8442/8443/10443,
#     51820/udp AmneziaWG/WireGuard, 8888 MTProto, 443/udp Hysteria2)
#   - sysctl hardening + BBR/TCP-буферы (как в autoXRAY) + limits nofile
#   - unattended-upgrades: еженедельно, перезагрузка при необходимости в 05:00
#   - доп. безопасность: chrony/NTP, auditd, sudo timeout, aging паролей,
#     needrestart auto-restart, SSH banner, ufw logging, fail2ban recidive
#
# Запуск локально (на сервере, под root):
#   sudo bash super-vpn-init-fixed.sh
#
# Запуск одной командой как autoXRAY (после загрузки на GitHub):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/super-vpn-init-fixed.sh)" -- вашДОМЕН.com
#   # необязательно: 2-й аргумент — имя пользователя, 3-й — порт SSH:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/super-vpn-init-fixed.sh)" -- вашДОМЕН.com myadmin 23456
#   # пароли через env (не светятся в ps, в отличие от аргументов):
#   export USER_PASS='...' ROOT_PASS='...'
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/super-vpn-init-fixed.sh)" -- вашДОМЕН.com
#
# ВАЖНО:
#   - Сначала протестируйте на тестовом VPS/VM. Не закрывайте текущую
#     SSH-сессию, пока не проверите вход под новым пользователем в НОВОМ окне.
#   - Скрипт идемпотентен: можно запускать повторно, но пароли спросит снова.
#   - Все конфиги бэкапятся с суффиксом .bak.<дата> перед перезаписью.
# =============================================================================
set -euo pipefail
trap 'echo -e "\033[0;31m[ERROR]\033[0m Ошибка на строке $LINENO. Проверьте вывод выше." >&2' ERR

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()   { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()     { echo -e "${GREEN}[OK]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()    { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# --- Чтение с клавиатуры через /dev/tty (чтобы работало при curl | bash) ---
# При запуске вида bash -c "$(curl ...)" stdin занят скриптом, поэтому
# обычный `read` съедал бы строки скрипта. Все read ниже идут через /dev/tty.
TTY="/dev/tty"
if [[ ! -e "$TTY" ]]; then
    TTY="/dev/stdin"
fi
read_tty() {
    # $1 = prompt, $2 = varname, $3 = "s" для скрытого ввода (пароль)
    local prompt="$1" var="$2" mode="${3:-}"
    if [[ "$mode" == "s" ]]; then
        IFS= read -r -s -p "$prompt" "$var" < "$TTY" || die "Не удалось прочитать ввод (нет терминала?). Задайте пароли через env: USER_PASS, ROOT_PASS."
        echo >&2
    else
        IFS= read -r -p "$prompt" "$var" < "$TTY" || die "Не удалось прочитать ввод (нет терминала?). Задайте значения через аргументы/env."
    fi
}

[[ $EUID -eq 0 ]] || die "Запустите от root: sudo bash super-vpn-init-fixed.sh"

export DEBIAN_FRONTEND=noninteractive

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
else
    die "Не найден /etc/os-release"
fi

case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "Поддерживаются только Ubuntu и Debian. Обнаружено: ${ID:-unknown}" ;;
esac

info "Система: ${PRETTY_NAME:-$ID} (ID=$ID, CODENAME=${VERSION_CODENAME:-?})"
if [[ "$ID" == "ubuntu" ]]; then
    warn "Запуск на Ubuntu. Рекомендованная система для VPN: Debian 12/13 (как в autoXRAY)."
fi

# ---------- Аргументы / env (как в autoXRAY: $1 = домен) ----------
# Поддерживаются env-переменные: SERVER_IP, SERVER_DOMAIN, NEW_USER,
# USER_PASS, ROOT_PASS, SSH_PORT, TZ_NAME
ARG_DOMAIN="${1:-}"
ARG_USER="${2:-}"
ARG_PORT="${3:-}"

# ---------- Bootstrap: curl нужен для определения IP ----------
# В исходном скрипте IP определялся ДО установки curl — на чистой системе
# определение всегда падало в ручной ввод. Теперь ставим curl заранее.
if ! command -v curl >/dev/null 2>&1; then
    info "curl не найден — ставлю минимальный набор для определения IP..."
    dpkg --configure -a >/dev/null 2>&1 || true
    apt-get update -qq || true
    apt-get install -y -qq curl ca-certificates || die "Не удалось установить curl. Проверьте интернет/DNS."
fi

# ---------- IP и домен ----------
DETECTED_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true)"
DETECTED_IP="${DETECTED_IP:-}"

valid_ipv4() { [[ "$1" =~ ^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$ ]]; }
valid_domain() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; }

if [[ -n "${SERVER_IP:-}" ]]; then
    SERVER_IP="$SERVER_IP"
elif [[ -n "$ARG_DOMAIN" ]] && valid_ipv4 "$ARG_DOMAIN"; then
    SERVER_IP="$ARG_DOMAIN"
else
    read_tty "Внешний IP сервера [${DETECTED_IP:-не определён}]: " INPUT_IP
    SERVER_IP="${INPUT_IP:-$DETECTED_IP}"
fi
while ! valid_ipv4 "$SERVER_IP"; do
    warn "Некорректный IPv4: '$SERVER_IP'. Введите IPv4 вида 1.2.3.4"
    read_tty "Внешний IP сервера: " SERVER_IP
done
ok "IP сервера: $SERVER_IP"

if [[ -n "${SERVER_DOMAIN:-}" ]]; then
    SERVER_DOMAIN="$SERVER_DOMAIN"
elif [[ -n "$ARG_DOMAIN" ]] && ! valid_ipv4 "$ARG_DOMAIN"; then
    SERVER_DOMAIN="$ARG_DOMAIN"
else
    read_tty "DNS-домен сервера, если есть [можно оставить пустым]: " SERVER_DOMAIN
fi
if [[ -n "$SERVER_DOMAIN" ]] && ! valid_domain "$SERVER_DOMAIN"; then
    die "Некорректный домен: '$SERVER_DOMAIN'. Укажите FQDN вида vpn.example.com или оставьте пустым."
fi
CONNECT_HOST="${SERVER_DOMAIN:-$SERVER_IP}"
info "Хост для подключения: $CONNECT_HOST"

# Проверка DNS (как в autoXRAY): домен должен резолвиться в IP сервера
if [[ -n "$SERVER_DOMAIN" ]] && command -v dig >/dev/null 2>&1; then
    DNS_IP="$(dig +short "$SERVER_DOMAIN" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)"
    if [[ -n "$DNS_IP" && "$DNS_IP" != "$SERVER_IP" ]]; then
        warn "A-запись $SERVER_DOMAIN ($DNS_IP) не совпадает с IP сервера ($SERVER_IP)."
        read_tty "Продолжить на ваш страх и риск? (y/N): " DNS_CHOICE
        if [[ ! "${DNS_CHOICE,,}" =~ ^y ]]; then
            die "Прервано. Исправьте A-запись ($SERVER_DOMAIN -> $SERVER_IP) и запустите снова."
        fi
    elif [[ -z "$DNS_IP" ]]; then
        warn "Не удалось получить A-запись для $SERVER_DOMAIN (dig пуст). Проверьте DNS позже."
    else
        ok "DNS $SERVER_DOMAIN -> $DNS_IP совпадает с IP сервера."
    fi
fi

# ---------- Пользователь и пароли ----------
if [[ -n "${NEW_USER:-}" ]]; then
    NEW_USER="$NEW_USER"
elif [[ -n "$ARG_USER" ]]; then
    NEW_USER="$ARG_USER"
else
    NEW_USER=""
fi
while true; do
    if [[ -z "$NEW_USER" ]]; then
        read_tty "Имя нового администратора: " NEW_USER
    fi
    if [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$NEW_USER" != "root" ]]; then
        break
    fi
    warn "Имя: латиница, цифры, - или _; не root. Попробуйте ещё раз."
    NEW_USER=""
done

valid_pass() {
    # минимум 8 символов, без ':' (ломает chpasswd) и без перевода строки
    [[ ${#1} -ge 8 && "$1" != *:* && "$1" != *$'\n'* ]]
}

if [[ -n "${USER_PASS:-}" ]]; then
    valid_pass "$USER_PASS" || die "USER_PASS из env слишком короткий (<8) или содержит ':'. Задайте пароль длиннее 8 символов без ':'."
    info "Пароль для $NEW_USER взят из env USER_PASS."
else
    while true; do
        read_tty "Пароль для $NEW_USER (мин. 8 символов): " USER_PASS s
        read_tty "Повторите пароль: " USER_PASS2 s
        if valid_pass "$USER_PASS" && [[ "$USER_PASS" == "$USER_PASS2" ]]; then
            break
        fi
        warn "Пароли пустые/короткие/содержат ':' или не совпадают."
    done
    unset USER_PASS2
fi

if [[ -n "${ROOT_PASS:-}" ]]; then
    valid_pass "$ROOT_PASS" || die "ROOT_PASS из env слишком короткий (<8) или содержит ':'. Задайте пароль длиннее 8 символов без ':'."
    info "Пароль root взят из env ROOT_PASS."
else
    while true; do
        read_tty "Новый пароль root (мин. 8 символов): " ROOT_PASS s
        read_tty "Повторите пароль root: " ROOT_PASS2 s
        if valid_pass "$ROOT_PASS" && [[ "$ROOT_PASS" == "$ROOT_PASS2" ]]; then
            break
        fi
        warn "Пароли пустые/короткие/содержат ':' или не совпадают."
    done
    unset ROOT_PASS2
fi

# ---------- SSH-порт ----------
RESERVED_PORTS=(22 80 443 8442 8443 10443 51820 51821 8888)
pick_random_port() {
    local p
    while true; do
        p="$(shuf -i 10001-65535 -n 1)"
        local skip=0
        for rp in "${RESERVED_PORTS[@]}"; do
            [[ "$p" == "$rp" ]] && skip=1
        done
        [[ $skip -eq 0 ]] && { echo "$p"; return; }
    done
}

if [[ -n "${SSH_PORT:-}" ]]; then
    RANDOM_SSH_PORT="$SSH_PORT"
elif [[ -n "$ARG_PORT" ]]; then
    RANDOM_SSH_PORT="$ARG_PORT"
else
    RANDOM_SSH_PORT="$(pick_random_port)"
fi
if ! [[ "$RANDOM_SSH_PORT" =~ ^[0-9]+$ ]] || (( RANDOM_SSH_PORT < 10001 || RANDOM_SSH_PORT > 65535 )); then
    die "Некорректный SSH-порт: '$RANDOM_SSH_PORT'. Допустимо 10001-65535."
fi
for rp in "${RESERVED_PORTS[@]}"; do
    [[ "$RANDOM_SSH_PORT" == "$rp" ]] && die "SSH-порт $RANDOM_SSH_PORT зарезервирован для VPN/веба. Выберите другой."
done
if ss -ltn 2>/dev/null | grep -qE "[:.]${RANDOM_SSH_PORT}[[:space:]]"; then
    warn "Порт $RANDOM_SSH_PORT уже занят — подбираю другой."
    RANDOM_SSH_PORT="$(pick_random_port)"
fi
info "SSH будет переведён на порт $RANDOM_SSH_PORT"

# ---------- Часовой пояс (важно для перезагрузки в 05:00) ----------
if [[ -n "${TZ_NAME:-}" ]]; then
    TZ_INPUT="$TZ_NAME"
else
    CURRENT_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "Etc/UTC")"
    read_tty "Часовой пояс сервера [$CURRENT_TZ, Enter = оставить, например Europe/Moscow]: " TZ_INPUT
    TZ_INPUT="${TZ_INPUT:-$CURRENT_TZ}"
fi
if timedatectl list-timezones 2>/dev/null | grep -qx "$TZ_INPUT"; then
    timedatectl set-timezone "$TZ_INPUT" 2>/dev/null || warn "Не удалось сменить timezone на $TZ_INPUT."
    ok "Часовой пояс: $TZ_INPUT (перезагрузка в 05:00 будет по этому времени)"
else
    warn "Часовой пояс '$TZ_INPUT' не найден — оставляю текущий. Перезагрузка в 05:00 будет по серверному времени."
fi

# ---------- Обновление и пакеты ----------
info "Обновление системы (может занять несколько минут)..."
dpkg --configure -a >/dev/null 2>&1 || true
apt-get update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install --no-install-recommends \
    sudo curl wget ca-certificates gnupg lsb-release \
    openssh-server rsyslog fail2ban ufw unattended-upgrades \
    apt-listchanges needrestart cron jq qrencode \
    chrony auditd lynis htop vim tmux dnsutils net-tools iproute2
ok "Пакеты установлены."

# ---------- Пользователи ----------
echo "root:${ROOT_PASS}" | chpasswd
ok "Пароль root изменён."

if ! id "$NEW_USER" &>/dev/null; then
    useradd -m -s /bin/bash -c "Server admin" "$NEW_USER"
    ok "Пользователь $NEW_USER создан."
else
    warn "Пользователь $NEW_USER уже существует — обновляю пароль и права."
fi
echo "${NEW_USER}:${USER_PASS}" | chpasswd

if ! id -nG "$NEW_USER" | grep -qw sudo; then
    usermod -aG sudo "$NEW_USER"
fi
ok "Пользователь $NEW_USER в группе sudo."

# Срок действия пароля: смена раз в 90 дней (предупреждение за 7 дней)
chage -M 90 -m 1 -W 7 "$NEW_USER" 2>/dev/null || true

install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "/home/$NEW_USER/.ssh"
if [[ -f /root/.ssh/authorized_keys ]]; then
    cp /root/.ssh/authorized_keys "/home/$NEW_USER/.ssh/authorized_keys"
    chown "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh/authorized_keys"
    chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"
    ok "SSH-ключи root скопированы пользователю $NEW_USER."
else
    warn "У root нет authorized_keys: вход будет по паролю, пока вы не добавите ключ."
fi

# sudo: таймаут 5 минут (не хранить sudo-пароль в памяти вечно)
cat > /etc/sudoers.d/99-admin-timeout <<'EOF'
Defaults timestamp_timeout=5
EOF
chmod 440 /etc/sudoers.d/99-admin-timeout
visudo -cf /etc/sudoers.d/99-admin-timeout >/dev/null && ok "sudo timeout 5 мин настроен." || { warn "sudoers синтаксис неверен — удаляю файл."; rm -f /etc/sudoers.d/99-admin-timeout; }

# ---------- SSH ----------
SSHD_DIR=/etc/ssh/sshd_config.d
mkdir -p "$SSHD_DIR"
BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
cp -a /etc/ssh/sshd_config "$BACKUP" 2>/dev/null || true
info "Бэкап sshd_config: $BACKUP"

# Include должен быть в sshd_config, иначе drop-in игнорируется.
# Вставляем в начало, если отсутствует (первое значение побеждает).
if ! grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config; then
    warn "В sshd_config нет Include для sshd_config.d — добавляю в начало."
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi
# Комментируем Port в главном конфиге, чтобы drop-in точно победил.
sed -i -E 's/^Port[[:space:]]+/#Port /' /etc/ssh/sshd_config || true

# SSH-баннер (предупреждение для всех, кто стучится)
cat > /etc/issue.net <<'EOF'
Authorized access only. All activity is monitored and logged.
Несанкционированный доступ запрещён. Все действия записываются.
EOF
chmod 644 /etc/issue.net

cat > "$SSHD_DIR/99-hardening.conf" <<EOF
Port ${RANDOM_SSH_PORT}
PermitRootLogin no
AllowUsers ${NEW_USER}
PasswordAuthentication yes
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 60
ClientAliveInterval 300
ClientAliveCountMax 3
X11Forwarding no
Banner /etc/issue.net
EOF
chmod 600 "$SSHD_DIR/99-hardening.conf"

if ! sshd -t; then
    warn "Конфиг SSH некорректен — откатываю drop-in и остаюсь на порту 22."
    rm -f "$SSHD_DIR/99-hardening.conf"
    sshd -t || die "sshd -t падает даже без drop-in. Проверьте $BACKUP вручную."
    RANDOM_SSH_PORT=22
else
    EFFECTIVE_PORT="$(sshd -T 2>/dev/null | awk 'tolower($1)=="port"{print $2; exit}' || true)"
    if [[ "$EFFECTIVE_PORT" != "$RANDOM_SSH_PORT" ]]; then
        warn "sshd -T показывает порт ${EFFECTIVE_PORT:-?}, ожидался $RANDOM_SSH_PORT. Проверьте Include/Port в sshd_config."
    else
        ok "sshd -T подтверждает порт $RANDOM_SSH_PORT."
    fi
fi

# Если UFW уже включён (повторный запуск) — открываем новый порт ДО рестарта SSH,
# иначе можно потерять доступ в окно между рестартом и финальной настройкой UFW.
if command -v ufw >/dev/null 2>&1; then
    ufw allow "${RANDOM_SSH_PORT}/tcp" comment 'SSH custom port (pre-restart)' >/dev/null 2>&1 || true
fi

# Ubuntu 24.04+: ssh.socket (socket activation) игнорирует Port из sshd_config.
# Отключаем сокет и включаем обычный сервис, чтобы порт реально сменился.
if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    info "Обнаружена socket-активация SSH (ssh.socket) — отключаю её, чтобы вступил порт из sshd_config."
    systemctl disable --now ssh.socket >/dev/null 2>&1 || true
    systemctl enable --now ssh.service >/dev/null 2>&1 || systemctl enable --now ssh >/dev/null 2>&1 || true
    systemctl restart ssh.service >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1 || true
else
    systemctl enable --now ssh.service >/dev/null 2>&1 || systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
    systemctl restart ssh.service >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
fi

sleep 1
if ss -ltn 2>/dev/null | grep -qE "[:.]${RANDOM_SSH_PORT}[[:space:]]"; then
    ok "SSH слушает порт $RANDOM_SSH_PORT."
else
    warn "Порт $RANDOM_SSH_PORT пока не слушается. НЕ закрывайте текущую SSH-сессию! Проверьте: systemctl status ssh; journalctl -u ssh -n 50"
fi
ok "SSH настроен на порту $RANDOM_SSH_PORT, root-вход отключён."

# ---------- rsyslog и Fail2ban ----------
systemctl enable --now rsyslog >/dev/null 2>&1 || true

if [[ -f /etc/fail2ban/jail.local ]]; then
    cp -a /etc/fail2ban/jail.local "/etc/fail2ban/jail.local.bak.$(date +%Y%m%d%H%M%S)"
fi
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 10m
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1
backend = auto

[sshd]
enabled = true
port = ${RANDOM_SSH_PORT}
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 1h
findtime = 10m

[recidive]
enabled = true
filter = recidive
logpath = /var/log/auth.log
bantime = 1w
findtime = 1d
maxretry = 5
EOF

systemctl enable --now fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban >/dev/null 2>&1 || true
sleep 2
if fail2ban-client ping >/dev/null 2>&1; then
    ok "Fail2ban работает."
    fail2ban-client status sshd 2>/dev/null | head -n 5 || true
else
    warn "Fail2ban не ответил: проверьте journalctl -u fail2ban -n 50"
fi

# ---------- UFW ----------
# ВАЖНО (исправлен баг исходника): reset делается ПЕРВЫМ, затем правила,
# затем enable. В исходнике allow делался до reset и стирался им.
if command -v ufw >/dev/null 2>&1; then
    ufw status numbered > "/root/ufw-backup-$(date +%Y%m%d%H%M%S).txt" 2>/dev/null || true
    ufw --force reset >/dev/null
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw logging on >/dev/null 2>&1 || true

    # SSH — limit (rate limit), а не allow: защита от перебора в дополнение к fail2ban
    ufw limit "${RANDOM_SSH_PORT}/tcp" comment 'SSH' >/dev/null
    ufw allow 80/tcp comment 'HTTP / ACME' >/dev/null
    ufw allow 443/tcp comment 'HTTPS / VLESS XHTTP+RAW' >/dev/null
    ufw allow 443/udp comment 'Hysteria2 / QUIC' >/dev/null
    ufw allow 8442/tcp comment 'Reserved 8442' >/dev/null
    ufw allow 8442/udp comment 'Reserved 8442 udp' >/dev/null
    ufw allow 8443/tcp comment 'Web portal 8443' >/dev/null
    ufw allow 8443/udp comment 'Web portal 8443 udp' >/dev/null
    ufw allow 10443/tcp comment 'Reserved 10443' >/dev/null
    ufw allow 10443/udp comment 'Reserved 10443 udp' >/dev/null
    # Будущие VPN-сервисы
    ufw allow 51820/udp comment 'WireGuard / AmneziaWG' >/dev/null
    ufw allow 51821/udp comment 'AmneziaWG alt' >/dev/null
    ufw allow 8888/tcp comment 'MTProto proxy' >/dev/null

    ufw --force enable >/dev/null
    ufw status verbose
    ok "UFW включён: только нужные порты открыты."
else
    warn "ufw не найден — пропускаю настройку файрвола."
fi

# ---------- Ядро и безопасность (sysctl) ----------
if [[ -f /etc/sysctl.d/99-server-hardening.conf ]]; then
    cp -a /etc/sysctl.d/99-server-hardening.conf "/etc/sysctl.d/99-server-hardening.conf.bak.$(date +%Y%m%d%H%M%S)"
fi
# BBR доступен не во всех ядрах — проверяем перед записью
BBR_OK=0
if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    BBR_OK=1
else
    warn "BBR недоступен в ядре ($(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo '?')) — пропускаю BBR."
fi

cat > /etc/sysctl.d/99-server-hardening.conf <<EOF
# VPN: forwarding нужен для WireGuard/Xray. Если VPN не будет — поставьте 0.
net.ipv4.ip_forward = 1
net.ipv4.tcp_syncookies = 1
# rp_filter=2 (loose), а не 1 (strict): strict ломает VPN при асимметричной маршрутизации
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
# Hardening ядра
kernel.kptr_restrict = 2
kernel.randomize_va_space = 2
kernel.yama.ptrace_scope = 1
fs.suid_dumpable = 0
# Производительность сети (как в autoXRAY)
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
EOF
if [[ $BBR_OK -eq 1 ]]; then
    cat >> /etc/sysctl.d/99-server-hardening.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
fi
sysctl -p /etc/sysctl.d/99-server-hardening.conf >/dev/null 2>&1 || warn "sysctl -p вернул ошибку — проверьте /etc/sysctl.d/99-server-hardening.conf"
ok "sysctl hardening применён."

# Лимиты открытых файлов (нужно для Xray/большого числа соединений, как в autoXRAY)
cat > /etc/security/limits.d/99-server.conf <<'EOF'
*       soft    nofile  1048576
*       hard    nofile  1048576
root    soft    nofile  1048576
root    hard    nofile  1048576
EOF

# ---------- Автообновления: еженедельно + перезагрузка в 05:00 ----------
# ВНИМАНИЕ: еженедельные обновления задерживают security-патчи до 7 дней.
# Для продакшена безопаснее ежедневно. Чтобы переключить на ежедневно:
#   sed -i 's/Update-Package-Lists "7"/Update-Package-Lists "1"/' /etc/apt/apt.conf.d/20auto-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "7";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# ВАЖНО: heredoc с 'EOF' (в кавычках) — ${distro_id} НЕ разворачивается bash,
# их разворачивает сам unattended-upgrades. Не убирайте кавычки!
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id} ESMServices:${distro_codename}";
    "${distro_id} ESMApps:${distro_codename}-apps-security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "05:00";
EOF

# Таймер: апгрейд по воскресеньям в 05:00 (по серверному времени, см. timezone выше)
mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
cat > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=Sun 05:00
RandomizedDelaySec=0
Persistent=true
EOF
systemctl daemon-reload >/dev/null 2>&1 || true

echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections >/dev/null 2>&1 || true
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
ok "Автообновления: еженедельно (воскресенье 05:00), перезагрузка при необходимости в 05:00."

# needrestart: автоматически перезапускать сервисы после обновления ядра
if [[ -f /etc/needrestart/needrestart.conf ]]; then
    if grep -q "nrconf{restart}.*=.*'a'" /etc/needrestart/needrestart.conf; then
        ok "needrestart: auto-restart уже включён."
    else
        printf "%s\n" "\$nrconf{restart} = 'a';" >> /etc/needrestart/needrestart.conf
        ok "needrestart: auto-restart включён."
    fi
fi

# ---------- NTP, audit, cron ----------
systemctl enable --now chrony >/dev/null 2>&1 || systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
timedatectl set-ntp true >/dev/null 2>&1 || true
ok "NTP включён (chrony/timesyncd)."

systemctl enable --now cron >/dev/null 2>&1 || true

# auditd: базовые правила для SSH/идентичности (не фейлит скрипт, если недоступен)
if command -v auditd >/dev/null 2>&1; then
    cat > /etc/audit/rules.d/99-server.rules <<'EOF'
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/sudoers -p wa -k sudo
-w /etc/sudoers.d/ -p wa -k sudo
EOF
    augenrules --load >/dev/null 2>&1 || true
    systemctl enable --now auditd >/dev/null 2>&1 || true
    ok "auditd включён с базовыми правилами."
else
    warn "auditd не установлен — пропускаю."
fi

# ---------- Проверки ----------
systemctl is-active --quiet ssh.service 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null || warn "SSH не активен — проверьте systemctl status ssh"
systemctl is-active --quiet fail2ban 2>/dev/null || warn "Fail2ban не активен"
ufw status 2>/dev/null | grep -qw active || warn "UFW не активен"
systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null && ok "apt-daily-upgrade.timer включён." || warn "apt-daily-upgrade.timer не включён"

cat <<EOF

============================================================
НАСТРОЙКА ЗАВЕРШЕНА
============================================================
Подключение SSH (проверьте в НОВОМ окне, не закрывая текущую сессию!):

    ssh -p ${RANDOM_SSH_PORT} ${NEW_USER}@${CONNECT_HOST}
    ssh -p ${RANDOM_SSH_PORT} ${NEW_USER}@${SERVER_IP}

Файлы:
    /etc/ssh/sshd_config.d/99-hardening.conf
    /etc/fail2ban/jail.local
    /etc/apt/apt.conf.d/20auto-upgrades
    /etc/apt/apt.conf.d/50unattended-upgrades
    /etc/sysctl.d/99-server-hardening.conf
    /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf

Проверки вручную:
    sshd -T | grep -iE '^(port|permitrootlogin|allowusers)'
    ufw status verbose
    fail2ban-client status sshd
    systemctl status apt-daily-upgrade.timer unattended-upgrades
    systemctl list-timers apt-daily-upgrade.timer

Следующие шаги для VPN (пример — autoXRAY для VLESS):
    bash -c "\$(curl -fsSL https://raw.githubusercontent.com/xVRVx/autoXRAY/main/autoXRAY2.sh)" -- ${SERVER_DOMAIN:-вашДОМЕН.com}
    # AmneziaWG/WireGuard: порт 51820/udp уже открыт в UFW.
    # MTProto: порт 8888/tcp уже открыт в UFW (web MTProto — через 443).
============================================================
EOF
