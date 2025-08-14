#!/usr/bin/env bash
set -euo pipefail

# install_awg_bot.sh
# Installs & configures AmneziaWG server (awg0) + Telegram admin bot.
# Works on Debian/Ubuntu (APT). For other distros, exit with a message.

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash install_awg_bot.sh" >&2
  exit 1
fi

OS_ID="$(. /etc/os-release; echo "$ID")"
OS_LIKE="$(. /etc/os-release; echo "${ID_LIKE:-}")"
if [[ "$OS_ID" != "debian" && "$OS_ID" != "ubuntu" && "$OS_LIKE" != *"debian"* && "$OS_LIKE" != *"ubuntu"* ]]; then
  echo "This installer currently supports Debian/Ubuntu only." >&2
  exit 1
fi

# Defaults (can be overridden via env vars)
AWG_PORT="${AWG_PORT:-51820}"
AWG_NET="${AWG_NET:-10.9.0.1/24}"
AWG_DIR="/etc/amnezia/amneziawg"
AWG_CONF="$AWG_DIR/awg0.conf"
CLIENT_DIR="$AWG_DIR/clients"
BOT_PARAMS_FILE="$AWG_DIR/bot_params"
BOT_REPO="${BOT_REPO:-https://github.com/LinQich/awg_admin_telebot.git}"
BOT_FILE="awg_adminbot.py"
BOT_DIR="/opt/awg_admin_telebot"
SYSTEMD_UNIT="/etc/systemd/system/awg_adminbot.service"

