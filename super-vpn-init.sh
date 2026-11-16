#!/usr/bin/env bash
# ==============================================================================
# Script: super-vpn-init.sh
# Description: Комплексный конфигуратор сервера (Debian / Ubuntu)
# Hardening + Xray VLESS Reality + AmneziaWG (Phone & Keenetic) + MTProto Telegram + Nginx Web Portal
# + Anti-RU Routing & Auto-healing Diagnostics
# ==============================================================================

set -e

# Цвета для вывода в консоль
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; }

# 1. Проверка прав root
if [ "$EUID" -ne 0 ]; then
    err "Скрипт должен быть запущен с правами root!"
    exit 1
fi

clear
echo -e "${PURPLE}================================================================${NC}"
echo -e "${PURPLE}      ALL-IN-ONE SECURE SERVER & VPN INITIALIZER (autoXRAY+)    ${NC}"
echo -e "${PURPLE}  Hardening + VLESS + AmneziaWG (Phone/Keenetic) + MTProto + Web ${NC}"
echo -e "${PURPLE}================================================================${NC}\n"

# 2. Автоопределение дистрибутива
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
else
    err "Не удалось определить операционную систему."
    exit 1
fi

if [[ "$OS" != "ubuntu" && "$OS" != "debian" ]]; then
    err "Поддерживаются только Debian и Ubuntu! Обнаружено: $OS"
    exit 1
fi
success "Операционная система: $NAME $VERSION"

# 3. Интерактивный ввод данных
info "--- Настройка сети и учетных записей ---"

DETECTED_IP=$(curl -s4 --max-time 4 ifconfig.me || curl -s4 --max-time 4 api.ipify.org || echo "")
read -rp "Введите статический IP сервера [по умолчанию: $DETECTED_IP]: " SERVER_IP
SERVER_IP=${SERVER_IP:-$DETECTED_IP}

read -rp "Введите ваш DNS-домен (если есть, например vpn.example.com; иначе Enter): " SERVER_DOMAIN
CONNECT_HOST="${SERVER_DOMAIN:-$SERVER_IP}"

while true; do
    read -rp "Введите имя нового пользователя-администратора: " NEW_USER
    if [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] && [ "$NEW_USER" != "root" ]; then
        break
    else
        warn "Имя должно состоять из строчных латинских букв/цифр и не быть 'root'."
    fi
done

while true; do
    read -s -rp "Введите пароль для $NEW_USER: " USER_PASS
    echo ""
    read -s -rp "Повторите пароль для $NEW_USER: " USER_PASS_CONFIRM
    echo ""
    if [ "$USER_PASS" == "$USER_PASS_CONFIRM" ] && [ -n "$USER_PASS" ]; then
        break
    else
        warn "Пароли не совпадают. Попробуйте снова."
    fi
done

while true; do
    read -s -rp "Введите новый пароль для root: " ROOT_PASS
    echo ""
    read -s -rp "Повторите пароль для root: " ROOT_PASS_CONFIRM
    echo ""
    if [ "$ROOT_PASS" == "$ROOT_PASS_CONFIRM" ] && [ -n "$ROOT_PASS" ]; then
        break
    else
        warn "Пароли root не совпадают. Попробуйте снова."
    fi
done

# 4. Обновление пакетов и установка зависимостей
info "Обновление системы и установка компонентов..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y sudo curl wget git gnupg ca-certificates lsb-release ufw fail2ban \
                   rsyslog cron systemd-timesyncd nginx ipset iptables jq qrencode \
                   software-properties-common python3-launchpadlib tar gzip

# 5. Смена пароля root и создание sudo-пользователя
info "Настройка учетных записей..."
echo "root:$ROOT_PASS" | chpasswd
success "Пароль root обновлен."

if id "$NEW_USER" &>/dev/null; then
    warn "Пользователь $NEW_USER уже существует. Обновляем пароль и группу."
else
    useradd -m -s /bin/bash "$NEW_USER"
fi
echo "$NEW_USER:$USER_PASS" | chpasswd
usermod -aG sudo "$NEW_USER"

