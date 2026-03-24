#!/usr/bin/env sh
set -eu

# Ubuntu installer for Telegram MTProxy.
#
# Режим 1 — классический mtproto-proxy от Telegram:
#   - Сборка из исходников, systemd, ежедневное обновление proxy-multi.conf
# Режим 2 — Telemt с https://github.com/telemt/telemt (Fake TLS + маскировка TCP под реальный сайт, см. https://habr.com/ru/articles/995102/):
#   - Бинарник с GitHub Releases (amd64/arm64). Образ ghcr.io/telemt/telemt сейчас только arm64 — на x86_64 Docker-пулл падает.
#   - SNI (tls_domain) задаётся при установке; mask + tls_emulation
# - В обоих режимах: UFW (SSH + порт прокси), Fail2ban для SSH
#
# Usage:
#   sudo sh <(wget -O - https://raw.githubusercontent.com/mr-Abdrahimov/mtproto-oneclick/main/install.sh)

log() {
  printf '%s\n' "$1" >&2
}

# CR в конце строки (Windows SSH, некоторые терминалы) ломает case y/n и «1»/«2».
sanitize_tty_line() {
  printf '%s' "${1:-}" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# y / yes / да и варианты с лишними символами после первой буквы
affirmative_answer() {
  _a="$(printf '%s' "${1:-}" | tr -d '\r\n\v\f' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$_a" ] && return 1
  case "$_a" in
    y|Y|yes|YES|Yes|д|Д|да|Да|ДА|da|DA|Da) return 0 ;;
  esac
  case "$_a" in
    [yY]?*) return 0 ;;
    [дД]?*) return 0 ;;
    да*) return 0 ;;
    [Дд][аА]*) return 0 ;;
    [yY][eE][sS]*) return 0 ;;
  esac
  return 1
}

read_line_interactive() {
  # stdin может быть не терминалом (curl|sh); /dev/tty надёжнее для вопросов
  if [ -r /dev/tty ]; then
    IFS= read -r _rl < /dev/tty || true
  else
    IFS= read -r _rl || true
  fi
  printf '%s' "${_rl:-}"
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log "ОШИБКА: Запустите от root (например: sudo)."
    exit 1
  fi
}

get_ssh_port() {
  # Take the last non-comment "Port <n>" from sshd_config; default to 22.
  # shellcheck disable=SC2016
  port="$(awk '
    $1 ~ /^#/ {next}
    tolower($1) == "port" {p=$2}
    END {if (p == "") print 22; else print p}
  ' /etc/ssh/sshd_config 2>/dev/null || true)"
  printf '%s' "$port"
}

prompt_port() {
  default_port=443
  while :; do
    printf 'Порт MTProxy (TCP) [%s]: ' "$default_port" >&2
    # shellcheck disable=SC2162
    read -r in_port < /dev/tty || true
    in_port="$(sanitize_tty_line "${in_port:-}")"

    if [ -z "${in_port:-}" ]; then
      PORT="$default_port"
    else
      PORT="$in_port"
    fi

    case "$PORT" in
      ''|*[!0-9]*) log "Введите число от 1 до 65535."; continue ;;
      *)
        if [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
          break
        fi
        log "Введите число от 1 до 65535."
        ;;
    esac
  done
  printf '%s' "$PORT"
}

# 1 = classic mtproto-proxy, 2 = Telemt (Fake TLS + masking)
prompt_install_mode() {
  log ""
  log "Режим установки:"
  log "  1) Классический MTProxy (исходники Telegram, systemd, секрет dd...)"
  log "  2) Telemt (бинарник) — Fake TLS и маскировка под выбранный SNI (устойчивее к active probing / DPI)"
  log ""
  while :; do
    printf 'Выберите 1 или 2 [1]: ' >&2
    read -r m </dev/tty || true
    m="$(sanitize_tty_line "${m:-}")"
    case "${m:-1}" in
      1) printf '%s' classic; return ;;
      2) printf '%s' telemt; return ;;
      *) log "Введите 1 или 2." ;;
    esac
  done
}

is_valid_sni() {
  host="$1"
  [ -n "$host" ] || return 1
  case "$host" in
    *[!a-zA-Z0-9.-]*) return 1 ;;
  esac
  case "$host" in
    *..*|-*|.*|*.) return 1 ;;
  esac
  return 0
}

