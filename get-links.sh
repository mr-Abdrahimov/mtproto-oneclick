#!/usr/bin/env sh
# Ссылки для подключения после install.sh (классический MTProxy или Telemt).

set -eu

SECRET_FILE="/etc/mtproxy/user-secret"
DEFAULTS_FILE="/etc/default/mtproxy"
TELEMT_CONFIG="/etc/telemt/telemt.toml"
TELEMT_API="http://127.0.0.1:9091/v1/users"

telemt_links() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "Ошибка: нужен curl для запроса API Telemt"
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Ошибка: нужен python3 для разбора JSON Telemt"
    exit 1
  fi
  if ! curl -fsS --max-time 5 "$TELEMT_API" -o /tmp/telemt-users.json 2>/dev/null; then
    echo "Ошибка: Telemt API недоступен по ${TELEMT_API}"
    echo "Проверьте: systemctl status telemt | journalctl -u telemt -n 30"
    exit 1
  fi
  echo
  echo "Telemt — ссылки tg:// (предпочтительно tls / ee):"
  echo
  python3 <<'PY'
import json

def user_dicts(payload):
    if isinstance(payload, list):
        return [x for x in payload if isinstance(x, dict)]
    if isinstance(payload, dict):
        for key in ("users", "data", "items", "result", "payload"):
            v = payload.get(key)
            if isinstance(v, list):
                return [x for x in v if isinstance(x, dict)]
            if isinstance(v, dict) and v and all(isinstance(x, dict) for x in v.values()):
                return list(v.values())
    return []

with open("/tmp/telemt-users.json", encoding="utf-8") as f:
    raw = json.load(f)
for u in user_dicts(raw):
    links = u.get("links") or {}
    tls = links.get("tls") or ()
    for L in tls:
        print(L)
    if not tls:
        for kind in ("secure", "classic"):
            for L in links.get(kind) or ():
                print(L)
PY
  rm -f /tmp/telemt-users.json
}

classic_links() {
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
}

if [ -f "$TELEMT_CONFIG" ]; then
  telemt_links
elif [ -f "$SECRET_FILE" ]; then
  classic_links
else
  echo "Ошибка: не найден ни Telemt ($TELEMT_CONFIG), ни классический MTProxy ($SECRET_FILE)"
  exit 1
fi