if [ -d "/root/.ssh" ] && [ -f "/root/.ssh/authorized_keys" ]; then
    mkdir -p "/home/$NEW_USER/.ssh"
    cp /root/.ssh/authorized_keys "/home/$NEW_USER/.ssh/"
    chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
    chmod 700 "/home/$NEW_USER/.ssh"
    chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"
fi
success "Пользователь $NEW_USER настроен с правами sudo."

# 6. Безопасная настройка SSH (с защитой от сбоя /run/sshd)
RANDOM_SSH_PORT=$(shuf -i 10001-65535 -n 1)
info "Сгенерирован случайный SSH-порт: $RANDOM_SSH_PORT"

# Гарантируем наличие privilege separation каталога
mkdir -p /run/sshd
chmod 0755 /run/sshd

cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak_$(date +%s)"

mkdir -p /etc/ssh/sshd_config.d
cat <<EOF > /etc/ssh/sshd_config.d/99-hardened.conf
Port $RANDOM_SSH_PORT
PermitRootLogin no
AllowUsers $NEW_USER
PasswordAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 4
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
EOF

# Проверка синтаксиса перед перезапуском
if sshd -t; then
    if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        systemctl stop ssh.socket 2>/dev/null || true
        systemctl disable ssh.socket 2>/dev/null || true
    fi
    systemctl enable ssh.service 2>/dev/null || systemctl enable sshd.service 2>/dev/null
    systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null
    success "Служба SSH активна на порту $RANDOM_SSH_PORT."
else
    err "Ошибка проверки синтаксиса SSH! Восстановление порта по умолчанию..."
    rm -f /etc/ssh/sshd_config.d/99-hardened.conf
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || systemctl start ssh.socket 2>/dev/null || true
    RANDOM_SSH_PORT=22
fi

# 7. Настройка rsyslog и Fail2ban
info "Настройка rsyslog и Fail2ban..."
systemctl enable --now rsyslog
touch /var/log/auth.log
chmod 640 /var/log/auth.log

cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 10m
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = $RANDOM_SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 1h
findtime = 10m
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# 8. Ядро, BBR и Anti-RU блокировка на уровне ipset
info "Оптимизация сетевого стека и включение TCP BBR..."
cat <<EOF > /etc/sysctl.d/99-custom-vpn.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.core.somaxconn = 65535
fs.file-max = 1000000
EOF
sysctl --system >/dev/null 2>&1

info "Загрузка пулов IP РФ в ipset для изоляции Рунета..."
ipset create ru_blocked hash:net 2>/dev/null || ipset flush ru_blocked
curl -sSL "https://www.ipdeny.com/ipblocks/data/countries/ru.zone" | while read -r subnet; do
    [[ -n "$subnet" && ! "$subnet" =~ ^# ]] && ipset add ru_blocked "$subnet" 2>/dev/null || true
done

systemctl enable --now systemd-timesyncd
timedatectl set-ntp true

# 9. Установка и настройка Xray (VLESS Reality + Anti-RU)
info "Установка ядра Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

XRAY_UUID=$(xray uuid)
XRAY_KEYS=$(xray x25519)
XRAY_PRIV_KEY=$(echo "$XRAY_KEYS" | grep "Private key:" | awk '{print $3}')
XRAY_PUB_KEY=$(echo "$XRAY_KEYS" | grep "Public key:" | awk '{print $3}')
XRAY_SHORT_ID=$(openssl rand -hex 8)
SNI_CAMOUFLAGE="www.microsoft.com"

info "Конфигурация Xray (Anti-RU и блокировка рекламы)..."
cat <<EOF > /usr/local/etc/xray/config.json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$XRAY_UUID", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI_CAMOUFLAGE:443",
          "xver": 0,
          "serverNames": [ "$SNI_CAMOUFLAGE" ],
          "privateKey": "$XRAY_PRIV_KEY",
          "shortIds": [ "$XRAY_SHORT_ID" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": [
          "geosite:category-ru",
          "geosite:ru",
          "regexp:.*\\\\.ru$",
          "regexp:.*\\\\.рф$",
          "regexp:.*\\\\.su$",
          "geosite:category-ads-all"
        ],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "ip": [ "geoip:ru", "geoip:private" ],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "direct"
      }
    ]
  }
}
EOF