prompt_tls_domain() {
  log ""
  log "Домен для SNI и маскировки (TLS). Примеры: eh.vk.com, ozon.ru, seller.ozon.ru, st.max.ru, web.max.ru"
  log "Выберите свой домен; один и тот же на массе серверов сам становится сигнатурой."
  default_sni="eh.vk.com"
  while :; do
    printf 'SNI / tls_domain [%s]: ' "$default_sni" >&2
    read -r d </dev/tty || true
    d="$(sanitize_tty_line "${d:-}")"
    if [ -z "${d:-}" ]; then
      d="$default_sni"
    fi
    if is_valid_sni "$d"; then
      printf '%s' "$d"
      return
    fi
    log "Некорректное имя: допустимы латинские буквы, цифры, точки и дефисы (без .. в начале/конце)."
  done
}

port_is_free() {
  # Returns 0 if free, 1 if already listening.
  port="$1"
  if ss -ltn "( sport = :${port} )" 2>/dev/null | grep -q ":${port}"; then
    return 1
  fi
  return 0
}

install_packages() {
  log "[2/10] Устанавливаю пакеты"
  export DEBIAN_FRONTEND=noninteractive
  apt update -qq
  apt install -y -qq \
    git curl xxd openssl ca-certificates \
    build-essential libssl-dev zlib1g-dev \
    ufw fail2ban
}

install_packages_telemt() {
  log "[2/8] Устанавливаю пакеты для Telemt"
  export DEBIAN_FRONTEND=noninteractive
  apt update -qq
  apt install -y -qq curl tar openssl ca-certificates ufw fail2ban python3
}

telemt_download_triple() {
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) printf '%s' "x86_64-linux-gnu" ;;
    aarch64|arm64) printf '%s' "aarch64-linux-gnu" ;;
    *)
      log "ОШИБКА: архитектура «$m» не поддерживается установщиком Telemt (нужны x86_64 или aarch64)."
      exit 1
      ;;
  esac
}

telemt_fetch_binary() {
  TAR_NAME="telemt-$(telemt_download_triple).tar.gz"
  URL="https://github.com/telemt/telemt/releases/latest/download/${TAR_NAME}"
  TMP_TGZ="$(mktemp)"
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_TGZ" "$TMP_DIR"' EXIT
  log "[4/8] Скачиваю Telemt: ${TAR_NAME}"
  curl -fsSL -o "$TMP_TGZ" "$URL" || {
    log "ОШИБКА: не удалось скачать ${URL}"
    exit 1
  }
  tar -xzf "$TMP_TGZ" -C "$TMP_DIR"
  install -m 0755 "${TMP_DIR}/telemt" /usr/local/bin/telemt
  rm -rf "$TMP_TGZ" "$TMP_DIR"
  trap - EXIT
}

create_system_user() {
  log "[3/10] Создаю системного пользователя mtproxy"
  STATE_DIR="/var/lib/mtproxy"
  if ! id mtproxy >/dev/null 2>&1; then
    useradd --system --home "$STATE_DIR" --create-home --shell /usr/sbin/nologin mtproxy
  fi
}

build_mtproxy() {
  INSTALL_DIR="/opt/MTProxy"
  BIN="/usr/local/bin/mtproto-proxy"
  log "[4/10] Загружаю исходники MTProxy"
  rm -rf "$INSTALL_DIR"
  git clone https://github.com/TelegramMessenger/MTProxy "$INSTALL_DIR"

  log "[5/10] Собираю MTProxy"
  make -C "$INSTALL_DIR"
  install -m 0755 "${INSTALL_DIR}/objs/bin/mtproto-proxy" "$BIN"
}

