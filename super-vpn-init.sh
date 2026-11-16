#!/usr/bin/env bash
# ==============================================================================
# Script: super-vpn-init.sh
# Description: Комплексный конфигуратор сервера (Debian / Ubuntu)
# Hardening + Xray VLESS Reality (Anti-RU routing) + AmneziaWG + Nginx Portal & Camouflage
# ==============================================================================

set -e

# Цветовая палитра для терминала
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

# 1. Проверка прав суперпользователя (root)
if [ "$EUID" -ne 0 ]; then
    err "Скрипт должен быть запущен с правами root!"
    exit 1
fi

clear
echo -e "${PURPLE}================================================================${NC}"
echo -e "${PURPLE}      ALL-IN-ONE SECURE SERVER & VPN INITIALIZER (autoXRAY+)    ${NC}"
echo -e "${PURPLE}   Hardening + VLESS Reality + AmneziaWG + Anti-RU Routing + Web ${NC}"
echo -e "${PURPLE}================================================================${NC}\n"

# 2. Автоопределение дистрибутива (Ubuntu / Debian)
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
else
    err "Не удалось определить дистрибутив операционной системы."
    exit 1
fi

if [[ "$OS" != "ubuntu" && "$OS" != "debian" ]]; then
    err "Скрипт поддерживает только Debian и Ubuntu! Обнаружено: $OS"
    exit 1
fi
success "Операционная система определена: $NAME $VERSION"

# 3. Интерактивный ввод сетевых параметров и паролей
info "--- Настройка сети и учетных записей ---"

# Автоопределение внешнего IP-адреса
DETECTED_IP=$(curl -s4 --max-time 4 ifconfig.me || curl -s4 --max-time 4 api.ipify.org || echo "")
read -rp "Введите статический IP сервера [по умолчанию: $DETECTED_IP]: " SERVER_IP
SERVER_IP=${SERVER_IP:-$DETECTED_IP}

read -rp "Введите ваш DNS-домен (если есть, например vpn.mydomain.com; иначе оставьте пустым): " SERVER_DOMAIN

# Хост подключения (домен в приоритете, если указан)
CONNECT_HOST="${SERVER_DOMAIN:-$SERVER_IP}"

# Ввод нового администратора
while true; do
    read -rp "Введите имя нового пользователя-администратора: " NEW_USER
    if [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] && [ "$NEW_USER" != "root" ]; then
        break
    else
        warn "Имя должно состоять из строчных латинских букв/цифр и не быть 'root'."
    fi
done

# Ввод пароля для нового пользователя
while true; do
    read -s -rp "Введите пароль для $NEW_USER: " USER_PASS
    echo ""
    read -s -rp "Повторите пароль для $NEW_USER: " USER_PASS_CONFIRM
    echo ""
    if [ "$USER_PASS" == "$USER_PASS_CONFIRM" ] && [ -n "$USER_PASS" ]; then
        break
    else
        warn "Пароли не совпадают или пустые. Попробуйте снова."
    fi
done

# Ввод нового пароля root
while true; do
    read -s -rp "Введите новый пароль для root: " ROOT_PASS
    echo ""
    read -s -rp "Повторите пароль для root: " ROOT_PASS_CONFIRM
    echo ""
    if [ "$ROOT_PASS" == "$ROOT_PASS_CONFIRM" ] && [ -n "$ROOT_PASS" ]; then
        break
    else
        warn "Пароли root не совпадают или пустые. Попробуйте снова."
    fi
done

# 4. Обновление репозиториев и установка базовых системных утилит
info "Обновление системы (apt update && upgrade)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y sudo curl wget git gnupg ca-certificates lsb-release ufw fail2ban \
                   rsyslog cron systemd-timesyncd nginx ipset iptables jq qrencode \
                   software-properties-common python3-launchpadlib

# 5. Смена пароля root и настройка sudo-пользователя
info "Настройка учетных записей..."
echo "root:$ROOT_PASS" | chpasswd
success "Пароль root успешно обновлен."

if id "$NEW_USER" &>/dev/null; then
    warn "Пользователь $NEW_USER уже существует. Обновляем пароль и права."
else
    useradd -m -s /bin/bash "$NEW_USER"
fi
echo "$NEW_USER:$USER_PASS" | chpasswd
usermod -aG sudo "$NEW_USER"

# Сохранение существующих ключей root для нового пользователя
if [ -d "/root/.ssh" ] && [ -f "/root/.ssh/authorized_keys" ]; then
    info "Копирование существующих SSH-ключей root пользователю $NEW_USER..."
    mkdir -p "/home/$NEW_USER/.ssh"
    cp /root/.ssh/authorized_keys "/home/$NEW_USER/.ssh/"
    chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
    chmod 700 "/home/$NEW_USER/.ssh"
    chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"