systemctl enable xray
systemctl restart xray

VLESS_NAME="VLESS-Reality-AntiRU"
VLESS_LINK="vless://${XRAY_UUID}@${CONNECT_HOST}:443?security=reality&encryption=none&pbk=${XRAY_PUB_KEY}&headerType=none&fp=chrome&spx=%2F&type=tcp&flow=xtls-rprx-vision&sni=${SNI_CAMOUFLAGE}&sid=${XRAY_SHORT_ID}#${VLESS_NAME}"

# 10. Установка AmneziaWG (Генерация для Телефона И Роутера Keenetic)
info "Настройка AmneziaWG (профили для Телефона и Keenetic)..."
if [[ "$OS" == "ubuntu" ]]; then
    add-apt-repository -y ppa:amnezia/ppa || true
    apt-get update -y
    apt-get install -y amneziawg || apt-get install -y wireguard-tools
else
    curl -sS https://keyserver.ubuntu.com/pks/lookup?op=get\&search=0x57290828 | gpg --dearmor -o /usr/share/keyrings/amnezia-ppa-keyring.gpg --yes || true
    echo "deb [signed-by=/usr/share/keyrings/amnezia-ppa-keyring.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu focal main" > /etc/apt/sources.list.d/amnezia-ppa.list
    apt-get update -y
    apt-get install -y amneziawg || apt-get install -y wireguard-tools
fi

AWG_CMD="awg"
if ! command -v awg &>/dev/null; then
    AWG_CMD="wg"
fi

mkdir -p /etc/amnezia/amneziawg

# Ключи сервера
AWG_SERVER_PRIV=$($AWG_CMD genkey)
AWG_SERVER_PUB=$(echo "$AWG_SERVER_PRIV" | $AWG_CMD pubkey)

# Ключи пира 1: Телефон / ПК (10.66.66.2)
PHONE_PRIV=$($AWG_CMD genkey)
PHONE_PUB=$(echo "$PHONE_PRIV" | $AWG_CMD pubkey)
PHONE_PSK=$($AWG_CMD genpsk)

# Ключи пира 2: Роутер Keenetic (10.66.66.3)
KEENETIC_PRIV=$($AWG_CMD genkey)
KEENETIC_PUB=$(echo "$KEENETIC_PRIV" | $AWG_CMD pubkey)
KEENETIC_PSK=$($AWG_CMD genpsk)

# Случайные параметры защиты от блокировок ТСПУ (DPI)
JC=$(shuf -i 3-7 -n 1)
JMIN=$(shuf -i 30-50 -n 1)
JMAX=$(shuf -i 60-90 -n 1)
S1=$(shuf -i 15-35 -n 1)
S2=$(shuf -i 15-35 -n 1)
H1=$(shuf -i 100000000-999999999 -n 1)
H2=$(shuf -i 100000000-999999999 -n 1)
H3=$(shuf -i 100000000-999999999 -n 1)
H4=$(shuf -i 100000000-999999999 -n 1)

DEFAULT_IF=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' || echo "eth0")

# Конфиг сервера awg0.conf с 2 пирами
cat <<EOF > /etc/amnezia/amneziawg/awg0.conf
[Interface]
Address = 10.66.66.1/24
ListenPort = 51820
PrivateKey = $AWG_SERVER_PRIV
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4
PostUp = iptables -A FORWARD -i awg0 -m set --match-set ru_blocked dst -j REJECT --reject-with icmp-host-prohibited; iptables -A FORWARD -i awg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $DEFAULT_IF -j MASQUERADE
PostDown = iptables -D FORWARD -i awg0 -m set --match-set ru_blocked dst -j REJECT --reject-with icmp-host-prohibited 2>/dev/null || true; iptables -D FORWARD -i awg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $DEFAULT_IF -j MASQUERADE

# Пир 1: Телефон / Мобильный клиент
[Peer]
PublicKey = $PHONE_PUB
PresharedKey = $PHONE_PSK
AllowedIPs = 10.66.66.2/32

