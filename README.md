# Pila_port — 3X-UI SNI Router

Интерактивный скрипт для настройки **Nginx Stream (SNI-роутер)** + отдельный домен для подписки 3X-UI.

## Схема работы

```
ИНТЕРНЕТ
   │
   ├── TCP :443 ──► NGINX STREAM / SNI ROUTER
   │                     │
   │                     ├── SNI = panel.example.com  → 127.0.0.1:8443  (NGINX HTTPS)
   │                     │                                  └── /panel/ → 3x-ui :29395
   │                     │
   │                     ├── SNI = sub.example.com    → 127.0.0.1:8444  (NGINX HTTPS)
   │                     │                                  └── /       → Subscription :2096
   │                     │
   │                     └── SNI = vpn.example.com    → 127.0.0.1:443   (Xray VLESS REALITY)
   │
   └── UDP :443 ──► AmneziaWG (опционально)
```

## Возможности

- Спрашивает 3 домена (панель / подписка / REALITY)
- Спрашивает порты панели, subscription и REALITY
- Проверяет занятость портов
- Устанавливает Nginx + certbot
- Автоматически получает SSL-сертификаты Let's Encrypt
- Создаёт SNI-роутер и два HTTPS-сервера
- Выводит инструкции по настройке 3x-ui

## Требования

- Debian / Ubuntu
- Root-доступ
- 3 домена (A-записи уже должны указывать на сервер)
- 3x-ui уже установлен

## Быстрая установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/deilja/Pila_port/main/setup-3xui-sni.sh)
```

Или вручную:

```bash
wget -O setup-3xui-sni.sh https://raw.githubusercontent.com/deilja/Pila_port/main/setup-3xui-sni.sh
chmod +x setup-3xui-sni.sh
sudo ./setup-3xui-sni.sh
```

## Что нужно настроить в 3x-ui после установки

### 1. Панель
- **Listen IP**: `127.0.0.1`
- **Port**: тот, который указали в скрипте (по умолчанию `29395`)
- **Web Base Path**: `/panel/`

### 2. Subscription
- **Listen IP**: `127.0.0.1`
- **Port**: тот, который указали в скрипте (по умолчанию `2096`)
- **Sub URI**: `https://sub.example.com` (ваш домен подписки)

### 3. REALITY inbound
- **Listen**: `127.0.0.1:443` (или порт, который указали)
- **SNI / serverNames**: ваш REALITY-домен

## Полезные команды

```bash
# Статус Nginx
systemctl status nginx

# Логи
journalctl -u nginx -f

# Проверка конфигурации
nginx -t

# Перезагрузка
systemctl reload nginx
```

## Структура конфигов

| Файл | Назначение |
|------|------------|
| `/etc/nginx/stream.d/sni-router.conf` | SNI-роутер (порт 443) |
| `/etc/nginx/conf.d/panel.conf` | HTTPS панели (127.0.0.1:8443) |
| `/etc/nginx/conf.d/sub.conf` | HTTPS подписки (127.0.0.1:8444) |

## Лицензия

Свободное использование.
