#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()   { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()     { echo -e "${GREEN}[OK]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()    { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запустите от root: sudo bash secure-server-init.sh"

# Совместимость с Debian/Ubuntu
export DEBIAN_FRONTEND=noninteractive

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
else
    die "Не найден /etc/os-release"
fi

case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "Поддерживаются только Ubuntu и Debian. Обнаружено: ${ID:-unknown}" ;;
esac

info "Система: ${PRETTY_NAME:-$ID}"

# ---------- Параметры ----------
DETECTED_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
read -rp "Внешний IP сервера [${DETECTED_IP:-не определён}]: " INPUT_IP
SERVER_IP="${INPUT_IP:-$DETECTED_IP}"
[[ -n "$SERVER_IP" ]] || die "Не удалось определить внешний IP. Укажите его вручную."

read -rp "DNS-домен сервера, если есть [можно оставить пустым]: " SERVER_DOMAIN
CONNECT_HOST="${SERVER_DOMAIN:-$SERVER_IP}"

while true; do
    read -rp "Имя нового администратора: " NEW_USER
    if [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$NEW_USER" != "root" ]]; then
        break
    fi
    warn "Имя: латиница, цифры, - или _; не root."
done

while true; do
    read -srp "Пароль для $NEW_USER: " USER_PASS; echo
    read -srp "Повторите пароль: " USER_PASS2; echo
    [[ -n "$USER_PASS" && "$USER_PASS" == "$USER_PASS2" ]] && break
    warn "Пароли пустые или не совпадают."
done

while true; do
    read -srp "Новый пароль root: " ROOT_PASS; echo
    read -srp "Повторите пароль root: " ROOT_PASS2; echo
    [[ -n "$ROOT_PASS" && "$ROOT_PASS" == "$ROOT_PASS2" ]] && break
    warn "Пароли пустые или не совпадают."
done

RANDOM_SSH_PORT="$(shuf -i 10001-65535 -n 1)"
info "SSH будет переведён на порт $RANDOM_SSH_PORT"

# ---------- Обновление и пакеты ----------
info "Обновление системы..."
apt-get update
apt-get -y upgrade
apt-get -y install --no-install-recommends \
    sudo curl wget ca-certificates gnupg lsb-release \
    rsyslog fail2ban ufw unattended-upgrades \
    apt-listchanges needrestart cron jq qrencode

# ---------- Пользователи ----------
echo "root:${ROOT_PASS}" | chpasswd
ok "Пароль root изменён."

if ! id "$NEW_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$NEW_USER"
fi
echo "${NEW_USER}:${USER_PASS}" | chpasswd

if ! id -nG "$NEW_USER" | grep -qw sudo; then
    usermod -aG sudo "$NEW_USER"
fi

install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "/home/$NEW_USER/.ssh"
if [[ -f /root/.ssh/authorized_keys ]]; then
    cp /root/.ssh/authorized_keys "/home/$NEW_USER/.ssh/authorized_keys"
    chown "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh/authorized_keys"
    chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"
    ok "SSH-ключи root скопированы пользователю $NEW_USER."
else
    warn "У root нет authorized_keys: вход будет по паролю, пока вы не добавите ключ."
fi

# ---------- SSH ----------
SSHD_DIR=/etc/ssh/sshd_config.d
mkdir -p "$SSHD_DIR"
BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
cp -a /etc/ssh/sshd_config "$BACKUP" 2>/dev/null || true

cat > "$SSHD_DIR/99-hardening.conf" <<EOF
Port ${RANDOM_SSH_PORT}
PermitRootLogin no
AllowUsers ${NEW_USER}
PasswordAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 5
ClientAliveInterval 300
ClientAliveCountMax 3
X11Forwarding no
EOF

chmod 600 "$SSHD_DIR/99-hardening.conf"

if ! sshd -t; then
    warn "Конфиг SSH некорректен, откат."
    rm -f "$SSHD_DIR/99-hardening.conf"
    sshd -t || true
    RANDOM_SSH_PORT=22
fi

# Сначала открываем новый порт, затем перезапускаем SSH
ufw allow "${RANDOM_SSH_PORT}/tcp" comment 'SSH custom port' >/dev/null

if systemctl list-unit-files | grep -q '^ssh\.socket'; then
    systemctl enable --now ssh.socket || true
    systemctl restart ssh.socket || true
else
    systemctl enable --now ssh || systemctl enable --now sshd || true
    systemctl restart ssh || systemctl restart sshd || true
fi

ss -ltnp | grep -q ":${RANDOM_SSH_PORT} " \
    || warn "Порт $RANDOM_SSH_PORT пока не слушается. НЕ закрывайте текущую SSH-сессию и проверьте статус службы."

ok "SSH настроен на порту $RANDOM_SSH_PORT, root-вход отключён."

# ---------- rsyslog и Fail2ban ----------
systemctl enable --now rsyslog || true

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 10m
findtime = 10m
maxretry = 5
backend = auto

[sshd]
enabled = true
port = ${RANDOM_SSH_PORT}
filter = sshd
logpath = /var/log/auth.log
backend = systemd
maxretry = 5
bantime = 1h
findtime = 10m
EOF

systemctl enable --now fail2ban || true
systemctl restart fail2ban || true
fail2ban-client ping >/dev/null 2>&1 && ok "Fail2ban работает." || warn "Fail2ban не ответил: проверьте journalctl -u fail2ban"

# ---------- UFW ----------
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null

# Порт 22 больше не нужен, если SSH реально переехал
if [[ "$RANDOM_SSH_PORT" != "22" ]]; then
    ufw delete allow ssh >/dev/null 2>&1 || true
    ufw delete allow 22/tcp >/dev/null 2>&1 || true
fi

ufw allow "${RANDOM_SSH_PORT}/tcp" comment 'SSH' >/dev/null
ufw allow 80/tcp comment 'HTTP' >/dev/null
ufw allow 443/tcp comment 'HTTPS / VLESS' >/dev/null
ufw allow 443/udp comment 'QUIC / HTTP3' >/dev/null
ufw allow 8442/tcp comment 'Reserved service' >/dev/null
ufw allow 8443/tcp comment 'Web portal' >/dev/null
ufw allow 10443/tcp comment 'Reserved service' >/dev/null

# Будущие VPN-сервисы
ufw allow 51820/udp comment 'WireGuard / AmneziaWG' >/dev/null
ufw allow 8888/tcp comment 'MTProto proxy' >/dev/null

ufw --force enable >/dev/null
ufw status verbose

# ---------- Ядро и безопасность ----------
cat > /etc/sysctl.d/99-server-hardening.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

sysctl --system >/dev/null || true

# ---------- Автообновления ----------
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id} ESMServices:${distro_codename}";
    "${distro_id} ESMApps:${distro_codename}-apps-security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

