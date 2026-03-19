# mtproto-oneclick (Ubuntu)

Скрипт для установки Telegram MTProxy (`mtproto-proxy`) на Ubuntu + включение защиты:

- UFW: запрет входящего трафика и разрешение только `SSH` и порта MTProxy
- Fail2ban: защита от перебора/атак по `SSH`

Во время установки скрипт попросит указать TCP-порт, на котором будет работать MTProxy.

## Установка

Запускайте от `root` (через `sudo`).

**Вариант 1 — скачать и запустить (самый надёжный):**

```sh
wget -qO /tmp/install-mtproxy.sh https://raw.githubusercontent.com/mr-Abdrahimov/mtproto-oneclick/main/install.sh
sudo sh /tmp/install-mtproxy.sh
```

**Вариант 2 — через curl:**

```sh
curl -fsSL https://raw.githubusercontent.com/mr-Abdrahimov/mtproto-oneclick/main/install.sh -o /tmp/install-mtproxy.sh
sudo sh /tmp/install-mtproxy.sh
```

**Вариант 3 — одной строкой (может не работать в части окружений):**

```sh
curl -fsSL https://raw.githubusercontent.com/mr-Abdrahimov/mtproto-oneclick/main/install.sh | sudo sh
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

## Получить ссылки для подключения

Чтобы снова вывести secret и ссылки (например, после переустановки или если вы их не сохранили), выполните на сервере:

```sh
curl -fsSL https://raw.githubusercontent.com/mr-Abdrahimov/mtproto-oneclick/main/get-links.sh | sudo sh
```

Или через wget:

```sh
wget -qO - https://raw.githubusercontent.com/mr-Abdrahimov/mtproto-oneclick/main/get-links.sh | sudo sh
```

## Конфиги

- MTProxy: `/etc/mtproxy/`
- systemd service: `/etc/systemd/system/mtproxy.service`
- Fail2ban: `/etc/fail2ban/jail.d/sshd.local`

## Устранение неполадок

**Прокси не работает:** проверьте `systemctl status mtproxy`, логи — `journalctl -u mtproxy -n 50`, откройте порт в панели хостинга.

**`curl http://127.0.0.1:8888/stats` возвращает пустое:** скрипт теперь добавляет `--http-stats` при установке. Для уже установленных — добавьте `--http-stats` в `ExecStart` в `/etc/systemd/system/mtproxy.service`, затем `systemctl daemon-reload && systemctl restart mtproxy`.

