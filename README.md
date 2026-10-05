# Pila_port — 3X-UI SNI Router

Интерактивный установщик для схемы **Nginx Stream SNI → 3X-UI / Subscription / Xray REALITY** на одном TCP-порту `443`.

## Архитектура

```text
                         INTERNET
                            │
                    TCP :443 / TLS ClientHello
                            │
                            ▼
                 NGINX STREAM / SNI PREREAD
                            │
             ┌──────────────┼───────────────┐
             │              │               │
   SNI = panel.domain   SNI = sub.domain   SNI = reality-sni
             │              │               │
             ▼              ▼               ▼
      127.0.0.1:8443  127.0.0.1:8444   127.0.0.1:4433
          Nginx HTTPS      Nginx HTTPS       Xray REALITY
             │              │
             ▼              ▼
       3X-UI :PANEL     Subscription :SUB
```

Nginx **не расшифровывает REALITY**. Он только читает SNI из ClientHello и передаёт TCP-сессию дальше.

Важное отличие от старой версии: Xray REALITY по умолчанию получает отдельный локальный порт `4433`, а наружу всё равно используется `TCP :443`. Это исключает конфликт wildcard `Nginx :443` с `Xray 127.0.0.1:443`.

## Что делает установщик

- Запрашивает домен панели, домен подписки и SNI для REALITY.
- Запрашивает фактические порты 3X-UI и Web Base Path.
- Использует отдельные loopback-порты Nginx `8443` и `8444`.
- Устанавливает Nginx, Certbot, DNS/OpenSSL-зависимости и stream-модуль.
- Проверяет `TCP :443` и защищает служебные backend-порты от конфликтов.
- Проверяет A-записи panel/sub.
- Получает сертификаты Let's Encrypt через временный **webroot**, не останавливая уже работающий Nginx.
- Создаёт SNI-router на TCP `443`.
- Делает HTTPS reverse proxy для панели и подписки.
- Создаёт резервные копии изменяемых Nginx-конфигов.
- Проверяет `nginx -t`, наличие listener на `443` и TLS/SNI для panel/sub.
- Не настраивает Xray или 3X-UI автоматически — их параметры остаются под контролем пользователя.

## Требования

- Debian или Ubuntu.
- Root-доступ.
- Уже установленный 3X-UI/Xray.
- A-запись **панельного домена** → этот VPS.
- A-запись **домена подписки** → этот VPS.
- Для `REALITY SNI` отдельная A-запись на этот VPS **не требуется**: это имя `serverNames`, используемое REALITY.

## Установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/deilja/Pila_port/main/setup-3xui-sni.sh)
```

Или:

```bash
wget -O setup-3xui-sni.sh https://raw.githubusercontent.com/deilja/Pila_port/main/setup-3xui-sni.sh
chmod +x setup-3xui-sni.sh
sudo ./setup-3xui-sni.sh
```

### Перед запуском

Узнай реальные значения в 3X-UI. Не используй значения из README как обязательные: разные версии/установки 3X-UI могут иметь другие panel port и Web Base Path.

Скрипт по умолчанию предлагает:

```text
Panel port:      29395
Subscription:    2096
REALITY local:   4433
Web Base Path:   /panel/
```

Их можно заменить во время установки.

## Настройка 3X-UI

### 1. Панель

В 3X-UI:

```text
Listen IP:       127.0.0.1
Port:            тот же, что введён в установщике
Web Base Path:   тот же path, что введён в установщике
```

После этого панель будет доступна как:

```text
https://PANEL_DOMAIN/PANEL_PATH/
```

### 2. Subscription

```text
Listen IP:       127.0.0.1
Port:            тот же, что введён в установщике
Subscription URL: https://SUB_DOMAIN/
```

### 3. VLESS + REALITY

```text
Listen IP:       127.0.0.1
Port:            4433        # или другой свободный локальный порт, который указал установщик
SNI/serverNames: VPN_SNI
```

Клиент при этом продолжает подключаться к VPS по:

```text
VPN_DOMAIN:443
```

Nginx передаёт этот TCP-поток на `127.0.0.1:4433` без TLS termination.

## PROXY protocol

По умолчанию `PROXY protocol` **выключен**. Это самый безопасный вариант для готового REALITY inbound без дополнительных настроек Xray.

Если нужен реальный IP клиента внутри panel/sub и Xray настроен на приём PROXY protocol, установку можно запускать так:

```bash
SNI_PROXY_PROTOCOL=on bash ./setup-3xui-sni.sh
```

При включении этой опции Xray REALITY inbound также должен принимать PROXY protocol.

## UDP :443 / AmneziaWG

Этот проект **не настраивает UDP :443**. Nginx Stream в данном установщике занимается TCP SNI-маршрутизацией.

AmneziaWG можно использовать отдельно, но его firewall/listener и конфигурацию этот скрипт не меняет.

## Конфиги

После установки:

```text
/etc/nginx/nginx.conf
/etc/nginx/stream.d/sni-router.conf
/etc/nginx/conf.d/pila-panel.conf
/etc/nginx/conf.d/pila-sub.conf
```

Резервные копии создаются рядом с изменяемыми файлами как `.bak.TIMESTAMP_PID`.

## Проверка

```bash
nginx -t
systemctl status nginx --no-pager -l
ss -ltnp | grep -E ':443|:8443|:8444|:4433'
```

Логи:

```bash
journalctl -u nginx -f
cat /var/log/setup-3xui-sni.log
```

Для проверки SNI:

```bash
openssl s_client -connect YOUR_SERVER_IP:443 -servername panel.example.com -brief
openssl s_client -connect YOUR_SERVER_IP:443 -servername sub.example.com -brief
```

## Повторный запуск

Скрипт старается не перезаписывать неизвестные пользователю Nginx-конфиги. Если целевой файл существует и не содержит маркер `Pila_port`, установка останавливается.

Если `nginx.conf` уже содержит собственный `stream { ... }` без подключения `stream.d`, скрипт не пытается автоматически переписывать этот блок: он выводит точную строку, которую нужно добавить вручную.

## Ограничения

Установщик не изменяет:

- пользователей/пароли 3X-UI;
- inbound-конфигурацию Xray;
- UUID/Reality keys;
- существующие DNS-записи;
- UDP/AmneziaWG;
- firewall-правила и UFW.
