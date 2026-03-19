#!/usr/bin/env sh
# Выводит ссылки для подключения к MTProxy (после установки через install.sh)

set -eu

SECRET_FILE="/etc/mtproxy/user-secret"
DEFAULTS_FILE="/etc/default/mtproxy"

if [ ! -f "$SECRET_FILE" ]; then
  echo "Ошибка: MTProxy не установлен или не найден $SECRET_FILE"
  exit 1
fi

SECRET="$(cat "$SECRET_FILE")"
PORT="443"
if [ -f "$DEFAULTS_FILE" ]; then
  # shellcheck disable=SC1090
  . "$DEFAULTS_FILE" 2>/dev/null || true
fi

PUBLIC_IP="$(curl -4fsSL https://api.ipify.org 2>/dev/null || true)"
if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
fi
[ -z "$PUBLIC_IP" ] && PUBLIC_IP="YOUR_SERVER_IP"

CLIENT_SECRET="dd${SECRET}"

echo
echo "Клиентский secret:"
echo "$SECRET"
echo
echo "Ссылка tg://"
echo "tg://proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${CLIENT_SECRET}"
echo
echo "Ссылка https://t.me/proxy"
echo "https://t.me/proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${CLIENT_SECRET}"
echo
echo "Локальная статистика:"
echo "curl -s http://127.0.0.1:8888/stats"