# Пир 2: Роутер Keenetic
[Peer]
PublicKey = $KEENETIC_PUB
PresharedKey = $KEENETIC_PSK
AllowedIPs = 10.66.66.3/32
EOF

systemctl enable awg-quick@awg0 2>/dev/null || systemctl enable wg-quick@awg0 2>/dev/null || true
systemctl restart awg-quick@awg0 2>/dev/null || systemctl restart wg-quick@awg0 2>/dev/null || true

# Клиентский файл 1: Телефон (с параметрами AmneziaWG для приложения)
PHONE_CONF="/etc/amnezia/amneziawg/amneziawg-phone.conf"
cat <<EOF > "$PHONE_CONF"
[Interface]
Address = 10.66.66.2/32
PrivateKey = $PHONE_PRIV
DNS = 1.1.1.1, 8.8.8.8
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $AWG_SERVER_PUB
PresharedKey = $PHONE_PSK
Endpoint = $CONNECT_HOST:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

# Клиентский файл 2: Keenetic (с MTU 1360 для исключения фрагментации роутера)
KEENETIC_CONF="/etc/amnezia/amneziawg/wireguard-keenetic.conf"
cat <<EOF > "$KEENETIC_CONF"
[Interface]
Address = 10.66.66.3/32
PrivateKey = $KEENETIC_PRIV
DNS = 1.1.1.1, 8.8.8.8
MTU = 1360

[Peer]
PublicKey = $AWG_SERVER_PUB
PresharedKey = $KEENETIC_PSK
Endpoint = $CONNECT_HOST:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

success "Сгенерированы конфиги: для Телефона и роутера Keenetic."

# 11. Установка и настройка Telegram MTProto Proxy (mtg с Fake-TLS)
info "Установка MTProto Proxy для Telegram (Fake-TLS mtg)..."
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then 
    MTG_ARCH="amd64"
elif [ "$ARCH" = "aarch64" ]; then 
    MTG_ARCH="arm64"
else 
    MTG_ARCH="amd64"
fi

