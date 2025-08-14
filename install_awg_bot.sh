#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Запусти от root: sudo bash install_awg_bot.sh" >&2
  exit 1
fi

# === 1. Установка AmneziaWG ===
cd /root
curl -O https://raw.githubusercontent.com/Varckin/amneziawg-install/main/amneziawg-install.sh
wget https://raw.githubusercontent.com/Varckin/amneziawg-install/main/amneziawg-install.sh
chmod +x amneziawg-install.sh
./amneziawg-install.sh

# === 2. Установка Python и зависимостей ===
apt update
apt install -y python3 python3-pip git qrencode
pip3 install --break-system-packages pyTelegramBotAPI qrcode

# === 3. Настройка бота ===
BOT_DIR="/opt/awg_admin_telebot"
BOT_FILE="awg_adminbot.py"
BOT_PARAMS_FILE="/etc/amnezia/amneziawg/bot_params"
SYSTEMD_UNIT="/etc/systemd/system/awg_adminbot.service"

# Клонируем репозиторий
if [[ -d "$BOT_DIR" ]]; then
  git -C "$BOT_DIR" pull --ff-only
else
  git clone --depth=1 https://github.com/LinQich/awg_admin_telebot.git "$BOT_DIR"
fi

chmod +x "$BOT_DIR/$BOT_FILE"

# === 4. Запрос токена и ID админа ===
read -rp "Введите токен бота: " BOT_TOKEN
read -rp "Введите ID администратора (можно несколько через пробел): " ADMIN_IDS

# Создаём файл параметров бота
mkdir -p /etc/amnezia/amneziawg
cat >"$BOT_PARAMS_FILE" <<EOF
BOT_TOKEN=$BOT_TOKEN
ADMIN_IDS=$ADMIN_IDS
EOF
chmod 600 "$BOT_PARAMS_FILE"

# === 5. Systemd unit ===
cat >"$SYSTEMD_UNIT" <<EOF
[Unit]
Description=AmneziaWG Telegram Admin Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=$BOT_PARAMS_FILE
WorkingDirectory=$BOT_DIR
ExecStart=/usr/bin/python3 $BOT_DIR/$BOT_FILE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now awg_adminbot.service

echo "✅ Установка завершена!
- Бот: $BOT_FILE в $BOT_DIR
- Конфиг бота: $BOT_PARAMS_FILE
Для изменения параметров: nano $BOT_PARAMS_FILE
После изменений: systemctl restart awg_adminbot
"