configure() {
  PORT="$1"
  WORKERS="${2:-1}"

  CONF_DIR="/etc/mtproxy"
  STATE_DIR="/var/lib/mtproxy"
  SERVICE_FILE="/etc/systemd/system/mtproxy.service"
  DEFAULTS_FILE="/etc/default/mtproxy"
  UPDATE_SCRIPT="/usr/local/sbin/mtproxy-update-config"
  UPDATE_SERVICE="/etc/systemd/system/mtproxy-update.service"
  UPDATE_TIMER="/etc/systemd/system/mtproxy-update.timer"
  BIN="/usr/local/bin/mtproto-proxy"

  log "[6/10] Подготавливаю каталоги и конфиги"
  install -d -m 0750 -o root -g mtproxy "$CONF_DIR"
  install -d -m 0750 -o mtproxy -g mtproxy "$STATE_DIR"

  curl -fsSL https://core.telegram.org/getProxySecret -o "${CONF_DIR}/proxy-secret"
  curl -fsSL https://core.telegram.org/getProxyConfig -o "${CONF_DIR}/proxy-multi.conf"

  SECRET="$(openssl rand -hex 16)"
  # Store without trailing newline for simpler usage in ExecStart.
  printf '%s' "$SECRET" > "${CONF_DIR}/user-secret"

  chown root:mtproxy \
    "${CONF_DIR}/proxy-secret" \
    "${CONF_DIR}/proxy-multi.conf" \
    "${CONF_DIR}/user-secret"
  chmod 0640 \
    "${CONF_DIR}/proxy-secret" \
    "${CONF_DIR}/proxy-multi.conf" \
    "${CONF_DIR}/user-secret"

  log "[7/10] Настраиваю systemd-сервис"
  cat > "$DEFAULTS_FILE" <<CFG
PORT=${PORT}
WORKERS=${WORKERS}
CFG

  # Обёртка для mtproxy: добавляет -P (proxy-tag) если файл существует
  cat > /usr/local/sbin/mtproxy-run <<'WRAPPER'
#!/bin/sh
. /etc/default/mtproxy
EXTRA=""
if [ -f /etc/mtproxy/proxy-tag ] && [ -s /etc/mtproxy/proxy-tag ]; then
  TAG="$(cat /etc/mtproxy/proxy-tag)"
  EXTRA="-P ${TAG}"
fi
exec /usr/local/bin/mtproto-proxy -u mtproxy -p 8888 -H "$PORT" -S "$(cat /etc/mtproxy/user-secret)" --http-stats $EXTRA --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M "$WORKERS"
WRAPPER
  chmod 0755 /usr/local/sbin/mtproxy-run

  cat > "$SERVICE_FILE" <<'UNIT'
[Unit]
Description=Telegram MTProxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/default/mtproxy
ExecStart=/usr/local/sbin/mtproxy-run
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT

  log "[8/10] Настраиваю ежедневное обновление конфига"
  cat > "$UPDATE_SCRIPT" <<'UPD'
#!/bin/sh
set -eu

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

curl -fsSL https://core.telegram.org/getProxyConfig -o "$TMP"
install -o root -g mtproxy -m 0640 "$TMP" /etc/mtproxy/proxy-multi.conf
systemctl try-restart mtproxy.service >/dev/null 2>&1 || true
UPD
  chmod 0755 "$UPDATE_SCRIPT"

  cat > "$UPDATE_SERVICE" <<'USVC'
[Unit]
Description=Refresh Telegram MTProxy config

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mtproxy-update-config
USVC

  cat > "$UPDATE_TIMER" <<'UTMR'
[Unit]
Description=Daily refresh for Telegram MTProxy config

[Timer]
OnCalendar=daily
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
UTMR

  echo "$SECRET"
}

configure_ufw() {
  PORT="$1"
  SSH_PORT="$2"

  log "Настраиваю UFW (файрвол)"
  # Make sure UFW is installed already (done in install_packages).

  # Add rules first, then enable.
  ufw status >/dev/null 2>&1 || true

  ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || true
  ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true

  # Only apply defaults if not active yet, to avoid unexpected changes.
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    return 0
  fi

  ufw default deny incoming
  ufw default allow outgoing

  ufw --force enable
}

configure_fail2ban() {
  SSH_PORT="$1"

  log "Настраиваю Fail2ban для SSH"

  # Ubuntu default log for sshd auth is /var/log/auth.log
  cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
logpath = /var/log/auth.log
bantime = 1h
findtime = 10m
maxretry = 5
action = ufw
EOF

  systemctl enable --now fail2ban >/dev/null 2>&1 || true
}

enable_services() {
  log "Применяю systemd-юниты"
  systemctl daemon-reload
  systemctl enable --now mtproxy.service
  systemctl enable --now mtproxy-update.timer
}

