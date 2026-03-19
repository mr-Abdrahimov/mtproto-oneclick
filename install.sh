#!/usr/bin/env sh
set -eu

# Ubuntu installer for Telegram MTProxy (mtproto-proxy).
# - Installs and builds MTProxy from GitHub sources
# - Creates systemd service + daily config refresh timer
# - Enables UFW and only allows SSH + MTProxy ports
# - Installs Fail2ban for SSH protection
#
# Usage:
#   sudo sh <(wget -O - https://raw.githubusercontent.com/mr-Abdrahimov/mtproto-oneclick/main/install.sh)

log() {
  printf '%s\n' "$1" >&2
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
    read -r in_port < /dev/tty

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

  cat > "$SERVICE_FILE" <<'UNIT'
[Unit]
Description=Telegram MTProxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/default/mtproxy
ExecStart=/bin/sh -c '/usr/local/bin/mtproto-proxy -u mtproxy -p 8888 -H "$PORT" -S "$(cat /etc/mtproxy/user-secret)" --http-stats --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M "$WORKERS"'
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

  log "[9/10] Настраиваю UFW (файрвол)"
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

  log "[10/10] Настраиваю Fail2ban для SSH"

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

main() {
  need_root

  # Basic required tools check early for clearer errors.
  command -v apt >/dev/null 2>&1 || { log "ОШИБКА: apt не найден. Установщик для Ubuntu/Debian."; exit 1; }
  command -v ss >/dev/null 2>&1 || { log "ОШИБКА: ss не найден (установите iproute2)."; exit 1; }

  WORKERS="${WORKERS:-1}"

  log "Укажите порт, на котором будет работать MTProxy (по умолчанию 443):"
  PORT="$(prompt_port)"

  log "[1/10] Проверяю, что порт ${PORT} свободен"
  if ! port_is_free "$PORT"; then
    log "ОШИБКА: порт ${PORT} уже занят."
    ss -ltnp 2>/dev/null | grep ":${PORT}" || true
    exit 1
  fi

  SSH_PORT="$(get_ssh_port)"
  log "Обнаружен порт SSH: ${SSH_PORT}"

  install_packages
  create_system_user
  build_mtproxy

  SECRET="$(configure "$PORT" "$WORKERS")"
  enable_services
  configure_ufw "$PORT" "$SSH_PORT"
  configure_fail2ban "$SSH_PORT"

  print_final_info "$PORT" "$SECRET"
}

main "$@"