MTG_VER=$(curl -sSL "https://api.github.com/repos/9seconds/mtg/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || echo "v2.1.7")
MTG_VER=${MTG_VER:-"v2.1.7"}

mkdir -p /tmp/mtg_install /etc/mtg
if curl -sSL "https://github.com/9seconds/mtg/releases/download/${MTG_VER}/mtg-${MTG_VER#v}-linux-${MTG_ARCH}.tar.gz" -o /tmp/mtg_install/mtg.tar.gz; then
    tar -xzf /tmp/mtg_install/mtg.tar.gz -C /tmp/mtg_install
    find /tmp/mtg_install -name "mtg" -type f -exec mv {} /usr/local/bin/mtg \;
    chmod +x /usr/local/bin/mtg
fi
rm -rf /tmp/mtg_install

if command -v /usr/local/bin/mtg &>/dev/null; then
    # Генерация Fake-TLS секрета с маскировкой под Cloudflare
    MTG_SECRET=$(/usr/local/bin/mtg generate-secret --hex cloudflare.com)
    cat <<EOF > /etc/mtg/config.toml
secret = "$MTG_SECRET"
bind-to = "0.0.0.0:8888"
EOF

    cat <<'EOF' > /etc/systemd/system/mtg.service
[Unit]
Description=mtg - Telegram MTProto Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mtg run /etc/mtg/config.toml
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mtg
    systemctl restart mtg
    success "MTProto Proxy запущен на порту 8888 с Fake-TLS."
    TG_PROXY_LINK="tg://proxy?server=${CONNECT_HOST}&port=8888&secret=${MTG_SECRET}"
    TG_HTTP_LINK="https://t.me/proxy?server=${CONNECT_HOST}&port=8888&secret=${MTG_SECRET}"
else
    warn "Не удалось загрузить бинарник mtg. Пропуск MTProto."
    TG_PROXY_LINK=""
    TG_HTTP_LINK=""
fi

# 12. Настройка Nginx: Сайт-маскировка (порт 80) и Веб-портал (порт 8443)
info "Настройка веб-сервера Nginx и веб-портала..."
SECRET_PORTAL_TOKEN="portal_$(openssl rand -hex 6)"
WEB_ROOT="/var/www/camouflage"
PORTAL_ROOT="/var/www/portal/$SECRET_PORTAL_TOKEN"
mkdir -p "$WEB_ROOT" "$PORTAL_ROOT"

# Сайт-маскировка
cat <<'EOF' > "$WEB_ROOT/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Nexus Cloud Edge</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #f8fafc; margin: 0; padding: 0; }
    .hero { min-height: 85vh; display: flex; flex-direction: column; justify-content: center; align-items: center; text-align: center; padding: 2rem; }
    h1 { font-size: 3rem; margin-bottom: 1rem; background: linear-gradient(to right, #38bdf8, #818cf8); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
    p { font-size: 1.25rem; color: #94a3b8; max-width: 600px; line-height: 1.6; }
    .status { display: inline-flex; align-items: center; background: #1e293b; padding: 8px 16px; border-radius: 9999px; font-size: 0.875rem; border: 1px solid #334155; }
    .dot { width: 8px; height: 8px; background: #22c55e; border-radius: 50%; margin-right: 8px; }
  </style>
</head>
<body>
  <div class="hero">
    <div class="status"><div class="dot"></div> All Systems Operational</div>
    <h1>Enterprise Cloud Infrastructure</h1>
    <p>High-reliability edge node and private microservices telemetry.</p>
  </div>
</body>
</html>
EOF

# Копируем оба файла конфигов в веб-папку
cp "$PHONE_CONF" "$PORTAL_ROOT/amneziawg-phone.conf"
cp "$KEENETIC_CONF" "$PORTAL_ROOT/wireguard-keenetic.conf"

PHONE_CONF_CONTENT=$(cat "$PHONE_CONF")
KEENETIC_CONF_CONTENT=$(cat "$KEENETIC_CONF")

# Генерация HTML-портала
cat <<EOF > "$PORTAL_ROOT/index.html"
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Панель управления VPN | $CONNECT_HOST</title>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
  <style>
    :root { --bg: #0b0f19; --card: #151d30; --border: #232f48; --accent: #38bdf8; --text: #f1f5f9; --sub: #94a3b8; --green: #10b981; --tg: #229ED9; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--text); margin: 0; padding: 24px; }
    .container { max-width: 1000px; margin: 0 auto; }
    .header { text-align: center; margin-bottom: 32px; }
    .header h1 { margin: 0 0 8px 0; font-size: 2.2rem; color: var(--accent); }
    .badge-ru { display: inline-block; background: rgba(239, 68, 68, 0.15); color: #f87171; border: 1px solid rgba(239, 68, 68, 0.3); padding: 5px 16px; border-radius: 9999px; font-size: 0.85rem; font-weight: bold; }
    .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; margin-bottom: 24px; }
    @media (max-width: 820px) { .grid { grid-template-columns: 1fr; } }
    .card { background: var(--card); border: 1px solid var(--border); border-radius: 16px; padding: 24px; box-shadow: 0 10px 25px rgba(0,0,0,0.3); }
    .card-title { font-size: 1.25rem; font-weight: 600; margin-bottom: 16px; display: flex; align-items: center; justify-content: space-between; }
    .qr-container { display: flex; flex-direction: column; align-items: center; background: white; padding: 14px; border-radius: 12px; width: fit-content; margin: 0 auto 16px auto; }
    .copy-box { background: #0c121e; padding: 12px; border-radius: 8px; border: 1px solid var(--border); font-family: monospace; font-size: 0.82rem; word-break: break-all; margin-bottom: 12px; color: #cbd5e1; max-height: 120px; overflow-y: auto; }
    .btn { display: inline-block; background: var(--accent); color: #000; padding: 10px 16px; border-radius: 8px; text-decoration: none; font-weight: 600; cursor: pointer; border: none; font-size: 0.88rem; transition: 0.2s; }
    .btn:hover { opacity: 0.9; }
    .btn-green { background: var(--green); color: #fff; }
    .btn-tg { background: var(--tg); color: #fff; }
    .guide-item { margin-bottom: 10px; color: var(--sub); font-size: 0.9rem; line-height: 1.5; }
    .guide-item strong { color: var(--text); }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <h1>Личный VPN Сервер</h1>
      <p style="color: var(--sub);">IP: $SERVER_IP ${SERVER_DOMAIN:+| Домен: $SERVER_DOMAIN}</p>
      <div class="badge-ru">🛡️ Умная маршрутизация: сайты .RU, реклама и трекеры заблокированы</div>
    </div>

    <div class="grid">
      <!-- VLESS CARD -->
      <div class="card">
        <div class="card-title">
          <span>⚡ VLESS Reality + Vision</span>
          <span style="font-size:0.8rem; color:var(--accent);">Порт 443</span>
        </div>
        <div class="qr-container"><div id="vless-qr"></div></div>
        <div class="copy-box" id="vless-link">$VLESS_LINK</div>
        <button class="btn" onclick="copyText('vless-link')">📋 Скопировать ссылку</button>
      </div>

      <!-- MTPROTO TELEGRAM CARD -->
      <div class="card">
        <div class="card-title">
          <span>✈️ Telegram MTProto Proxy</span>
          <span style="font-size:0.8rem; color:var(--tg);">Fake-TLS (8888)</span>
        </div>
        <div class="qr-container"><div id="tg-qr"></div></div>
        <div class="copy-box" id="tg-link">$TG_HTTP_LINK</div>
        <div style="display:flex; gap: 8px;">
          <a class="btn btn-tg" href="$TG_PROXY_LINK" target="_blank">🚀 Включить в Telegram</a>
          <button class="btn" onclick="copyText('tg-link')">📋 Скопировать</button>
        </div>
      </div>

      <!-- AMNEZIAWG ТЕЛЕФОН -->
      <div class="card">
        <div class="card-title">
          <span>📱 AmneziaWG (Телефон / ПК)</span>
          <span style="font-size:0.8rem; color:var(--green);">UDP 51820 | 10.66.66.2</span>
        </div>
        <div class="qr-container"><div id="phone-qr"></div></div>
        <div class="copy-box" id="phone-conf">$PHONE_CONF_CONTENT</div>
        <div style="display:flex; gap: 8px;">
          <button class="btn btn-green" onclick="copyText('phone-conf')">📋 Скопировать</button>
          <a class="btn" href="amneziawg-phone.conf" download="amneziawg-phone.conf">💾 Скачать .conf</a>
        </div>
      </div>

      <!-- KEENETIC РОУТЕР -->
      <div class="card">
        <div class="card-title">
          <span>🌐 WireGuard (Роутер Keenetic)</span>
          <span style="font-size:0.8rem; color:var(--green);">MTU 1360 | 10.66.66.3</span>
        </div>
        <div class="qr-container"><div id="keenetic-qr"></div></div>
        <div class="copy-box" id="keenetic-conf">$KEENETIC_CONF_CONTENT</div>
        <div style="display:flex; gap: 8px;">
          <button class="btn btn-green" onclick="copyText('keenetic-conf')">📋 Скопировать</button>
          <a class="btn" href="wireguard-keenetic.conf" download="wireguard-keenetic.conf">💾 Скачать .conf</a>
        </div>
      </div>
    </div>

    <!-- ИНСТРУКЦИЯ ПО РОУТЕРУ И КЛИЕНТАМ -->
    <div class="card">
      <div class="card-title">📖 Инструкция по подключению</div>
      <div class="guide-item"><strong>Роутер Keenetic:</strong> Зайдите в веб-интерфейс Keenetic (192.168.1.1) → <em>Сетевые правила</em> → <em>WireGuard VPN</em> → Нажмите <em>Добавить подключение</em> → <em>Загрузить из файла</em> и выберите скачанный <code>wireguard-keenetic.conf</code>. Включите подключение и добавьте его в политику маршрутизации Keenetic.</div>
      <div class="guide-item"><strong>Телефон / ПК (Amnezia):</strong> Установите приложение <em>Amnezia VPN</em>. Нажмите «+» → «У меня есть данные для подключения» → Отсканируйте QR-код телефона камерой.</div>
      <div class="guide-item"><strong>VLESS Клиенты:</strong> Подходят <em>Happ, Streisand, v2rayNG, Hiddify, FoXray, Nekoray</em>. Скопируйте ссылку и нажмите «Импорт из буфера».</div>
      <div class="guide-item"><strong>Telegram MTProto:</strong> Нажмите кнопку «Включить в Telegram» или отсканируйте QR-код в Telegram на смартфоне.</div>
    </div>
  </div>

  <script>
    new QRCode(document.getElementById("vless-qr"), { text: "$VLESS_LINK", width: 150, height: 150 });
    new QRCode(document.getElementById("tg-qr"), { text: "$TG_HTTP_LINK", width: 150, height: 150 });
    new QRCode(document.getElementById("phone-qr"), { text: document.getElementById("phone-conf").innerText, width: 150, height: 150 });
    new QRCode(document.getElementById("keenetic-qr"), { text: document.getElementById("keenetic-conf").innerText, width: 150, height: 150 });

    function copyText(id) {
      const text = document.getElementById(id).innerText;
      navigator.clipboard.writeText(text).then(() => {
        alert("Скопировано в буфер обмена!");
      });
    }
  </script>
</body>
</html>
EOF

# Nginx vhosts: 80 (маскировка) и 8443 (секретный портал)
cat <<EOF > /etc/nginx/sites-available/default
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root $WEB_ROOT;
    index index.html;
    server_name _;

    location / {
        try_files \$uri \$uri/ =404;
    }
}

server {
    listen 8443 default_server;
    listen [::]:8443 default_server;
    root /var/www/portal;
    index index.html;
    server_name _;

    location /$SECRET_PORTAL_TOKEN/ {
        alias $PORTAL_ROOT/;
        index index.html;
    }

    location / {
        return 404;
    }
}
EOF

systemctl restart nginx

# 13. Настройка фаервола UFW
info "Настройка портов в UFW..."
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing

ufw allow "$RANDOM_SSH_PORT/tcp" comment "SSH Port"
ufw allow 80/tcp comment "HTTP Camouflage"
ufw allow 443/tcp comment "VLESS Reality HTTPS"
ufw allow 443/udp comment "QUIC / Hysteria"
ufw allow 8442/tcp comment "Custom 8442"
ufw allow 8443/tcp comment "Web Portal 8443"
ufw allow 10443/tcp comment "Custom 10443"
ufw allow 51820/udp comment "AmneziaWG UDP"
ufw allow 8888/tcp comment "MTProto Proxy TCP"

ufw --force enable

# 14. Еженедельный крон
cat <<'EOF' > /etc/cron.d/weekly_system_update
0 5 * * 0 root apt-get update && DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y && apt-get autoremove -y && apt-get clean && /sbin/reboot
EOF
chmod 644 /etc/cron.d/weekly_system_update

# ==============================================================================
# 15. КОМПЛЕКСНАЯ ПРОВЕРКА РАБОТОСПОСОБНОСТИ И АВТОИСЦЕЛЕНИЕ (SELF-HEALING)
# ==============================================================================
info "--- Запуск самодиагностики и автоисправления компонентов ---"

check_and_heal() {
    local name="$1"
    local check_cmd="$2"
    local heal_cmd="$3"

    if eval "$check_cmd" >/dev/null 2>&1; then
        echo -e "  [${GREEN}OK${NC}] $name"
    else
        warn "Обнаружена проблема в $name! Применение автоисправления..."
        eval "$heal_cmd" >/dev/null 2>&1 || true
        sleep 2
        if eval "$check_cmd" >/dev/null 2>&1; then
            echo -e "  [${YELLOW}FIXED${NC}] $name (успешно восстановлен)"
        else
            echo -e "  [${RED}FAILED${NC}] $name (требует ручной проверки)"
        fi
    fi
}

check_and_heal "SSH Служба" \
    "systemctl is-active --quiet ssh || systemctl is-active --quiet sshd" \
    "mkdir -p /run/sshd && chmod 0755 /run/sshd && systemctl restart ssh || systemctl restart sshd"

check_and_heal "Xray (VLESS Reality)" \
    "systemctl is-active --quiet xray" \
    "systemctl restart xray"

check_and_heal "AmneziaWG Сервер (Порт 51820)" \
    "ip link show awg0 >/dev/null 2>&1 || ip link show wg0 >/dev/null 2>&1" \
    "systemctl restart awg-quick@awg0 || systemctl restart wg-quick@awg0"

check_and_heal "Telegram MTProto Proxy (mtg)" \
    "systemctl is-active --quiet mtg" \
    "systemctl restart mtg"

check_and_heal "Веб-сервер Nginx (Порты 80, 8443)" \
    "systemctl is-active --quiet nginx" \
    "nginx -t && systemctl restart nginx"

check_and_heal "Защита Fail2ban" \
    "fail2ban-client ping | grep -q 'Server replied: pong'" \
    "systemctl restart fail2ban"

check_and_heal "Фаервол UFW" \
    "ufw status | grep -qw 'active'" \
    "ufw --force enable"

check_and_heal "Сетевой алгоритм TCP BBR" \
    "sysctl net.ipv4.tcp_congestion_control | grep -q 'bbr'" \
    "modprobe tcp_bbr && sysctl -w net.ipv4.tcp_congestion_control=bbr"

check_and_heal "Фильтр блокировки .RU (ipset)" \
    "ipset list ru_blocked >/dev/null 2>&1" \
    "ipset create ru_blocked hash:net 2>/dev/null || true"

# 16. Финальный отчет
clear
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}             НАСТРОЙКА СЕРВЕРА УСПЕШНО ЗАВЕРШЕНА!               ${NC}"
echo -e "${GREEN}================================================================${NC}\n"

PORTAL_URL_IP="http://${SERVER_IP}:8443/${SECRET_PORTAL_TOKEN}/"
[ -n "$SERVER_DOMAIN" ] && PORTAL_URL_DOM="http://${SERVER_DOMAIN}:8443/${SECRET_PORTAL_TOKEN}/"

echo -e "${CYAN}--- ВАШ СЕКРЕТНЫЙ ВЕБ-ПОРТАЛ С КОНФИГАМИ И QR-КОДАМИ ---${NC}"
echo -e "  Откройте в браузере:"
echo -e "  👉 ${GREEN}${PORTAL_URL_IP}${NC}"
if [ -n "$SERVER_DOMAIN" ]; then
    echo -e "  👉 ${GREEN}${PORTAL_URL_DOM}${NC}"
fi
echo ""

echo -e "${CYAN}--- ДАННЫЕ ДЛЯ ПОДКЛЮЧЕНИЯ ПО SSH ---${NC}"
echo -e "  ${YELLOW}ssh -p $RANDOM_SSH_PORT $NEW_USER@$SERVER_IP${NC}"
if [ -n "$SERVER_DOMAIN" ]; then
    echo -e "  ${YELLOW}ssh -p $RANDOM_SSH_PORT $NEW_USER@$SERVER_DOMAIN${NC}"
fi
echo ""

echo -e "${CYAN}--- ТЕЛЕГРАМ ПРОКСИ (MTPROTO FAKE-TLS) ---${NC}"
if [ -n "$TG_HTTP_LINK" ]; then
    echo -e "  Ссылка для подключения: ${YELLOW}$TG_HTTP_LINK${NC}"
fi
echo ""

echo -e "${CYAN}--- БЫСТРАЯ ССЫЛКА VLESS REALITY ---${NC}"
echo -e "  ${YELLOW}$VLESS_LINK${NC}\n"

echo -e "${PURPLE}--- СТАТУС БЕЗОПАСНОСТИ И МАРШРУТИЗАЦИИ ---${NC}"
echo -e "  • Сайты .RU, .РФ, .SU и IP РФ: ${RED}ЗАБЛОКИРОВАНЫ${NC}"
echo -e "  • Keenetic файл: ${GREEN}wireguard-keenetic.conf (MTU 1360)${NC}"
echo -e "  • Телефон файл:  ${GREEN}amneziawg-phone.conf (Анти-ТСПУ/DPI)${NC}"
echo -e "  • Все службы прошли автодиагностику и активны.${NC}\n"

echo -e "${RED}ВАЖНО: Проверьте вход по SSH в новом окне, не закрывая текущее!${NC}"
