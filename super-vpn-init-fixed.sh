```bash
#!/usr/bin/env bash
# ==================================================================
#  Server setup: hardening + Xray (Reality/XHTTP/WARP) + WireGuard
#  + MTProto + HTTPS-панель + меню "vpn".   Ubuntu / Debian
# ==================================================================
set -Eeuo pipefail
trap 'echo -e "\e[31m[ОШИБКА] строка $LINENO: \"$BASH_COMMAND\"\e[0m"' ERR

G="\e[32m"; Y="\e[33m"; R="\e[31m"; B="\e[36m"; N="\e[0m"
ok()   { echo -e "${G}[OK]${N} $*"; }
info() { echo -e "${B}[..]${N} $*"; }
warn() { echo -e "${Y}[!!]${N} $*"; }
die()  { echo -e "${R}[XX]${N} $*"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

XRAY_PORT=443; XHTTP_PORT=8442; MTG_PORT=8443
WG_PORT=51820; AWG_PORT=51821; WEB_LOCAL_PORT=8001
EXTRA_TCP=(80 443 8442 8443 10443)

[[ $EUID -eq 0 ]] || die "Запусти от root: sudo bash $0"
[[ -r /etc/os-release ]] || die "Нет /etc/os-release"
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ok "Дистрибутив: $PRETTY_NAME" ;;
  *) [[ "${ID_LIKE:-}" == *debian* ]] && warn "Debian-подобная система: $PRETTY_NAME" || die "Только Ubuntu/Debian" ;;
esac

ask() { local prompt="$1" var="$2" def="${3:-}" val
  if [[ -n $def ]]; then read -rp "$prompt [$def]: " val </dev/tty; val="${val:-$def}"
  else read -rp "$prompt: " val </dev/tty; fi
  printf -v "$var" '%s' "$val"; }
ask_pass() { local p1 p2
  while true; do
    read -rsp "$1: " p1 </dev/tty; echo
    read -rsp "Повтори пароль: " p2 </dev/tty; echo
    [[ -z $p1 ]] && { warn "Пароль пустой"; continue; }
    [[ $p1 != "$p2" ]] && { warn "Не совпадают"; continue; }
    printf -v "$2" '%s' "$p1"; return
  done; }
yesno() { local a d="${2:-N}" hint="y/N"; [[ $d == Y ]] && hint="Y/n"
  read -rp "$1 [$hint]: " a </dev/tty; a="${a:-$d}"; [[ $a =~ ^[YyДд] ]]; }

# ------------------------- ввод данных -------------------------
echo -e "\n${B}=== Ввод данных ===${N}"
while true; do
  ask "Имя нового администратора" NEWUSER
  [[ $NEWUSER =~ ^[a-z_][a-z0-9_-]{0,31}$ && $NEWUSER != root ]] && break
  warn "Строчные латинские буквы/цифры/_/-, не root"
done
ask_pass "Пароль для $NEWUSER" USERPASS
ask_pass "НОВЫЙ пароль для root" ROOTPASS

DETECTED_IP=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
while true; do
  ask "Статичный IP сервера" SERVER_IP "$DETECTED_IP"
  [[ $SERVER_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
  warn "Неверный IPv4"
done
while true; do
  ask "Домен (A-запись -> $SERVER_IP, в Cloudflare только DNS only)" DOMAIN
  [[ -n $DOMAIN && ! $DOMAIN =~ ^[0-9.]+$ && $DOMAIN == *.* ]] && break
  warn "Нужен именно домен (например vpn.example.com)"
done
RESOLVED=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)
if [[ $RESOLVED != "$SERVER_IP" ]]; then
  warn "Домен резолвится в '${RESOLVED:-ничего}', а не в $SERVER_IP"
  yesno "Продолжить (сертификат тогда будет самоподписанным)?" N || die "Поправь DNS и запусти снова"
fi
ask "Email для сертификатов (Let's Encrypt / ZeroSSL, лучше указать)" LE_EMAIL ""

INSTALL_WARP=0; INSTALL_WG=0; INSTALL_MTG=0
yesno "Установить WARP (клиент 'warp' с выходом через Cloudflare)?" Y && INSTALL_WARP=1
yesno "Установить WireGuard (файл для Keenetic)?" Y               && INSTALL_WG=1
yesno "Установить MTProto-прокси для Telegram (Docker)?" Y        && INSTALL_MTG=1

# --- SSH порт: при повторном запуске оставляем прежний ---
SSH_PORT=""
if [[ -f /etc/vpnpanel/state.env ]]; then
  OLD_PORT=$(grep -E '^SSH_PORT=' /etc/vpnpanel/state.env | tr -dc '0-9' || true)
  if [[ $OLD_PORT =~ ^[0-9]+$ ]] && (( OLD_PORT >= 10001 && OLD_PORT <= 65535 )); then
    SSH_PORT=$OLD_PORT
    ok "Найдена прошлая установка — оставляю SSH порт $SSH_PORT"
  fi
fi
if [[ -z $SSH_PORT ]]; then
  RESERVED=" $WG_PORT $AWG_PORT 10443 "
  while true; do
    SSH_PORT=$(shuf -i 10001-65535 -n 1)
    [[ $RESERVED == *" $SSH_PORT "* ]] && continue
    ss -ltn | awk '{print $4}' | grep -qE ":${SSH_PORT}$" && continue
    break
  done
  ok "SSH порт: $SSH_PORT"
fi

# ------------------------- пакеты -------------------------
info "apt update + full-upgrade..."
apt-get update -y
apt-get "${APT_OPTS[@]}" full-upgrade
apt-get "${APT_OPTS[@]}" install sudo curl wget ca-certificates openssl rsyslog fail2ban ufw \
        openssh-server iproute2 cron qrencode unzip jq nginx certbot gnupg
systemctl enable --now rsyslog cron >/dev/null 2>&1 || true
rm -f /etc/nginx/sites-enabled/default
ok "Пакеты установлены"

# ------------------------- пользователи -------------------------
if id "$NEWUSER" &>/dev/null; then warn "$NEWUSER уже есть - обновляю пароль"
else adduser --disabled-password --gecos "" "$NEWUSER"; fi
echo "$NEWUSER:$USERPASS" | chpasswd
usermod -aG sudo "$NEWUSER"
echo "root:$ROOTPASS" | chpasswd
ok "Пользователь $NEWUSER (sudo) создан, пароль root изменён"

# ------------------------- SSH -------------------------
info "Настройка SSH..."
cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)
mkdir -p /etc/ssh/sshd_config.d
sed -i -E 's/^\s*(Port|PermitRootLogin|AllowUsers)\s+/#&/' /etc/ssh/sshd_config
grep -qE '^\s*Include\s+/etc/ssh/sshd_config.d' /etc/ssh/sshd_config || \
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
Port $SSH_PORT
PermitRootLogin no
AllowUsers $NEWUSER
PasswordAuthentication yes
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 4
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
sshd -t || die "Ошибка конфига sshd"

# ------------------------- UFW (до рестарта sshd) -------------------------
info "Настройка UFW..."
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
for p in "${EXTRA_TCP[@]}"; do ufw allow "${p}/tcp" >/dev/null; done
ufw allow "${WG_PORT}/udp"  comment 'WireGuard' >/dev/null
ufw allow "${AWG_PORT}/udp" comment 'AmneziaWG' >/dev/null
ufw --force enable >/dev/null
ok "UFW включён"

if systemctl list-unit-files | grep -q '^ssh.socket'; then
  systemctl disable --now ssh.socket >/dev/null 2>&1 || true
fi
systemctl enable ssh >/dev/null 2>&1 || true
systemctl restart ssh; sleep 2
ss -ltn | grep -q ":${SSH_PORT}\b" && ok "sshd слушает $SSH_PORT" || die "sshd не слушает $SSH_PORT"

# ------------------------- Fail2ban -------------------------
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 10m
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
backend = auto
logpath = /var/log/auth.log
maxretry = 5
bantime = 1h
findtime = 10m
EOF
touch /var/log/auth.log
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban; sleep 3
fail2ban-client status sshd >/dev/null 2>&1 && ok "Fail2ban: jail sshd активен" || warn "Fail2ban: смотри journalctl -u fail2ban"

# ------------------------- sysctl -------------------------
cat > /etc/sysctl.d/99-vpn.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl --system >/dev/null
ok "sysctl: BBR + ip_forward"

# ==================================================================
#  Библиотека и меню (ставятся в систему)
# ==================================================================
mkdir -p /etc/vpnpanel /usr/local/lib/vpnpanel /var/www/vpn
chmod 700 /etc/vpnpanel

cat > /usr/local/lib/vpnpanel/lib.sh <<'LIB_EOF'
#!/usr/bin/env bash
PANEL_DIR=/etc/vpnpanel
STATE=$PANEL_DIR/state.env
CLIENTS=$PANEL_DIR/clients.json
WGPEERS=$PANEL_DIR/wg_peers.json
WARPJSON=$PANEL_DIR/warp.json
XBIN=/usr/local/bin/xray
XRAY_CFG=/usr/local/etc/xray/config.json
WEBROOT=/var/www/vpn
CERT_LOG=/var/log/vpnpanel-certbot.log

if [[ -z ${G:-} ]]; then G="\e[32m"; Y="\e[33m"; R="\e[31m"; B="\e[36m"; N="\e[0m"; fi
ok()   { echo -e "${G}[OK]${N} $*"; }
info() { echo -e "${B}[..]${N} $*"; }
warn() { echo -e "${Y}[!!]${N} $*"; }
err()  { echo -e "${R}[XX]${N} $*"; }

load_state() { if [[ -f $STATE ]]; then . "$STATE"; fi; return 0; }
set_state() {
  local k="$1" v="$2"; touch "$STATE"
  grep -v "^${k}=" "$STATE" > "$STATE.tmp" || true
  echo "${k}=\"${v}\"" >> "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"; chmod 600 "$STATE"
}
uuid()       { cat /proc/sys/kernel/random/uuid; }
valid_name() { [[ $1 =~ ^[A-Za-z0-9_-]{1,32}$ ]]; }
jq_edit()    { local f="$1"; shift; jq "$@" "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }
hesc()       { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
port_tcp()   { ss -ltn | awk '{print $4}' | grep -qE "[:.]$1\$"; }
port_udp()   { ss -lun | awk '{print $5}' | grep -qE "[:.]$1\$"; }
web_url()    { load_state; echo "https://${DOMAIN}/${WEB_TOKEN}/"; }

# ------------------------- XRAY -------------------------
xray_build() {
  load_state
  local warp=false warpout=null new="/usr/local/etc/xray/config.new.json" out
  if [[ -s $WARPJSON ]]; then warp=true; warpout=$(cat "$WARPJSON"); fi
  jq -n \
    --argjson clients "$(cat "$CLIENTS")" \
    --argjson tcpport "$XRAY_PORT" --argjson xport "$XHTTP_PORT" \
    --arg dest "127.0.0.1:${WEB_LOCAL_PORT}" --arg sni "$DOMAIN" \
    --arg priv "$REALITY_PRIV" --arg sid "$REALITY_SID" --arg path "$XHTTP_PATH" \
    --argjson warp "$warp" --argjson warpout "$warpout" '
    def reality: {show:false, dest:$dest, xver:0, serverNames:[$sni], privateKey:$priv, shortIds:[$sid]};
    def sniff: {enabled:true, destOverride:["http","tls","quic"], routeOnly:true};
    ($clients|map(select(.transport=="tcp")))   as $tcp |
    ($clients|map(select(.transport=="xhttp"))) as $xh  |
    ($clients|map(select(.warp==true))|map(.name)) as $wu |
    {
      log: {loglevel:"warning"},
      inbounds: (
        [ {tag:"vless-tcp", listen:"0.0.0.0", port:$tcpport, protocol:"vless",
           settings:{decryption:"none", clients:($tcp|map({id:.uuid, flow:"xtls-rprx-vision", email:.name}))},
           streamSettings:{network:"tcp", security:"reality", realitySettings:reality},
           sniffing:sniff} ]
        + ( if ($xh|length) > 0 then
            [ {tag:"vless-xhttp", listen:"0.0.0.0", port:$xport, protocol:"vless",
               settings:{decryption:"none", clients:($xh|map({id:.uuid, email:.name}))},
               streamSettings:{network:"xhttp", security:"reality", realitySettings:reality,
                               xhttpSettings:{path:$path, mode:"auto"}},
               sniffing:sniff} ]
            else [] end ) ),
      outbounds: ( [{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"block"}]
                   + ( if $warp then [$warpout] else [] end ) ),
      routing: { domainStrategy:"IPIfNonMatch",
        rules: ( [ {type:"field", ip:["geoip:private"], outboundTag:"block"},
                   {type:"field", protocol:["bittorrent"], outboundTag:"block"} ]
                 + ( if ($warp and (($wu|length) > 0))
                     then [ {type:"field", user:$wu, outboundTag:"warp"} ] else [] end ) ) }
    }' > "$new" || { err "jq: не удалось собрать конфиг Xray"; return 1; }
  if ! out=$($XBIN run -test -format json -config "$new" 2>&1); then
    echo "$out"; rm -f "$new"; err "Конфиг Xray невалиден"; return 1
  fi
  mv "$new" "$XRAY_CFG"; chmod 644 "$XRAY_CFG"
}
xray_apply() {
  xray_build || return 1
  systemctl enable xray >/dev/null 2>&1
  systemctl restart xray; sleep 2
  systemctl is-active --quiet xray
}
vless_link() {
  load_state
  local row id tr
  row=$(jq -r --arg n "$1" '.[]|select(.name==$n)|[.uuid,.transport]|@tsv' "$CLIENTS")
  [[ -n $row ]] || return 1
  IFS=$'\t' read -r id tr <<<"$row"
  local base="encryption=none&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}"
  if [[ $tr == tcp ]]; then
    echo "vless://${id}@${DOMAIN}:${XRAY_PORT}?${base}&flow=xtls-rprx-vision&type=tcp&headerType=none#${DOMAIN}-${1}"
  else
    echo "vless://${id}@${DOMAIN}:${XHTTP_PORT}?${base}&type=xhttp&path=${XHTTP_PATH//\//%2F}&mode=auto#${DOMAIN}-${1}"
  fi
}
xray_add_client() { # name transport(tcp|xhttp) warp(true|false)
  local n="$1" t="$2" w="${3:-false}"
  valid_name "$n" || { err "Имя: латиница/цифры/-/_ до 32 символов"; return 1; }
  [[ $t == tcp || $t == xhttp ]] || { err "Транспорт: tcp или xhttp"; return 1; }
  if jq -e --arg n "$n" '.[]|select(.name==$n)' "$CLIENTS" >/dev/null; then err "Клиент $n уже есть"; return 1; fi
  if [[ $w == true && ! -s $WARPJSON ]]; then err "WARP не установлен"; return 1; fi
  jq_edit "$CLIENTS" --arg n "$n" --arg u "$(uuid)" --arg t "$t" --argjson w "$w" \
     '. + [{name:$n,uuid:$u,transport:$t,warp:$w}]'
  xray_apply
}
xray_del_client() {
  local n="$1" tr cnt
  tr=$(jq -r --arg n "$n" '.[]|select(.name==$n)|.transport' "$CLIENTS")
  [[ -n $tr ]] || { err "Нет клиента $n"; return 1; }
  if [[ $tr == tcp ]]; then
    cnt=$(jq '[.[]|select(.transport=="tcp")]|length' "$CLIENTS")
    (( cnt > 1 )) || { err "Нельзя удалить последнего tcp-клиента (на 443 держится сайт)"; return 1; }
  fi
  jq_edit "$CLIENTS" --arg n "$n" 'map(select(.name!=$n))' && xray_apply
}

# ------------------------- WARP (wgcf -> outbound wireguard) -------------------------
warp_setup() {
  local arch ver d prof priv pub ep addr4 devid token cid r reserved="[0,0,0]" i
  case "$(uname -m)" in
    x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; armv7l) arch=armv7;;
    *) warn "Архитектура не поддерживается wgcf"; return 1;;
  esac
  ver=$(curl -fsSL --max-time 10 https://api.github.com/repos/ViRb3/wgcf/releases/latest 2>/dev/null | jq -r .tag_name 2>/dev/null || true)
  [[ $ver =~ ^v[0-9.]+$ ]] || ver=v2.2.22
  info "Скачиваю wgcf $ver..."
  curl -fsSL -o /usr/local/bin/wgcf "https://github.com/ViRb3/wgcf/releases/download/${ver}/wgcf_${ver#v}_linux_${arch}" || { warn "Не скачался wgcf"; return 1; }
  chmod +x /usr/local/bin/wgcf
  d=$PANEL_DIR/warp; mkdir -p "$d"; chmod 700 "$d"
  rm -f "$d/wgcf-account.toml" "$d/wgcf-profile.conf"
  for i in 1 2 3 4 5; do
    wgcf register --accept-tos --config "$d/wgcf-account.toml" >/dev/null 2>&1 && break
    sleep $((i*4))
  done
  [[ -s $d/wgcf-account.toml ]] || { warn "Cloudflare не дал зарегистрировать WARP (повтори позже: sudo vpn)"; return 1; }
  wgcf generate --config "$d/wgcf-account.toml" --profile "$d/wgcf-profile.conf" >/dev/null 2>&1 || return 1
  prof="$d/wgcf-profile.conf"
  priv=$(sed -nE 's/^PrivateKey *= *//p' "$prof" | tr -d '\r ')
  pub=$(sed -nE 's/^PublicKey *= *//p' "$prof" | tr -d '\r ')
  ep=$(sed -nE 's/^Endpoint *= *//p' "$prof" | tr -d '\r ')
  addr4=$(sed -nE 's/^Address *= *//p' "$prof" | tr ',' '\n' | tr -d ' \r' | grep -E '^[0-9]+\.' | head -1)
  [[ -n $priv && -n $pub && -n $ep && -n $addr4 ]] || { warn "Не разобрался профиль WARP"; return 1; }
  devid=$(sed -nE "s/^device_id *= *'(.*)'/\1/p" "$d/wgcf-account.toml")
  token=$(sed -nE "s/^access_token *= *'(.*)'/\1/p" "$d/wgcf-account.toml")
  cid=$(curl -fsS --max-time 10 -H "Authorization: Bearer $token" -H "User-Agent: okhttp/3.12.1" \
        -H "CF-Client-Version: a-6.3-1922" "https://api.cloudflareclient.com/v0a2158/reg/$devid" 2>/dev/null \
        | jq -r '.config.client_id // empty' 2>/dev/null || true)
  if [[ -n $cid ]]; then
    r=$(printf '%s' "$cid" | base64 -d 2>/dev/null | od -An -tu1 | xargs | tr ' ' ',' || true)
    [[ $r =~ ^[0-9]+,[0-9]+,[0-9]+$ ]] && reserved="[$r]"
  fi
  jq -n --arg k "$priv" --arg a "$addr4" --arg pub "$pub" --arg ep "$ep" --argjson res "$reserved" '
    {tag:"warp", protocol:"wireguard",
     settings:{secretKey:$k, address:[$a],
               peers:[{publicKey:$pub, allowedIPs:["0.0.0.0/0"], endpoint:$ep}],
               mtu:1280, reserved:$res, domainStrategy:"ForceIPv4", noKernelTun:true}}' > "$WARPJSON"
  chmod 600 "$WARPJSON"
  ok "WARP зарегистрирован (reserved=$reserved)"
}

# ------------------------- WIREGUARD -------------------------
wg_build() {
  load_state
  {
    cat <<EOF
[Interface]
Address = ${WG_NET}.1/24
ListenPort = $WG_PORT
PrivateKey = $WG_SRV_PRIV
PostUp   = iptables -I FORWARD 1 -i wg0 -j ACCEPT; iptables -I FORWARD 1 -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -s ${WG_NET}.0/24 ! -o wg0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -s ${WG_NET}.0/24 ! -o wg0 -j MASQUERADE
EOF
    jq -r --arg net "$WG_NET" '.[]|"\n[Peer]\n# \(.name)\nPublicKey = \(.pub)\nAllowedIPs = \($net).\(.ip)/32"' "$WGPEERS"
  } > /etc/wireguard/wg0.conf
  chmod 600 /etc/wireguard/wg0.conf
}
wg_apply() {
  wg_build
  if ip link show wg0 >/dev/null 2>&1; then wg syncconf wg0 <(wg-quick strip wg0)
  else systemctl restart wg-quick@wg0; fi
}
wg_client_conf() { # name
  load_state
  local row ip priv
  row=$(jq -r --arg n "$1" '.[]|select(.name==$n)|[.ip,.priv]|@tsv' "$WGPEERS")
  [[ -n $row ]] || return 1
  IFS=$'\t' read -r ip priv <<<"$row"
  cat <<EOF
[Interface]
PrivateKey = $priv
Address = ${WG_NET}.${ip}/32
DNS = 1.1.1.1, 1.0.0.1

[Peer]
PublicKey = $WG_SRV_PUB
Endpoint = ${SERVER_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
}
wg_add_peer() {
  load_state
  local name="$1" ip priv pub
  valid_name "$name" || { err "Неверное имя"; return 1; }
  if jq -e --arg n "$name" '.[]|select(.name==$n)' "$WGPEERS" >/dev/null; then err "Пир $name уже есть"; return 1; fi
  ip=$(jq -r '(([.[].ip]|max) // 1) + 1' "$WGPEERS")
  (( ip <= 254 )) || { err "Закончились адреса"; return 1; }
  priv=$(wg genkey); pub=$(printf '%s' "$priv" | wg pubkey)
  jq_edit "$WGPEERS" --arg n "$name" --argjson ip "$ip" --arg pr "$priv" --arg pu "$pub" \
     '. + [{name:$n,ip:$ip,priv:$pr,pub:$pu}]'
  wg_apply
}
wg_del_peer() {
  jq -e --arg n "$1" '.[]|select(.name==$n)' "$WGPEERS" >/dev/null || { err "Нет пира $1"; return 1; }
  jq_edit "$WGPEERS" --arg n "$1" 'map(select(.name!=$n))' && wg_apply
}
wg_install() {
  load_state
  info "Установка WireGuard..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard wireguard-tools >/dev/null
  if [[ -z ${WG_SRV_PRIV:-} ]]; then
    local priv pub; priv=$(wg genkey); pub=$(printf '%s' "$priv" | wg pubkey)
    set_state WG_SRV_PRIV "$priv"; set_state WG_SRV_PUB "$pub"
  fi
  set_state WG_ENABLED 1; load_state
  systemctl enable wg-quick@wg0 >/dev/null 2>&1
  if [[ $(jq length "$WGPEERS") -eq 0 ]]; then wg_add_peer keenetic; else wg_apply; fi
}

# ------------------------- MTProto -------------------------
mtg_install() {
  load_state
  command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker >/dev/null 2>&1
  docker pull nineseconds/mtg:2 >/dev/null
  if [[ -z ${MTG_SECRET:-} ]]; then
    set_state MTG_SECRET "$(docker run --rm nineseconds/mtg:2 generate-secret --hex www.google.com)"; load_state
  fi
  mkdir -p /opt/mtg
  cat > /opt/mtg/config.toml <<EOF
secret = "$MTG_SECRET"
bind-to = "0.0.0.0:3128"
EOF
  docker rm -f mtg >/dev/null 2>&1 || true
  docker run -d --name mtg --restart always -p "${MTG_PORT}:3128" \
     -v /opt/mtg/config.toml:/config.toml:ro nineseconds/mtg:2 run /config.toml >/dev/null
  set_state MTG_ENABLED 1
}

# ------------------------- NGINX -------------------------
stub_page() {
  mkdir -p /var/www/stub
  cat > /var/www/stub/index.html <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><title>Welcome</title>
<style>body{font-family:sans-serif;background:#f5f5f5;color:#333;display:grid;place-items:center;height:100vh;margin:0}</style></head>
<body><div><h1>It works</h1><p>Site is under construction.</p></div></body></html>
EOF
}
nginx_write() {
  load_state
  local mode="${1:-full}"
  [[ -n ${CERT_FULL:-} ]] || mode=http
  mkdir -p /var/www/letsencrypt "$WEBROOT"
  [[ -f /var/www/stub/index.html ]] || stub_page
  {
    cat <<EOF
server {
    listen 80 default_server;
    server_name _;
    return 444;
}
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/letsencrypt; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
    if [[ $mode == full ]]; then
      cat <<EOF
server {
    listen 127.0.0.1:${WEB_LOCAL_PORT} ssl http2 default_server;
    server_name $DOMAIN;
    server_tokens off;
    ssl_certificate $CERT_FULL;
    ssl_certificate_key $CERT_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:5m;
    ssl_session_timeout 1d;
    root /var/www/stub;
    index index.html;
    location = /robots.txt { default_type text/plain; return 200 "User-agent: *\nDisallow: /\n"; }
EOF
      if [[ ${WEB_ENABLED:-1} == 1 ]]; then
        cat <<EOF
    location = /${WEB_TOKEN}/sub.txt {
        alias $WEBROOT/${WEB_TOKEN}/sub.txt;
        default_type text/plain;
        access_log off;
        add_header Cache-Control "no-store" always;
    }
    location ^~ /${WEB_TOKEN}/ {
        alias $WEBROOT/${WEB_TOKEN}/;
        index index.html;
        access_log off;
        add_header Cache-Control "no-store" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
    }
EOF
      fi
      echo "}"
    fi
  } > /etc/nginx/conf.d/vpnpanel.conf
  if nginx -t >/dev/null 2>&1; then systemctl reload nginx 2>/dev/null || systemctl restart nginx
  else nginx -t; return 1; fi
}

# ------------------------- СЕРТИФИКАТЫ -------------------------
# 1) Let's Encrypt (certbot)  2) ZeroSSL (acme.sh)  3) самоподписанный + автоповтор
cert_try_le() {
  load_state
  local emailarg=(--register-unsafely-without-email)
  [[ -n ${LE_EMAIL:-} ]] && emailarg=(-m "$LE_EMAIL")
  if certbot certonly --webroot -w /var/www/letsencrypt -d "$DOMAIN" --non-interactive \
       --agree-tos "${emailarg[@]}" >>"$CERT_LOG" 2>&1; then
    set_state CERT_FULL "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    set_state CERT_KEY  "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    set_state CERT_MODE letsencrypt
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
    ok "Сертификат Let's Encrypt получен"
    return 0
  fi
  local ra
  ra=$(grep -oE 'retry after [0-9: -]+ UTC' "$CERT_LOG" | tail -1 || true)
  if grep -qiE 'too many certificates|rate limit' "$CERT_LOG"; then
    warn "Let's Encrypt: лимит выпуска для домена ${ra:+($ra)}"
  else
    warn "Let's Encrypt не выдал сертификат (лог: $CERT_LOG)"
  fi
  return 1
}
cert_try_zerossl() {
  load_state
  local acme=/root/.acme.sh/acme.sh email="${LE_EMAIL:-}" rc
  [[ -n $email ]] || email="admin@${DOMAIN}"
  if [[ ! -x $acme ]]; then
    info "Ставлю acme.sh (для ZeroSSL)..."
    curl -fsSL https://get.acme.sh 2>>"$CERT_LOG" | sh -s email="$email" >>"$CERT_LOG" 2>&1 || true
  fi
  [[ -x $acme ]] || { warn "acme.sh не установился"; return 1; }
  "$acme" --set-default-ca --server zerossl >>"$CERT_LOG" 2>&1 || true
  "$acme" --register-account -m "$email" --server zerossl >>"$CERT_LOG" 2>&1 || true
  "$acme" --issue -d "$DOMAIN" -w /var/www/letsencrypt --server zerossl --keylength ec-256 \
      >>"$CERT_LOG" 2>&1 && rc=0 || rc=$?
  if [[ $rc -ne 0 && $rc -ne 2 ]]; then warn "ZeroSSL не выдал сертификат (лог: $CERT_LOG)"; return 1; fi
  mkdir -p "$PANEL_DIR/cert"; chmod 700 "$PANEL_DIR/cert"
  "$acme" --install-cert -d "$DOMAIN" --ecc \
      --fullchain-file "$PANEL_DIR/cert/fullchain.pem" --key-file "$PANEL_DIR/cert/privkey.pem" \
      --reloadcmd "systemctl reload nginx" >>"$CERT_LOG" 2>&1 || { warn "Не удалось установить сертификат ZeroSSL"; return 1; }
  set_state CERT_FULL "$PANEL_DIR/cert/fullchain.pem"
  set_state CERT_KEY  "$PANEL_DIR/cert/privkey.pem"
  set_state CERT_MODE zerossl
  ok "Сертификат ZeroSSL получен"
  return 0
}
cert_issue() { cert_try_le && return 0; info "Пробую ZeroSSL..."; cert_try_zerossl && return 0; return 1; }
cert_selfsigned() {
  load_state
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" \
    -keyout "$PANEL_DIR/self.key" -out "$PANEL_DIR/self.crt" >/dev/null 2>&1
  chmod 600 "$PANEL_DIR/self.key"
  set_state CERT_FULL "$PANEL_DIR/self.crt"; set_state CERT_KEY "$PANEL_DIR/self.key"
  set_state CERT_MODE selfsigned
}
cert_setup() {
  load_state
  : > "$CERT_LOG"
  nginx_write http
  systemctl restart nginx
  if cert_issue; then return 0; fi
  warn "Настоящий сертификат пока получить не удалось. Ставлю самоподписанный."
  cert_selfsigned
  echo "*/30 * * * * root /usr/local/bin/vpn certretry >>/var/log/vpnpanel-certretry.log 2>&1" > /etc/cron.d/vpn-cert-retry
  chmod 644 /etc/cron.d/vpn-cert-retry
  warn "Каждые 30 минут буду пробовать снова автоматически (или вручную: sudo vpn certretry)"
}
cert_retry() {
  load_state
  if [[ ${CERT_MODE:-} == letsencrypt || ${CERT_MODE:-} == zerossl ]]; then
    rm -f /etc/cron.d/vpn-cert-retry; ok "Настоящий сертификат уже установлен (${CERT_MODE})"; return 0
  fi
  info "Пробую получить настоящий сертификат..."
  : > "$CERT_LOG"
  if cert_issue; then
    load_state; nginx_write full; site_build
    rm -f /etc/cron.d/vpn-cert-retry
    ok "Готово: HTTPS теперь с настоящим сертификатом"
  else
    warn "Не получилось, попробую позже"; return 1
  fi
}

# ------------------------- САЙТ -------------------------
site_build() {
  load_state
  find "$WEBROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  if [[ ${WEB_ENABLED:-1} != 1 ]]; then nginx_write full; return 0; fi
  local dir="$WEBROOT/$WEB_TOKEN"
  mkdir -p "$dir/files" "$dir/qr"
  local XC="" WC="" MC="" links="" name tr warp ip link e wb label

  while IFS=$'\t' read -r name tr warp; do
    link=$(vless_link "$name")
    links+="$link"$'\n'
    qrencode -t SVG -m 2 -o "$dir/qr/x-$name.svg" "$link"
    e=$(printf '%s' "$link" | hesc)
    if [[ $tr == tcp ]]; then label="Reality · Vision · TCP"; else label="Reality · XHTTP"; fi
    wb=""; [[ $warp == true ]] && wb=' <span class="badge warp">через WARP</span>'
    XC+=$(cat <<EOF
<div class="card" data-name="$name"><h3>$name <span class="badge">$label</span>$wb</h3>
<div class="link" id="lx-$name">$e</div>
<div class="row"><button data-copy="#lx-$name">Копировать ссылку</button><button data-qr="#qx-$name">QR-код</button></div>
<div class="qr" id="qx-$name"><img src="qr/x-$name.svg" alt="QR $name" loading="lazy"></div></div>
EOF
)
  done < <(jq -r '.[]|[.name,.transport,(.warp|tostring)]|@tsv' "$CLIENTS")
  printf '%s' "$links" | base64 -w0 > "$dir/sub.txt"

  if [[ ${WG_ENABLED:-0} == 1 ]]; then
    while IFS=$'\t' read -r name ip; do
      wg_client_conf "$name" > "$dir/files/$name.conf"
      qrencode -t SVG -m 2 -o "$dir/qr/w-$name.svg" < "$dir/files/$name.conf"
      e=$(hesc < "$dir/files/$name.conf")
      WC+=$(cat <<EOF
<div class="card" data-name="$name"><h3>$name <span class="badge">WireGuard · ${WG_NET}.$ip</span></h3>
<p class="sub">Файл для Keenetic (импорт из файла) и приложений WireGuard.</p>
<div class="row"><a class="btn" href="files/$name.conf" download="$name.conf">⬇ Скачать $name.conf</a>
<button data-copy="#cw-$name">Копировать конфиг</button><button data-tg="#cw-$name">Показать текст</button><button data-qr="#qw-$name">QR-код</button></div>
<pre class="link" id="cw-$name" style="display:none">$e</pre>
<div class="qr" id="qw-$name"><img src="qr/w-$name.svg" alt="QR $name" loading="lazy"></div></div>
EOF
)
    done < <(jq -r '.[]|[.name,(.ip|tostring)]|@tsv' "$WGPEERS")
  else
    WC='<p class="sub">WireGuard не установлен. Запусти <code>sudo vpn</code> и выбери установку WireGuard.</p>'
  fi

  if [[ ${MTG_ENABLED:-0} == 1 ]]; then
    local l1 l2
    l1="tg://proxy?server=${DOMAIN}&port=${MTG_PORT}&secret=${MTG_SECRET}"
    l2="https://t.me/proxy?server=${DOMAIN}&port=${MTG_PORT}&secret=${MTG_SECRET}"
    qrencode -t SVG -m 2 -o "$dir/qr/mtg.svg" "$l2"
    MC=$(cat <<EOF
<div class="card"><h3>Telegram MTProto <span class="badge">mtg · fake-TLS</span></h3>
<div class="link" id="lm1">$(printf '%s' "$l2" | hesc)</div>
<div class="row"><a class="btn" href="$(printf '%s' "$l2" | hesc)">Открыть в Telegram</a>
<button data-copy="#lm1">Копировать</button><button data-qr="#qm">QR-код</button></div>
<div class="qr" id="qm"><img src="qr/mtg.svg" alt="QR mtproto"></div>
<p class="sub">tg-ссылка: <span id="lm2">$(printf '%s' "$l1" | hesc)</span></p></div>
EOF
)
  else
    MC='<p class="sub">MTProto не установлен.</p>'
  fi

  local certnote="Let's Encrypt"
  [[ ${CERT_MODE:-} == zerossl ]] && certnote="ZeroSSL"
  [[ ${CERT_MODE:-} == selfsigned ]] && certnote="самоподписанный (браузер покажет предупреждение; идёт автоповтор получения настоящего)"

  {
    cat <<'HTML'
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>VPN панель</title>
<style>
:root{--bg:#0f1420;--card:#171e2e;--fg:#e6e9f2;--mut:#8a93a8;--acc:#4f8cff;--line:#26304a}
*{box-sizing:border-box}
body{margin:0;font:15px/1.5 system-ui,Segoe UI,Roboto,sans-serif;background:var(--bg);color:var(--fg)}
.wrap{max-width:980px;margin:0 auto;padding:20px}
h1{font-size:22px;margin:0 0 4px}.sub{color:var(--mut)}
.tabs{display:flex;gap:8px;flex-wrap:wrap;margin:16px 0}
.tab{background:var(--card);border:1px solid var(--line);color:var(--fg);padding:8px 14px;border-radius:10px;cursor:pointer}
.tab.on{background:var(--acc);border-color:var(--acc);color:#fff}
.pane{display:none}.pane.on{display:block}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px;margin-bottom:14px}
.card h3{margin:0 0 8px;font-size:17px}
.badge{display:inline-block;font-size:12px;padding:2px 8px;border-radius:99px;background:#22304f;color:#9fc0ff;margin-left:6px;vertical-align:middle}
.badge.warp{background:#3a2a12;color:#ffc069}
.link{background:#0c111c;border:1px solid var(--line);border-radius:8px;padding:10px;word-break:break-all;font:12.5px/1.45 ui-monospace,Menlo,Consolas,monospace;max-height:160px;overflow:auto;white-space:pre-wrap;margin:0}
.row{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}
button,.btn{background:#24304d;color:var(--fg);border:1px solid var(--line);border-radius:8px;padding:7px 12px;cursor:pointer;text-decoration:none;font-size:14px}
button:hover,.btn:hover{border-color:var(--acc)}
.qr{display:none;margin-top:12px;background:#fff;padding:8px;border-radius:10px;width:fit-content}
.qr.on{display:block}.qr img{display:block;width:240px;height:240px}
input[type=search]{width:100%;padding:10px;border-radius:10px;border:1px solid var(--line);background:var(--card);color:var(--fg);margin-bottom:14px}
.kv{display:grid;grid-template-columns:170px 1fr;gap:6px 12px}.kv>div:nth-child(odd){color:var(--mut)}
code{background:#0c111c;padding:1px 6px;border-radius:5px}
ol li{margin-bottom:6px}
.toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);background:#2b3a5e;padding:10px 18px;border-radius:10px;opacity:0;transition:.25s;pointer-events:none}
.toast.on{opacity:1}
</style></head><body><div class="wrap">
HTML
    cat <<EOF
<h1>🛡 VPN-панель</h1>
<div class="sub">$DOMAIN · обновлено $(date '+%F %T %Z')</div>
<div class="tabs">
<button class="tab on" data-p="px">VLESS / Xray</button>
<button class="tab" data-p="pw">WireGuard · Keenetic</button>
<button class="tab" data-p="pm">MTProto</button>
<button class="tab" data-p="pi">Инфо и инструкции</button>
</div>

<div class="pane on" id="px">
<input type="search" id="flt" placeholder="Поиск клиента…">
<div class="card"><h3>Подписка (все клиенты разом)</h3>
<div class="link" id="lsub">https://$DOMAIN/$WEB_TOKEN/sub.txt</div>
<div class="row"><button data-copy="#lsub">Копировать URL подписки</button></div>
<p class="sub">Вставь в v2rayN / Hiddify / Streisand / Happ как подписку.</p></div>
$XC
</div>

<div class="pane" id="pw">$WC
<div class="card"><h3>Импорт на Keenetic</h3><ol>
<li>Веб-интерфейс роутера → «Общие настройки» → «Изменить набор компонентов» → убедись, что установлен компонент <b>WireGuard VPN</b>.</li>
<li>«Интернет» → «Другие подключения» → «Добавить подключение WireGuard» (или «Создать подключение») → <b>«Загрузить из файла»</b> → выбери скачанный <code>.conf</code>.</li>
<li>Включи подключение. Для выхода всего трафика через туннель отметь «Использовать для выхода в интернет»; для выборочных устройств — «Приоритеты подключений» и политика доступа.</li>
<li>Если сайты открываются не все или тормозят — уменьши MTU подключения до 1280.</li>
<li>Названия пунктов могут чуть отличаться в разных версиях KeeneticOS.</li></ol></div>
</div>

<div class="pane" id="pm">$MC</div>

<div class="pane" id="pi">
<div class="card"><h3>Сервер</h3><div class="kv">
<div>Домен</div><div>$DOMAIN</div>
<div>IP</div><div>$SERVER_IP</div>
<div>SSH</div><div><code>ssh -p $SSH_PORT $NEWUSER@$DOMAIN</code></div>
<div>VLESS TCP Reality</div><div>$XRAY_PORT/tcp</div>
<div>VLESS XHTTP Reality</div><div>$XHTTP_PORT/tcp</div>
<div>WireGuard</div><div>$WG_PORT/udp</div>
<div>MTProto</div><div>$MTG_PORT/tcp</div>
<div>Сертификат</div><div>$certnote</div>
<div>Управление</div><div><code>sudo vpn</code></div>
</div></div>
<div class="card"><h3>Клиентские приложения</h3><ul>
<li>Android: v2rayNG, Hiddify; iOS: Streisand, Happ, Shadowrocket; Windows: v2rayN, Hiddify; macOS: Hiddify, Streisand.</li>
<li>XHTTP работает только в клиентах с Xray-core новых версий (конец 2024 и позже) — обнови приложение.</li>
<li>Клиент <b>warp</b> выходит в интернет через Cloudflare WARP, остальные — напрямую с IP сервера.</li></ul></div>
<div class="card"><h3>Безопасность</h3>
<p>Адрес этой страницы — секрет, на странице ключи. Сохрани данные и отключи сайт: <code>sudo vpn</code> → «Включить/выключить сайт», либо смени адрес («Сменить секретный адрес»).</p></div>
</div>
<div class="toast" id="toast"></div>
EOF
    cat <<'HTML'
</div><script>
const $=(s,r=document)=>r.querySelector(s),$$=(s,r=document)=>[...r.querySelectorAll(s)];
function show(id){if(!$('#'+id))id='px';
 $$('.tab').forEach(t=>t.classList.toggle('on',t.dataset.p===id));
 $$('.pane').forEach(p=>p.classList.toggle('on',p.id===id));
 history.replaceState(null,'','#'+id)}
$$('.tab').forEach(t=>t.onclick=()=>show(t.dataset.p));
show((location.hash||'#px').slice(1));
function toast(m){const t=$('#toast');t.textContent=m;t.classList.add('on');setTimeout(()=>t.classList.remove('on'),1500)}
async function copy(txt){try{await navigator.clipboard.writeText(txt)}catch(e){
 const a=document.createElement('textarea');a.value=txt;document.body.appendChild(a);a.select();document.execCommand('copy');a.remove()}
 toast('Скопировано')}
document.addEventListener('click',e=>{
 const c=e.target.closest('[data-copy]');if(c){copy($(c.dataset.copy).textContent.trim());return}
 const q=e.target.closest('[data-qr]');if(q){$(q.dataset.qr).classList.toggle('on');return}
 const t=e.target.closest('[data-tg]');if(t){const x=$(t.dataset.tg);x.style.display=x.style.display==='none'?'block':'none'}
});
$('#flt').oninput=e=>{const v=e.target.value.toLowerCase();
 $$('#px .card[data-name]').forEach(c=>c.style.display=c.dataset.name.toLowerCase().includes(v)?'':'none')};
</script></body></html>
HTML
  } > "$dir/index.html"
  chmod -R a+rX "$WEBROOT"
  nginx_write full
}
rotate_token() { set_state WEB_TOKEN "$(openssl rand -hex 16)"; site_build; }
toggle_web() {
  load_state
  if [[ ${WEB_ENABLED:-1} == 1 ]]; then set_state WEB_ENABLED 0; else set_state WEB_ENABLED 1; fi
  site_build
}

# ------------------------- ПРОВЕРКИ -------------------------
test_client() { # name
  load_state
  local name="$1" row id tr warp port cfg pid out ip wp want=off i
  row=$(jq -r --arg n "$name" '.[]|select(.name==$n)|[.uuid,.transport,(.warp|tostring)]|@tsv' "$CLIENTS")
  [[ -n $row ]] || return 1
  IFS=$'\t' read -r id tr warp <<<"$row"
  port=$XRAY_PORT; [[ $tr == xhttp ]] && port=$XHTTP_PORT
  cfg=$(mktemp --suffix=.json)
  jq -n --arg id "$id" --arg sni "$DOMAIN" --arg pbk "$REALITY_PUB" --arg sid "$REALITY_SID" \
        --arg tr "$tr" --argjson port "$port" --arg path "$XHTTP_PATH" '
    {log:{loglevel:"error"},
     inbounds:[{listen:"127.0.0.1",port:10808,protocol:"socks",settings:{udp:false}}],
     outbounds:[{protocol:"vless",
       settings:{vnext:[{address:"127.0.0.1",port:$port,
                 users:[ ({id:$id,encryption:"none"} + (if $tr=="tcp" then {flow:"xtls-rprx-vision"} else {} end)) ]}]},
       streamSettings:({network:$tr,security:"reality",
                        realitySettings:{serverName:$sni,fingerprint:"chrome",publicKey:$pbk,shortId:$sid}}
                       + (if $tr=="xhttp" then {xhttpSettings:{path:$path,mode:"auto"}} else {} end))}]}' > "$cfg"
  $XBIN run -format json -config "$cfg" >/dev/null 2>&1 &
  pid=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do port_tcp 10808 && break; sleep 0.5; done
  out=$(curl -sS --max-time 20 -x socks5h://127.0.0.1:10808 https://www.cloudflare.com/cdn-cgi/trace 2>&1 || true)
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  rm -f "$cfg"
  ip=$(sed -n 's/^ip=//p' <<<"$out"); wp=$(sed -n 's/^warp=//p' <<<"$out")
  if [[ -z $ip ]]; then err "клиент $name ($tr): нет связи через туннель"; return 1; fi
  [[ $warp == true ]] && want=on
  if [[ $wp == "$want" || ( $want == on && $wp == plus ) ]]; then
    ok "клиент $name ($tr): работает, выходной IP $ip, warp=$wp"
  else
    warn "клиент $name ($tr): ip=$ip warp=$wp (ожидалось warp=$want)"; return 1
  fi
}
SELFTEST_FAILS=0
_chk() { local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else err "$d"; SELFTEST_FAILS=$((SELFTEST_FAILS+1)); fi; }
ufw_active() { ufw status | grep -q "Status: active"; }
web_check() {
  load_state
  local k="" path="/" code
  [[ ${CERT_MODE:-selfsigned} == selfsigned ]] && k="-k"
  [[ ${WEB_ENABLED:-1} == 1 ]] && path="/${WEB_TOKEN}/"
  code=$(curl -sS $k --max-time 10 --resolve "$DOMAIN:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${DOMAIN}${path}" 2>/dev/null || true)
  [[ $code == 200 ]]
}
selftest() {
  load_state
  SELFTEST_FAILS=0
  echo -e "\n${B}=== Проверка сервера ===${N}"
  _chk "sshd слушает порт $SSH_PORT" port_tcp "$SSH_PORT"
  _chk "UFW активен" ufw_active
  _chk "fail2ban работает" systemctl is-active --quiet fail2ban
  _chk "fail2ban: jail sshd" fail2ban-client status sshd
  _chk "nginx работает" systemctl is-active --quiet nginx
  _chk "xray работает" systemctl is-active --quiet xray
  _chk "порт $XRAY_PORT/tcp (Xray Reality)" port_tcp "$XRAY_PORT"
  if [[ $(jq '[.[]|select(.transport=="xhttp")]|length' "$CLIENTS") -gt 0 ]]; then
    _chk "порт $XHTTP_PORT/tcp (Xray XHTTP)" port_tcp "$XHTTP_PORT"
  fi
  _chk "HTTPS-сайт через Reality-fallback (https://$DOMAIN)" web_check
  if [[ ${WG_ENABLED:-0} == 1 ]]; then
    _chk "WireGuard wg0 поднят" wg show wg0
    _chk "порт $WG_PORT/udp (WireGuard)" port_udp "$WG_PORT"
  fi
  if [[ ${MTG_ENABLED:-0} == 1 ]]; then
    _chk "MTProto-контейнер запущен" bash -c "docker ps --format '{{.Names}}' | grep -q '^mtg$'"
    _chk "порт $MTG_PORT/tcp (MTProto)" port_tcp "$MTG_PORT"
  fi
  local n
  while IFS= read -r n; do
    test_client "$n" || SELFTEST_FAILS=$((SELFTEST_FAILS+1))
  done < <(jq -r '.[].name' "$CLIENTS")
  if [[ ${CERT_MODE:-selfsigned} == selfsigned ]]; then
    warn "Сертификат самоподписанный (идёт автоповтор получения настоящего)"
  else
    ok "Сертификат: ${CERT_MODE}"
  fi
  echo
  if (( SELFTEST_FAILS == 0 )); then ok "Все проверки пройдены"; else warn "Проблемных проверок: $SELFTEST_FAILS"; fi
  return 0
}
LIB_EOF

cat > /usr/local/bin/vpn <<'MENU_EOF'
#!/usr/bin/env bash
[[ $EUID -eq 0 ]] || exec sudo -E bash "$0" "$@"
. /usr/local/lib/vpnpanel/lib.sh
load_state

pause() { read -rp "Enter — продолжить..." _ </dev/tty; }
rd()    { local v; read -rp "$1" v </dev/tty; echo "$v"; }

list_all() {
  local n
  echo -e "\n${B}=== VLESS ===${N}"
  while IFS= read -r n; do echo -e "${Y}$n${N}"; vless_link "$n"; echo; done < <(jq -r '.[].name' "$CLIENTS")
  if [[ ${WG_ENABLED:-0} == 1 ]]; then
    echo -e "${B}=== WireGuard-пиры ===${N}"
    jq -r --arg net "$WG_NET" '.[]|"\(.name)  \($net).\(.ip)"' "$WGPEERS"
  fi
  if [[ ${MTG_ENABLED:-0} == 1 ]]; then
    echo -e "\n${B}=== MTProto ===${N}"
    echo "https://t.me/proxy?server=${DOMAIN}&port=${MTG_PORT}&secret=${MTG_SECRET}"
  fi
  echo -e "\n${B}Сайт:${N} $( [[ ${WEB_ENABLED:-1} == 1 ]] && web_url || echo 'выключен')"
}
add_client() {
  local n t w
  n=$(rd "Имя клиента (латиница/цифры/-/_): ")
  echo "Транспорт: 1) TCP Reality Vision ($XRAY_PORT)   2) XHTTP Reality ($XHTTP_PORT)"
  t=$(rd "Выбор [1]: "); [[ $t == 2 ]] && t=xhttp || t=tcp
  w=false
  if [[ -s $WARPJSON ]]; then
    [[ $(rd "Выход через WARP? [y/N]: ") =~ ^[Yy] ]] && w=true
  fi
  if xray_add_client "$n" "$t" "$w"; then
    site_build
    local l; l=$(vless_link "$n"); echo; echo "$l"; echo; qrencode -t ANSIUTF8 "$l"
  fi
}
del_client() {
  jq -r '.[]|"  \(.name) (\(.transport), warp=\(.warp))"' "$CLIENTS"
  local n; n=$(rd "Какого клиента удалить: ")
  [[ -n $n ]] && xray_del_client "$n" && site_build && ok "Удалён $n"
}
add_peer() {
  if [[ ${WG_ENABLED:-0} != 1 ]]; then
    [[ $(rd "WireGuard не установлен. Установить? [y/N]: ") =~ ^[Yy] ]] || return
    wg_install; load_state; site_build; return
  fi
  local n; n=$(rd "Имя пира (например keenetic2): ")
  wg_add_peer "$n" && site_build && ok "Пир $n добавлен, файл скачивается на сайте"
}
del_peer() {
  [[ ${WG_ENABLED:-0} == 1 ]] || { warn "WireGuard не установлен"; return; }
  jq -r '.[].name' "$WGPEERS" | sed 's/^/  /'
  local n; n=$(rd "Какого пира удалить: ")
  [[ -n $n ]] && wg_del_peer "$n" && site_build && ok "Удалён $n"
}
install_warp() {
  if warp_setup; then
    jq -e '.[]|select(.name=="warp")' "$CLIENTS" >/dev/null || \
      jq_edit "$CLIENTS" --arg u "$(uuid)" '. + [{name:"warp",uuid:$u,transport:"tcp",warp:true}]'
    xray_apply && site_build && ok "WARP включён, клиент 'warp' создан"
  fi
}
restart_all() {
  systemctl restart xray nginx fail2ban
  [[ ${WG_ENABLED:-0} == 1 ]] && systemctl restart wg-quick@wg0
  [[ ${MTG_ENABLED:-0} == 1 ]] && docker restart mtg >/dev/null
  ok "Перезапущено"
}
status_all() {
  for s in ssh fail2ban ufw nginx xray; do printf '%-12s %s\n' "$s" "$(systemctl is-active $s 2>&1)"; done
  [[ ${WG_ENABLED:-0} == 1 ]] && { printf '%-12s %s\n' wg0 "$(systemctl is-active wg-quick@wg0)"; wg show wg0 | head -20; }
  echo; fail2ban-client status sshd 2>/dev/null
  echo; ufw status numbered
}

case "${1:-}" in
  url)  web_url; exit;;
  test) selftest; exit;;
  list) list_all; exit;;
  rebuild) xray_apply && site_build; exit;;
  certretry) cert_retry; exit;;
esac

while true; do
  load_state
  clear
  echo -e "${B}════════ VPN-менеджер · $DOMAIN ════════${N}"
  echo " 1) Показать ссылки и клиентов"
  echo " 2) Ссылка на сайт с данными"
  echo " 3) Добавить VLESS-клиента (TCP / XHTTP / WARP)"
  echo " 4) Удалить VLESS-клиента"
  echo " 5) Добавить WireGuard-пир (роутер) / установить WG"
  echo " 6) Удалить WireGuard-пир"
  echo " 7) Включить/выключить сайт"
  echo " 8) Сменить секретный адрес сайта"
  echo " 9) Проверка всего (selftest)"
  echo "10) Статус сервисов, fail2ban, ufw"
  echo "11) Перезапустить сервисы"
  echo "12) Обновить систему и Xray сейчас (без перезагрузки)"
  echo "13) Установить/переустановить WARP"
  echo "14) Установить/переустановить MTProto"
  echo "15) Получить настоящий SSL-сертификат (повтор)"
  echo " 0) Выход"
  c=$(rd "> ")
  case "$c" in
    1) list_all; pause;;
    2) if [[ ${WEB_ENABLED:-1} == 1 ]]; then web_url; qrencode -t ANSIUTF8 "$(web_url)"; else warn "Сайт выключен (пункт 7)"; fi; pause;;
    3) add_client; pause;;
    4) del_client; pause;;
    5) add_peer; pause;;
    6) del_peer; pause;;
    7) toggle_web; [[ ${WEB_ENABLED:-1} == 1 ]] && web_url || echo "Сайт выключен"; pause;;
    8) rotate_token; echo "Новый адрес:"; web_url; pause;;
    9) selftest; pause;;
    10) status_all; pause;;
    11) restart_all; pause;;
    12) /usr/local/sbin/weekly-update.sh --no-reboot; ok "Готово. Лог: /var/log/weekly-update.log"; pause;;
    13) install_warp; pause;;
    14) mtg_install && load_state && site_build && ok "MTProto установлен"; pause;;
    15) cert_retry; pause;;
    0) exit 0;;
  esac
done
MENU_EOF
chmod 644 /usr/local/lib/vpnpanel/lib.sh
chmod 755 /usr/local/bin/vpn

# ==================================================================
#  Первичная инициализация
# ==================================================================
. /usr/local/lib/vpnpanel/lib.sh
[[ -f $STATE ]] && cp -a "$STATE" "$STATE.bak.$(date +%s)"
: > "$STATE"; chmod 600 "$STATE"
echo '[]' > "$CLIENTS"; echo '[]' > "$WGPEERS"
rm -f "$WARPJSON" /etc/cron.d/vpn-cert-retry
set_state DOMAIN "$DOMAIN";       set_state SERVER_IP "$SERVER_IP"
set_state SSH_PORT "$SSH_PORT";   set_state NEWUSER "$NEWUSER"
set_state XRAY_PORT "$XRAY_PORT"; set_state XHTTP_PORT "$XHTTP_PORT"
set_state WG_PORT "$WG_PORT";     set_state MTG_PORT "$MTG_PORT"
set_state WEB_LOCAL_PORT "$WEB_LOCAL_PORT"
set_state WG_NET "10.66.66"
set_state LE_EMAIL "$LE_EMAIL"
set_state XHTTP_PATH "/$(openssl rand -hex 6)"
set_state WEB_TOKEN "$(openssl rand -hex 16)"
set_state WEB_ENABLED 1

# ---------- Xray ----------
info "Установка Xray..."
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
KEYS=$($XBIN x25519)
PRIV=$(echo "$KEYS" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')
PUB=$(echo "$KEYS"  | awk -F': *' 'tolower($1) ~ /public|password/ {print $2; exit}')
[[ -n $PRIV && -n $PUB ]] || die "Не удалось получить ключи x25519"
set_state REALITY_PRIV "$PRIV"; set_state REALITY_PUB "$PUB"
set_state REALITY_SID "$(openssl rand -hex 8)"

jq -n --arg a "$(uuid)" --arg b "$(uuid)" \
  '[{name:"main",uuid:$a,transport:"tcp",warp:false},{name:"xhttp",uuid:$b,transport:"xhttp",warp:false}]' > "$CLIENTS"

if [[ $INSTALL_WARP -eq 1 ]]; then
  if warp_setup; then
    jq_edit "$CLIENTS" --arg u "$(uuid)" '. + [{name:"warp",uuid:$u,transport:"tcp",warp:true}]'
  else
    warn "WARP пропущен. Позже: sudo vpn -> пункт 13"
  fi
fi

# ---------- nginx + сертификат ----------
cert_setup
load_state
nginx_write full

# ---------- Xray apply ----------
xray_apply || die "Xray не запустился: journalctl -u xray"
ok "Xray запущен (Reality TCP:$XRAY_PORT, XHTTP:$XHTTP_PORT)"

# ---------- WG / MTG ----------
[[ $INSTALL_WG  -eq 1 ]] && wg_install
[[ $INSTALL_MTG -eq 1 ]] && mtg_install
load_state

# ---------- автообновление ----------
cat > /usr/local/sbin/weekly-update.sh <<'EOF'
#!/usr/bin/env bash
export DEBIAN_FRONTEND=noninteractive
LOG=/var/log/weekly-update.log
{
  echo "=== $(date) ==="
  apt-get update -y
  apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
  apt-get -y autoremove --purge
  apt-get -y autoclean
  if [ -x /usr/local/bin/xray ]; then
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install || true
  fi
  command -v certbot >/dev/null && certbot renew -q || true
  . /usr/local/lib/vpnpanel/lib.sh; load_state
  if [ "${MTG_ENABLED:-0}" = "1" ]; then mtg_install || true; fi
  echo "Готово"
} >> "$LOG" 2>&1
[ "${1:-}" = "--no-reboot" ] && exit 0
sleep 5
/sbin/reboot
EOF
chmod 700 /usr/local/sbin/weekly-update.sh
echo "0 5 * * 0 root /usr/local/sbin/weekly-update.sh" > /etc/cron.d/weekly-update
chmod 644 /etc/cron.d/weekly-update
ok "Автообновление: воскресенье 05:00 + перезагрузка (время сервера: $(date +%Z))"

# ---------- сайт и проверки ----------
site_build
selftest || true
load_state

URL=$(web_url)
echo -e "\n${G}==================== ГОТОВО ====================${N}"
echo -e "SSH:     ${Y}ssh -p $SSH_PORT $NEWUSER@$DOMAIN${N}   (или @$SERVER_IP)"
echo -e "Сайт:    ${Y}$URL${N}"
if [[ ${CERT_MODE:-} == selfsigned ]]; then
  echo -e "${R}Сертификат самоподписанный — браузер покажет предупреждение (можно продолжить).${N}"
  echo -e "Настоящий сертификат подтянется сам (проверка каждые 30 мин) или вручную: ${Y}sudo vpn certretry${N}"
fi
qrencode -t ANSIUTF8 "$URL" || true
echo -e "Меню:    ${Y}sudo vpn${N}   (также: vpn url | vpn test | vpn list)"
echo -e "${R}Не закрывай эту сессию, пока не проверишь вход по SSH во втором окне!${N}"
echo "Если у хостера есть внешний firewall — открой там $SSH_PORT/tcp, 80, 443, 8442, 8443, ${WG_PORT}/udp."
echo -e "Рекомендуется перезагрузка: ${Y}sudo reboot${N}"
```