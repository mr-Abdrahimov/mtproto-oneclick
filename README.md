# mtproto-oneclick (Ubuntu)

Скрипт для установки Telegram MTProxy (`mtproto-proxy`) на Ubuntu + включение защиты:

- UFW: запрет входящего трафика и разрешение только `SSH` и порта MTProxy
- Fail2ban: защита от перебора/атак по `SSH`

Во время установки скрипт попросит указать TCP-порт, на котором будет работать MTProxy.

## Установка

Запускайте от `root` (через `sudo`):

```sh
sudo sh <(wget -O - https://raw.githubusercontent.com/mr-Abdrahimov/mtproto-oneclick/main/install.sh)
```

Скрипт:

1. Проверит, что порт MTProxy свободен
2. Скачает и соберёт MTProxy
3. Настроит `systemd` сервис `mtproxy` и ежедневное обновление `proxy-multi.conf`
4. Поднимет UFW и разрешит доступ к:
   - `SSH` (автоматически определит порт из `sshd_config`, обычно `22`)
   - выбранному порту MTProxy
5. Установит Fail2ban для SSH

## Что будет на выходе

После установки скрипт выведет:

- статус сервиса `mtproxy`
- `client secret`
- ссылки для подключения:
  - `tg://proxy?server=...&port=...&secret=...`
  - `https://t.me/proxy?...`

Локальная статистика:

```sh
curl -s http://127.0.0.1:8888/stats
```

## Конфиги

- MTProxy: `/etc/mtproxy/`
- systemd service: `/etc/systemd/system/mtproxy.service`
- Fail2ban: `/etc/fail2ban/jail.d/sshd.local`