print_final_info() {
  PORT="$1"
  SECRET="$2"

  PUBLIC_IP="$(curl -4fsSL https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  [ -z "$PUBLIC_IP" ] && PUBLIC_IP="YOUR_SERVER_IP"

  # Telegram requires the client secret format: "dd" + server secret.
  CLIENT_SECRET="dd${SECRET}"

  log ""
  log "========== ГОТОВО =========="
  log "Статус сервиса:"
  systemctl --no-pager --full status mtproxy.service 2>/dev/null || true
  log ""
  log "Клиентский secret:"
  log "${SECRET}"
  log ""
  log "Ссылка tg://"
  log "tg://proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${CLIENT_SECRET}"
  log ""
  log "Ссылка https://t.me/proxy"
  log "https://t.me/proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${CLIENT_SECRET}"
  log ""
  log "Локальная статистика:"
  log "curl -s http://127.0.0.1:8888/stats"
}

telemt_write_config() {
  TELEMT_PORT="$1"
  TLS_DOMAIN="$2"
  SECRET="$3"
  PUBLIC_HOST="$4"
  install -d -m 0750 -o root -g telemt /etc/telemt
  cat > /etc/telemt/telemt.toml <<CFG
# Сгенерировано mtproto-oneclick (Telemt, Fake TLS + masking)

[general]
use_middle_proxy = false
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = ["user1"]
public_host = "${PUBLIC_HOST}"
public_port = ${TELEMT_PORT}

[server]
port = ${TELEMT_PORT}

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.0/8", "::1/128"]

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "${TLS_DOMAIN}"
mask = true
tls_emulation = true
tls_front_dir = "/var/lib/telemt/tlsfront"

[access.users]
user1 = "${SECRET}"
CFG
  chown root:telemt /etc/telemt/telemt.toml
  chmod 0640 /etc/telemt/telemt.toml
}

telemt_write_systemd_unit() {
  cat > /etc/systemd/system/telemt.service <<'UNIT'
[Unit]
Description=Telemt MTProxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/var/lib/telemt
Environment=RUST_LOG=info
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
}

telemt_setup() {
  TELEMT_PORT="$1"
  TLS_DOMAIN="$2"

  log "[3/8] Создаю пользователя telemt и каталоги"
  if command -v docker >/dev/null 2>&1; then
    docker rm -f telemt >/dev/null 2>&1 || true
  fi
  if ! id telemt >/dev/null 2>&1; then
    useradd --system --home /var/lib/telemt --create-home --shell /usr/sbin/nologin telemt
  fi
  install -d -m 0750 -o telemt -g telemt /var/lib/telemt
  install -d -m 0755 -o telemt -g telemt /var/lib/telemt/tlsfront

  PUBLIC_HOST="$(curl -4fsSL https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$PUBLIC_HOST" ]; then
    PUBLIC_HOST="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  if [ -z "$PUBLIC_HOST" ]; then
    log "ПРЕДУПРЕЖДЕНИЕ: не удалось определить публичный IPv4 для ссылок. Укажите public_host вручную в /etc/telemt/telemt.toml и перезапустите telemt."
    PUBLIC_HOST="0.0.0.0"
  fi

  SECRET="$(openssl rand -hex 16)"
  telemt_write_config "$TELEMT_PORT" "$TLS_DOMAIN" "$SECRET" "$PUBLIC_HOST"

  telemt_fetch_binary

  log "[5/8] Настраиваю systemd-службу telemt"
  systemctl stop telemt-compose.service >/dev/null 2>&1 || true
  systemctl disable telemt-compose.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/telemt-compose.service
  telemt_write_systemd_unit
  systemctl daemon-reload
  systemctl enable --now telemt.service

  printf '%s' "$SECRET" > /etc/telemt/user-secret
  chown root:telemt /etc/telemt/user-secret
  chmod 0640 /etc/telemt/user-secret
  printf '%s' "$TLS_DOMAIN" > /etc/telemt/tls-domain
  printf '%s' "$TELEMT_PORT" > /etc/telemt/listen-port
}