systemctl enable --now unattended-upgrades || true

# Опциональная еженедельная перезагрузка в 05:00 воскресенья
read -rp "Включить еженедельную перезагрузку сервера в 05:00 воскресенья? [y/N]: " REBOOT_CHOICE
if [[ "${REBOOT_CHOICE,,}" == "y" ]]; then
    cat > /etc/cron.d/weekly-server-reboot <<'EOF'
0 5 * * 0 root /sbin/shutdown -r now
EOF
    chmod 644 /etc/cron.d/weekly-server-reboot
    ok "Еженедельная перезагрузка включена."
else
    ok "Автоматическая перезагрузка не включена."
fi

# ---------- Проверки ----------
systemctl is-active --quiet ssh || systemctl is-active --quiet sshd || warn "SSH не активен"
systemctl is-active --quiet fail2ban || warn "Fail2ban не активен"
ufw status | grep -qw active || warn "UFW не активен"

cat <<EOF

============================================================
НАСТРОЙКА ЗАВЕРШЕНА
============================================================
Подключение SSH:

    ssh -p ${RANDOM_SSH_PORT} ${NEW_USER}@${CONNECT_HOST}
    ssh -p ${RANDOM_SSH_PORT} ${NEW_USER}@${SERVER_IP}

ВАЖНО: откройте новое окно терминала и проверьте вход,
не закрывая текущую root-сессию.

Файлы:
    /etc/ssh/sshd_config.d/99-hardening.conf
    /etc/fail2ban/jail.local
    /etc/apt/apt.conf.d/20auto-upgrades
============================================================
EOF