fi
success "Пользователь $NEW_USER настроен и добавлен в группу sudo."

# 6. Настройка и усиление SSH
RANDOM_SSH_PORT=$(shuf -i 10001-65535 -n 1)
info "Сгенерирован случайный SSH-порт: $RANDOM_SSH_PORT"

cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak_$(date +%s)"

# Исправление сокетов systemd в современных Ubuntu (22.10, 24.04 LTS)
if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    systemctl stop ssh.socket 2>/dev/null || true
    systemctl disable ssh.socket 2>/dev/null || true
fi

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

if sshd -t; then
    systemctl enable ssh.service 2>/dev/null || systemctl enable sshd.service 2>/dev/null
    systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null
    success "Служба SSH перезапущена на порту $RANDOM_SSH_PORT. Вход root запрещен."
else
    err "Ошибка проверки синтаксиса SSH! Откат."
    rm -f /etc/ssh/sshd_config.d/99-hardened.conf
    exit 1
fi

# 7. Настройка rsyslog и Fail2ban
info "Настройка службы логирования rsyslog..."
systemctl enable --now rsyslog
touch /var/log/auth.log
chmod 640 /var/log/auth.log

info "Создание конфигурации /etc/fail2ban/jail.local..."
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
sleep 2

if fail2ban-client ping | grep -q "Server replied: pong"; then
    success "Fail2ban успешно запущен и защищает порт $RANDOM_SSH_PORT."
else
    warn "Fail2ban запущен, но статус требует внимания. Проверьте: fail2ban-client status"
fi

# 8. Оптимизация сетевого стека, BBR и Anti-RU блокировка на уровне ядра
info "Включение алгоритма TCP BBR и оптимизация ядра sysctl..."
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
success "Сетевой стек оптимизирован (BBR активен)."