# Печатает в stdout по одной ссылке tg:// на строку (предпочтительно tls). Возврат 0 если API ответил.
telemt_dump_api_tls_links() {
  n=0
  while [ "$n" -lt 15 ]; do
    if curl -fsS --max-time 2 "http://127.0.0.1:9091/v1/users" >/dev/null 2>&1; then
      break
    fi
    n=$((n + 1))
    sleep 1
  done
  curl -fsS --max-time 5 "http://127.0.0.1:9091/v1/users" -o /tmp/telemt-users.json 2>/dev/null || return 1
  python3 <<'PY'
import json
import sys

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

try:
    with open("/tmp/telemt-users.json", encoding="utf-8") as f:
        raw = json.load(f)
except Exception:
    sys.exit(1)
out = []
for u in user_dicts(raw):
    links = u.get("links") or {}
    tls = links.get("tls") or ()
    for L in tls:
        out.append(L)
    if not tls:
        for kind in ("secure", "classic"):
            for L in links.get(kind) or ():
                out.append(L)
for L in out:
    print(L)
PY
  _py="$?"
  rm -f /tmp/telemt-users.json
  return "$_py"
}

telemt_log_api_links() {
  log "$1"
  if telemt_dump_api_tls_links > /tmp/telemt-tls-out.txt 2>/dev/null; then
    if [ -s /tmp/telemt-tls-out.txt ]; then
      while IFS= read -r line; do
        [ -n "$line" ] && log "$line"
      done < /tmp/telemt-tls-out.txt
    else
      log "(API ответил, но список ссылок пуст — см. journalctl -u telemt)"
    fi
    rm -f /tmp/telemt-tls-out.txt
  else
    rm -f /tmp/telemt-tls-out.txt
    log "(API http://127.0.0.1:9091 недоступен — см. journalctl -u telemt -n 50)"
  fi
}

print_final_info_telemt() {
  TELEMT_PORT="$1"
  TLS_DOMAIN="$2"

  PUBLIC_IP="$(curl -4fsSL https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  [ -z "$PUBLIC_IP" ] && PUBLIC_IP="YOUR_SERVER_IP"

  log ""
  log "========== ГОТОВО (Telemt) =========="
  log "Служба:"
  systemctl --no-pager --full status telemt.service 2>/dev/null || true
  log ""
  telemt_log_api_links "Ссылки для клиента (Fake TLS); если пусто — подождите и проверьте journalctl -u telemt:"
  log ""
  log "Снова вывести ссылки: sh /path/to/get-links.sh (Telemt) или curl -s http://127.0.0.1:9091/v1/users"
  log ""
  log "Проверка маскировки (как в обзорах про active probing):"
  log "curl -v -I --resolve ${TLS_DOMAIN}:${TELEMT_PORT}:${PUBLIC_IP} https://${TLS_DOMAIN}/"
  log "(TLS и цепочка сертификатов до маскируемого хоста — главный признак успеха; код HTTP у edge часто 301/302/403/418 и не обязан быть 200.)"
  log ""
  log "Файлы: /etc/telemt/telemt.toml | логи: journalctl -u telemt -n 80 --no-pager"
  log "Регистрация в @MTProxybot: в конце установки будет запрос; подробнее: https://github.com/telemt/telemt/blob/main/docs/FAQ.ru.md"
}