# Detect main interface for NAT
detect_main_iface() {
  local iface
  iface=$(ip -4 route list default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  if [[ -z "$iface" ]]; then
    iface=$(ip -o -4 addr show | awk '!/ lo /{print $2; exit}')
  fi
  echo "$iface"
}

# Random AWG obfuscation params
rand_awg_params() {
  # Jc 0..10 ; Jmin 64..512 ; Jmax 256..1024 (and > Jmin)
  local JC JMIN JMAX S1 S2
  JC=$((RANDOM % 6 + 3))                 # 3..8 sensible default
  JMIN=$((RANDOM % 65 + 64))             # 64..128
  JMAX=$((RANDOM % 769 + 256))           # 256..1024
  if (( JMAX <= JMIN )); then JMAX=$((JMIN + 64)); fi
  S1=$((RANDOM % 65))                    # 0..64
  S2=$((RANDOM % 65))                    # 0..64
  # Under-Load header is H1..H4; make it a random permutation of 1..4
  local arr=(1 2 3 4)
  for i in {0..3}; do
    j=$((RANDOM % 4))
    tmp=${arr[$i]}; arr[$i]=${arr[$j]}; arr[$j]=$tmp
  done
  echo "$JC $JMIN $JMAX $S1 $S2 ${arr[0]} ${arr[1]} ${arr[2]} ${arr[3]}"
}

step_install_packages() {
  apt-get update -y
  apt-get install -y --no-install-recommends software-properties-common curl ca-certificates gnupg lsb-release git python3 python3-pip qrencode
  add-apt-repository -y ppa:amnezia/ppa
  apt-get update -y
  apt-get install -y amneziawg
  # python deps for the bot
  pip3 install --break-system-packages pyTelegramBotAPI qrcode
}

step_generate_server() {
  install -d -m 755 "$AWG_DIR" "$CLIENT_DIR"
  # Generate keys using awg (fallback to wg if needed)
  if command -v awg >/dev/null 2>&1; then
    KEYGEN="awg"
  else
    apt-get install -y wireguard-tools
    KEYGEN="wg"
  fi
  SERVER_PRIV="$("$KEYGEN" genkey)"
  SERVER_PUB="$(printf "%s" "$SERVER_PRIV" | "$KEYGEN" pubkey)"
  echo "$SERVER_PRIV" > "$AWG_DIR/server_private"
  echo "$SERVER_PUB"  > "$AWG_DIR/server_public"
  chmod 600 "$AWG_DIR/server_private"
}

step_write_conf() {
  local JC JMIN JMAX S1 S2 H1 H2 H3 H4
  read -r JC JMIN JMAX S1 S2 H1 H2 H3 H4 < <(rand_awg_params)
  local IFACE
  IFACE="$(detect_main_iface)"
  local ADDR="${AWG_NET}"
  cat >"$AWG_CONF" <<EOF
[Interface]
Address = ${ADDR}
ListenPort = ${AWG_PORT}
PrivateKey = $(cat "$AWG_DIR/server_private")

# AmneziaWG obfuscation (randomized)
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

# NAT + firewall rules (IPv4)
PostUp = iptables -A INPUT -p udp --dport ${AWG_PORT} -m conntrack --ctstate NEW -j ACCEPT
PostUp = iptables -A FORWARD -i ${IFACE} -o awg0 -j ACCEPT
PostUp = iptables -A FORWARD -i awg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${IFACE} -j MASQUERADE
PostDown = iptables -D INPUT -p udp --dport ${AWG_PORT} -m conntrack --ctstate NEW -j ACCEPT || true
PostDown = iptables -D FORWARD -i ${IFACE} -o awg0 -j ACCEPT || true
PostDown = iptables -D FORWARD -i awg0 -j ACCEPT || true
PostDown = iptables -t nat -D POSTROUTING -o ${IFACE} -j MASQUERADE || true
EOF
  # Enable IP forwarding
  printf "net.ipv4.ip_forward=1
" >/etc/sysctl.d/99-awg-forward.conf
  sysctl -p /etc/sysctl.d/99-awg-forward.conf || true
}

step_enable_service() {
  systemctl enable --now awg-quick@awg0.service || awg-quick up awg0
  systemctl restart awg-quick@awg0.service || true
}

step_bot_fetch() {
  install -d -m 755 "$BOT_DIR"
  if command -v git >/dev/null 2>&1; then
    if [[ -d "$BOT_DIR/.git" ]]; then
      git -C "$BOT_DIR" pull --ff-only || true
    else
      git clone --depth=1 "$BOT_REPO" "$BOT_DIR" || true
    fi
  fi
  # If the repo doesn't exist or file is missing, attempt to curl/wget raw file path
  if [[ ! -f "$BOT_DIR/$BOT_FILE" ]]; then
    echo "# Placeholder; please place $BOT_FILE into $BOT_DIR (cloned from $BOT_REPO)" > "$BOT_DIR/$BOT_FILE"
  fi
  chmod 755 "$BOT_DIR/$BOT_FILE"
}

step_bot_params() {
  if [[ ! -f "$BOT_PARAMS_FILE" ]]; then
    cat >"$BOT_PARAMS_FILE" <<EOF
# Fill in and \`systemctl restart awg_adminbot\` after editing.
BOT_TOKEN=put-your-telegram-bot-token-here
ADMIN_IDS=123456789
EOF
    chmod 600 "$BOT_PARAMS_FILE"
  fi
}

step_bot_service() {
  cat >"$SYSTEMD_UNIT" <<'EOF'
[Unit]
Description=AmneziaWG Telegram Admin Bot
After=network-online.target awg-quick@awg0.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=/etc/amnezia/amneziawg/bot_params
WorkingDirectory=/opt/awg_admin_telebot
ExecStart=/usr/bin/python3 /opt/awg_admin_telebot/awg_adminbot.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now awg_adminbot.service
}

echo "[1/6] Installing packages..."
step_install_packages
echo "[2/6] Generating server keys..."
step_generate_server
echo "[3/6] Writing awg0.conf..."
step_write_conf
echo "[4/6] Enabling awg-quick@awg0..."
step_enable_service
echo "[5/6] Fetching bot..."
step_bot_fetch
echo "[6/6] Writing bot params & service..."
step_bot_params
step_bot_service

echo "Done.
- AWG conf:    $AWG_CONF
- Clients dir: $CLIENT_DIR
- Bot service: awg_adminbot.service
Edit $BOT_PARAMS_FILE to set BOT_TOKEN/ADMIN_IDS, then: systemctl restart awg_adminbot
"