# Настройка базы IP-адресов РФ в ipset для блокировки исходящих соединений
info "Загрузка пулов IP-адресов РФ для блокировки маршрутизации..."
ipset create ru_blocked hash:net 2>/dev/null || ipset flush ru_blocked
curl -sSL "https://www.ipdeny.com/ipblocks/data/countries/ru.zone" | while read -r subnet; do
    [[ -n "$subnet" && ! "$subnet" =~ ^# ]] && ipset add ru_blocked "$subnet" 2>/dev/null || true
done
success "Список российских подсетей загружен в ipset ru_blocked."

# Точное время (NTP) для стабильной работы TLS
systemctl enable --now systemd-timesyncd
timedatectl set-ntp true

# 9. Установка Xray (VLESS-Reality с блокировкой сайтов РФ и рекламы)
info "Установка и настройка ядра Xray..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

XRAY_UUID=$(xray uuid)
XRAY_KEYS=$(xray x25519)
XRAY_PRIV_KEY=$(echo "$XRAY_KEYS" | grep "Private key:" | awk '{print $3}')
XRAY_PUB_KEY=$(echo "$XRAY_KEYS" | grep "Public key:" | awk '{print $3}')
XRAY_SHORT_ID=$(openssl rand -hex 8)
SNI_CAMOUFLAGE="www.microsoft.com"

info "Конфигурация Xray (Anti-RU + Anti-Ads маршрутизация)..."
cat <<EOF > /usr/local/etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$XRAY_UUID",
            "flow": "xtls-rprx-vision"
          }
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
          "serverNames": [
            "$SNI_CAMOUFLAGE"
          ],
          "privateKey": "$XRAY_PRIV_KEY",
          "shortIds": [
            "$XRAY_SHORT_ID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
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
        "ip": [
          "geoip:ru",
          "geoip:private"
        ],
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
success "Xray VLESS-Reality настроен на порту 443 с изоляцией от Рунета."

VLESS_NAME="VLESS-Reality-AntiRU"
VLESS_LINK="vless://${XRAY_UUID}@${CONNECT_HOST}:443?security=reality&encryption=none&pbk=${XRAY_PUB_KEY}&headerType=none&fp=chrome&spx=%2F&type=tcp&flow=xtls-rprx-vision&sni=${SNI_CAMOUFLAGE}&sid=${XRAY_SHORT_ID}#${VLESS_NAME}"

# 10. Установка AmneziaWG (защита от ТСПУ и DPI)
info "Установка AmneziaWG..."
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
AWG_SERVER_PRIV=$($AWG_CMD genkey)
AWG_SERVER_PUB=$(echo "$AWG_SERVER_PRIV" | $AWG_CMD pubkey)
AWG_CLIENT_PRIV=$($AWG_CMD genkey)
AWG_CLIENT_PUB=$(echo "$AWG_CLIENT_PRIV" | $AWG_CMD pubkey)
AWG_PSK=$($AWG_CMD genpsk)

# Случайные параметры защиты от DPI (мусорные пакеты и заголовки)
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

[Peer]
PublicKey = $AWG_CLIENT_PUB
PresharedKey = $AWG_PSK
AllowedIPs = 10.66.66.2/32
EOF

systemctl enable awg-quick@awg0 2>/dev/null || systemctl enable wg-quick@awg0 2>/dev/null || true
systemctl restart awg-quick@awg0 2>/dev/null || systemctl restart wg-quick@awg0 2>/dev/null || true

# Клиентский конфиг AmneziaWG
AWG_CLIENT_CONF="/etc/amnezia/amneziawg/client.conf"
cat <<EOF > "$AWG_CLIENT_CONF"
[Interface]
Address = 10.66.66.2/32
PrivateKey = $AWG_CLIENT_PRIV
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
PresharedKey = $AWG_PSK
Endpoint = $CONNECT_HOST:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

success "AmneziaWG поднят на порту 51820 с защитой от цензуры и блокировкой .RU на шлюзе."

# 11. Настройка Nginx: Сайт-маскировка на порту 80 и Веб-портал на порту 8443
info "Настройка веб-сервера Nginx..."
SECRET_PORTAL_TOKEN="portal_$(openssl rand -hex 6)"
WEB_ROOT="/var/www/camouflage"
PORTAL_ROOT="/var/www/portal/$SECRET_PORTAL_TOKEN"
mkdir -p "$WEB_ROOT" "$PORTAL_ROOT"

# Сайт-маскировка для порта 80
cat <<'EOF' > "$WEB_ROOT/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Nexus Cloud Solutions</title>
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
    <h1>High-Performance Cloud Infrastructure</h1>
    <p>Next-generation distributed edge computing, low-latency microservices, and automated telemetry management.</p>
  </div>
</body>
</html>
EOF

cp "$AWG_CLIENT_CONF" "$PORTAL_ROOT/amneziawg-client.conf"
AWG_CONF_CONTENT=$(cat "$AWG_CLIENT_CONF")

# Веб-панель управления со ссылками и QR-кодами
cat <<EOF > "$PORTAL_ROOT/index.html"
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Панель управления VPN | $CONNECT_HOST</title>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
  <style>
    :root { --bg: #0b0f19; --card: #151d30; --border: #232f48; --accent: #38bdf8; --text: #f1f5f9; --sub: #94a3b8; --green: #10b981; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--text); margin: 0; padding: 24px; }
    .container { max-width: 900px; margin: 0 auto; }
    .header { text-align: center; margin-bottom: 32px; }
    .header h1 { margin: 0 0 8px 0; font-size: 2rem; color: var(--accent); }
    .badge-ru { display: inline-block; background: rgba(239, 68, 68, 0.15); color: #f87171; border: 1px solid rgba(239, 68, 68, 0.3); padding: 4px 14px; border-radius: 9999px; font-size: 0.85rem; font-weight: bold; }
    .card { background: var(--card); border: 1px solid var(--border); border-radius: 16px; padding: 24px; margin-bottom: 24px; box-shadow: 0 10px 25px rgba(0,0,0,0.3); }
    .card-title { font-size: 1.25rem; font-weight: 600; margin-bottom: 16px; display: flex; align-items: center; justify-content: space-between; }
    .qr-container { display: flex; flex-direction: column; align-items: center; background: white; padding: 16px; border-radius: 12px; width: fit-content; margin: 0 auto 16px auto; }
    .copy-box { background: #0c121e; padding: 12px; border-radius: 8px; border: 1px solid var(--border); font-family: monospace; font-size: 0.85rem; word-break: break-all; margin-bottom: 12px; color: #cbd5e1; max-height: 120px; overflow-y: auto; }
    .btn { display: inline-block; background: var(--accent); color: #000; padding: 10px 18px; border-radius: 8px; text-decoration: none; font-weight: 600; cursor: pointer; border: none; font-size: 0.9rem; transition: 0.2s; }
    .btn:hover { opacity: 0.9; }
    .btn-green { background: var(--green); color: #fff; }
    .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; }
    @media (max-width: 768px) { .grid { grid-template-columns: 1fr; } }
    .guide-item { margin-bottom: 8px; color: var(--sub); font-size: 0.9rem; }
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
        <div class="qr-container">
          <div id="vless-qr"></div>
        </div>
        <div class="copy-box" id="vless-link">$VLESS_LINK</div>
        <button class="btn" onclick="copyText('vless-link')">📋 Скопировать ссылку</button>
      </div>

      <!-- AMNEZIA WG CARD -->
      <div class="card">
        <div class="card-title">
          <span>🛡️ AmneziaWG (Анти-ТСПУ)</span>
          <span style="font-size:0.8rem; color:var(--green);">UDP 51820</span>
        </div>
        <div class="qr-container">
          <div id="awg-qr"></div>
        </div>
        <div class="copy-box" id="awg-conf">$AWG_CONF_CONTENT</div>
        <div style="display:flex; gap: 8px;">
          <button class="btn btn-green" onclick="copyText('awg-conf')">📋 Скопировать</button>
          <a class="btn" href="amneziawg-client.conf" download="amneziawg-client.conf">💾 Скачать .conf</a>
        </div>
      </div>
    </div>

    <!-- ИНСТРУКЦИЯ ПО ПРИЛОЖЕНИЯМ -->
    <div class="card">
      <div class="card-title">📱 Клиенты для подключения</div>
      <div class="guide-item"><strong>iOS:</strong> Happ, Streisand, FoXray, Amnezia VPN (App Store)</div>
      <div class="guide-item"><strong>Android:</strong> Happ, v2rayNG, Amnezia VPN (Google Play / GitHub)</div>
      <div class="guide-item"><strong>Windows / macOS:</strong> Hiddify, v2rayN, Nekoray, Amnezia VPN</div>
      <div class="guide-item" style="margin-top:12px;"><strong>Как подключить:</strong> Для VLESS скопируйте ссылку и вставьте в приложение (Импорт из буфера) или отсканируйте QR-код. Для AmneziaWG скачайте файл конфигурации либо отсканируйте QR-код через мобильное приложение Amnezia VPN.</div>
    </div>
  </div>

  <script>
    new QRCode(document.getElementById("vless-qr"), {
      text: "$VLESS_LINK",
      width: 180,
      height: 180
    });

    new QRCode(document.getElementById("awg-qr"), {
      text: document.getElementById("awg-conf").innerText,
      width: 180,
      height: 180
    });

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

# Nginx vhosts: порт 80 (маскировка) и порт 8443 (секретный портал)
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
success "Nginx настроен: маскировка на 80, секретная веб-панель на 8443."

# 12. Настройка фаервола UFW
info "Настройка портов в UFW..."
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing

# Открываем системный SSH порт
ufw allow "$RANDOM_SSH_PORT/tcp" comment "SSH Port"

# Веб-порты и сертификаты
ufw allow 80/tcp comment "HTTP (Camouflage)"
ufw allow 443/tcp comment "HTTPS (VLESS Reality)"
ufw allow 443/udp comment "QUIC / Hysteria"

# Пользовательские порты
ufw allow 8442/tcp comment "Custom 8442"
ufw allow 8443/tcp comment "Web Portal 8443"
ufw allow 10443/tcp comment "Custom 10443"

# VPN и прокси порты
ufw allow 51820/udp comment "AmneziaWG UDP"
ufw allow 8888/tcp comment "MTProto Proxy"

ufw --force enable
success "UFW активирован с необходимым набором правил."

# 13. Автообновление ядра и пакетов раз в неделю (Вс, 05:00) + Reboot
info "Настройка еженедельного автообновления и перезагрузки..."
cat <<'EOF' > /etc/cron.d/weekly_system_update
0 5 * * 0 root apt-get update && DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y && apt-get autoremove -y && apt-get clean && /sbin/reboot
EOF
chmod 644 /etc/cron.d/weekly_system_update

# 14. Финальный отчет
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

echo -e "${CYAN}--- БЫСТРАЯ ССЫЛКА VLESS REALITY ---${NC}"
echo -e "  ${YELLOW}$VLESS_LINK${NC}\n"

echo -e "${PURPLE}--- СТАТУС БЕЗОПАСНОСТИ И МАРШРУТИЗАЦИИ ---${NC}"
echo -e "  • Сайты зоны .RU, .РФ, .SU и пулы российских IP: ${RED}ЗАБЛОКИРОВАНЫ${NC}"
echo -e "  • Реклама и аналитические трекеры: ${RED}ЗАБЛОКИРОВАНЫ${NC}"
echo -e "  • Защита от блокировок AmneziaWG (DPI): ${GREEN}АКТИВНА${NC}"
echo -e "  • Автообновление ядра и сервисов: ${GREEN}Каждое воскресенье в 05:00${NC}\n"

echo -e "${RED}ВАЖНО: Не закрывайте эту сессию, пока не проверите вход по SSH в новом окне!${NC}"