is_valid_hex32() {
  [ ${#1} -eq 32 ] || return 1
  case "$1" in
    *[!0-9a-fA-F]*) return 1 ;;
  esac
  return 0
}

apply_telemt_ad_tag() {
  tag="$1"
  CFG="/etc/telemt/telemt.toml"
  sed -i 's/^use_middle_proxy = false/use_middle_proxy = true/' "$CFG"
  if grep -q '^ad_tag = ' "$CFG"; then
    sed -i "s|^ad_tag = \".*\"|ad_tag = \"${tag}\"|" "$CFG"
  else
    sed -i "/^use_middle_proxy = true/a ad_tag = \"${tag}\"" "$CFG"
  fi
  chown root:telemt "$CFG"
  chmod 0640 "$CFG"
}

prompt_telemt_proxy_tag() {
  log ""
  printf 'Зарегистрировать прокси в @MTProxybot (ad_tag, спонсорский канал / статистика)? (y/n) [n]: ' >&2
  answer="$(read_line_interactive)"
  answer="$(sanitize_tty_line "$answer")"
  if ! affirmative_answer "$answer"; then
    if [ -n "$answer" ]; then
      log "Пропуск @MTProxybot: ответ не распознан как согласие (введите y или yes). Настройка: https://github.com/telemt/telemt/blob/main/docs/FAQ.ru.md"
    fi
    return 0
  fi

  log "Шаг @MTProxybot: скопируйте в бота строки ниже."

  CFG="/etc/telemt/telemt.toml"
  if [ ! -f "$CFG" ]; then
    log "ОШИБКА: не найден $CFG"
    return 0
  fi

  SECRET="$(cat /etc/telemt/user-secret 2>/dev/null || true)"
  PORT="$(cat /etc/telemt/listen-port 2>/dev/null || true)"
  if [ -z "$PORT" ]; then
    PORT=443
  fi
  PUBLIC_HOST=""
  _ph="$(grep -E '^public_host = ' "$CFG" 2>/dev/null | head -1 | sed 's/^public_host = "\([^"]*\)".*/\1/' || true)"
  if [ -n "$_ph" ]; then
    PUBLIC_HOST="$_ph"
  fi
  if [ -z "$PUBLIC_HOST" ] || [ "$PUBLIC_HOST" = "0.0.0.0" ]; then
    PUBLIC_HOST="$(curl -4fsSL https://api.ipify.org 2>/dev/null || true)"
  fi
  if [ -z "$PUBLIC_HOST" ]; then
    PUBLIC_HOST="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  if [ -z "$PUBLIC_HOST" ]; then
    PUBLIC_HOST="YOUR_SERVER_IP"
  fi

  log ""
  log "В боте @MTProxybot: /newproxy, затем отправьте строки боту:"
  log ""
  log "host:port"
  log "${PUBLIC_HOST}:${PORT}"
  log ""
  log "secret (сырой секрет из [access.users] / файла /etc/telemt/user-secret, 32 hex):"
  log "${SECRET}"
  log ""
  log "Не отправляйте «secret» из ссылки tg://proxy — нужен только сырой hex с сервера."
  log "Ссылку, которую пришлёт бот, не используйте — для Telemt она не подходит."
  log "Как в режиме 1: в бот уходит secret, от бота вы получаете отдельную строку — proxy-tag (ad_tag); это не тот же secret."
  log "После ответа бота вставьте ниже только proxy-tag (32 hex). Перезагрузка сервера не нужна — скрипт сделает systemctl restart telemt."
  log ""

  while :; do
    printf 'Введите proxy-tag из ответа бота (32 hex, ad_tag): ' >&2
    tag="$(read_line_interactive)"
    tag="$(sanitize_tty_line "$tag")"
    tag="$(printf '%s' "$tag" | tr -d ' \t\n\r')"
    if is_valid_hex32 "$tag"; then
      break
    fi
    log "Ошибка: нужны ровно 32 hex-символа (0-9, a-f). Попробуйте снова."
  done

  apply_telemt_ad_tag "$tag"

  printf '%s' "$tag" > /etc/telemt/proxy-tag
  chown root:telemt /etc/telemt/proxy-tag
  chmod 0640 /etc/telemt/proxy-tag

  log "ad_tag записан, перезапускаю telemt..."
  systemctl restart telemt.service
  sleep 1
  if systemctl is-active --quiet telemt.service; then
    log "Готово. В боте: /myproxies → ваш прокси → Set promotion (публичная ссылка на канал; подождите до ~1 ч обновления)."
    log ""
    sleep 2
    telemt_log_api_links "Актуальная ссылка после ad_tag / middle proxy — удалите старый прокси в Telegram и добавьте эту (старая ссылка из чата часто перестаёт работать):"
    log ""
    log "Если Telegram пишет «прокси недоступен»:"
    log "  • Используйте только свежую tg:// ссылку из блока выше (после каждой переустановки и после ad_tag секрет/режим могут отличаться)."
    log "  • Проверка TCP снаружи: nc -vz ${PUBLIC_HOST} ${PORT} (если timeout — откройте порт ${PORT} у провайдера VPS, не только UFW)."
    log "  • Распространение у Telegram после бота может занять до ~1 ч."
    log "  • Тест без спонсора: в /etc/telemt/telemt.toml задайте use_middle_proxy = false, удалите строку ad_tag, затем systemctl restart telemt — если так заработает, проблема в middle proxy / ожидании бота."
  else
    log "ПРЕДУПРЕЖДЕНИЕ: telemt не запустился. Проверьте: journalctl -u telemt -n 30"
  fi
}

prompt_proxy_tag() {
  log ""
  printf 'Добавить proxy-tag из бота @MTProxybot? (y/n) [n]: ' >&2
  answer="$(read_line_interactive)"
  answer="$(sanitize_tty_line "$answer")"
  if ! affirmative_answer "$answer"; then
    if [ -n "$answer" ]; then
      log "Пропуск @MTProxybot: ответ не распознан как согласие (введите y или yes)."
    fi
    return 0
  fi
  log "Данные для бота @MTProxybot:"

  PORT="$(grep -E '^PORT=' /etc/default/mtproxy 2>/dev/null | cut -d= -f2 || echo 443)"
  SECRET="$(cat /etc/mtproxy/user-secret 2>/dev/null || true)"
  PUBLIC_IP="$(curl -4fsSL https://api.ipify.org 2>/dev/null || true)"
  [ -z "$PUBLIC_IP" ] && PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [ -z "$PUBLIC_IP" ] && PUBLIC_IP="YOUR_SERVER_IP"

  log ""
  log "Отправьте боту @MTProxybot:"
  log ""
  log "host:port"
  log "${PUBLIC_IP}:${PORT}"
  log ""
  log "secret"
  log "${SECRET}"
  log ""
  log "После регистрации бот пришлёт proxy-tag. Введите его ниже:"
  log ""

  while :; do
    printf 'Введите proxy-tag (32 hex-символа): ' >&2
    tag="$(read_line_interactive)"
    tag="$(sanitize_tty_line "$tag")"
    tag="$(printf '%s' "$tag" | tr -d ' \t\n\r')"
    if is_valid_hex32 "$tag"; then
      break
    fi
    log "Ошибка: нужны ровно 32 hex-символа (0-9, a-f). Попробуйте снова."
  done

  printf '%s' "$tag" > /etc/mtproxy/proxy-tag
  chown root:mtproxy /etc/mtproxy/proxy-tag
  chmod 0640 /etc/mtproxy/proxy-tag

  log "Proxy-tag сохранён. Перезапускаю mtproxy..."
  systemctl restart mtproxy.service
  sleep 1
  if systemctl is-active --quiet mtproxy.service; then
    log "Готово. MTProxy перезапущен с proxy-tag."
  else
    log "ПРЕДУПРЕЖДЕНИЕ: mtproxy не запустился. Проверьте: journalctl -u mtproxy -n 20"
  fi
}

main() {
  need_root

  # Basic required tools check early for clearer errors.
  command -v apt >/dev/null 2>&1 || { log "ОШИБКА: apt не найден. Установщик для Ubuntu/Debian."; exit 1; }
  command -v ss >/dev/null 2>&1 || { log "ОШИБКА: ss не найден (установите iproute2)."; exit 1; }

  WORKERS="${WORKERS:-1}"
  MODE="$(prompt_install_mode)"

  log "Укажите порт, на котором будет работать прокси (по умолчанию 443):"
  PORT="$(prompt_port)"

  log "Проверяю, что порт ${PORT} свободен"
  if ! port_is_free "$PORT"; then
    log "ОШИБКА: порт ${PORT} уже занят."
    ss -ltnp 2>/dev/null | grep ":${PORT}" || true
    exit 1
  fi

  SSH_PORT="$(get_ssh_port)"
  log "Обнаружен порт SSH: ${SSH_PORT}"

  if [ "$MODE" = "telemt" ]; then
    TLS_DOMAIN="$(prompt_tls_domain)"
    log "[1/8] Режим: Telemt (официальный бинарник)"
    install_packages_telemt
    telemt_setup "$PORT" "$TLS_DOMAIN"
    configure_ufw "$PORT" "$SSH_PORT"
    configure_fail2ban "$SSH_PORT"
    log "[6/8] Готово"
    print_final_info_telemt "$PORT" "$TLS_DOMAIN"
    prompt_telemt_proxy_tag
  else
    log "[1/10] Режим: классический MTProxy"
    install_packages
    create_system_user
    build_mtproxy

    SECRET="$(configure "$PORT" "$WORKERS")"
    enable_services
    configure_ufw "$PORT" "$SSH_PORT"
    configure_fail2ban "$SSH_PORT"

    print_final_info "$PORT" "$SECRET"

    prompt_proxy_tag
  fi
}

main "$@"

